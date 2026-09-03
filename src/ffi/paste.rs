use std::ffi::{c_char, c_int};
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

use arboard::Clipboard;

use crate::backend::{backend, try_backend, copyattach_temp_root, mark_history_changed, PendingSelfWrite};
use crate::db::load_text_by_db_id;
use crate::history::add_to_history;
use crate::macos;
use crate::types::ClipboardEntry;
use super::to_ffi_cstring;

/// Maximum age for a materialized paste PNG. Cmd+V is delivered asynchronously
/// (`CGEventPostToPid`), so a busy target may read the *previous* paste's file
/// after the next paste begins; the file must outlive that window. Anything
/// older than this can no longer be in flight and is safe to purge.
const PASTE_IMAGE_TTL: Duration = Duration::from_secs(60);


/// Materialize a clipboard image as a PNG file under the per-user temp
/// directory, mirroring the drag provider's convention (separate `Paste`
/// subdir so drag cleanup never races with a paste in flight). The new file
/// is written first; only once it is safely on disk are files older than
/// [`PASTE_IMAGE_TTL`] purged — a failed write must never delete the file the
/// pasteboard still references (the clipboard keeps the previous paste's URL
/// until this paste's `set_pasteboard_file_url` replaces it). Never delete
/// everything, since the previous paste's target may still be reading its file.
///
/// Returns the absolute file path, or `None` (with a log) on failure.
fn write_paste_image_file(png_data: &[u8], entry_id: u64) -> Option<String> {
    let mut dir = copyattach_temp_root();
    dir.push("Paste");
    if let Err(e) = std::fs::create_dir_all(&dir) {
        crate::error_log!("CopyAttach: cannot create paste image dir {}: {e}", dir.display());
        return None;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let path = dir.join(format!("clipboard-{entry_id}-{}.png", now.as_micros()));
    if let Err(e) = std::fs::write(&path, png_data) {
        crate::error_log!("CopyAttach: cannot write paste image {}: {e}", path.display());
        return None;
    }
    purge_stale_paste_images();
    Some(path.to_string_lossy().into_owned())
}

/// Purge materialized paste PNGs older than [`PASTE_IMAGE_TTL`]. Runs after
/// each successful paste materialization (never before the new file is on
/// disk — a failed write must not delete the file the pasteboard still
/// references) and once at backend init: a long stretch without image pastes
/// would otherwise leave stale files until the OS cleans $TMPDIR. Never
/// deletes everything, since the previous paste's target may still be
/// reading its file.
pub(crate) fn purge_stale_paste_images() {
    let mut dir = copyattach_temp_root();
    dir.push("Paste");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if let Ok(modified) = meta.modified() {
                    if let Ok(mtime) = modified.duration_since(std::time::UNIX_EPOCH) {
                        if now.saturating_sub(mtime) >= PASTE_IMAGE_TTL {
                            let _ = std::fs::remove_file(entry.path());
                        }
                    }
                }
            }
        }
    }
}

/// Shared implementation for select-and-paste.
/// Loads full image data from DB if needed, writes to system clipboard,
/// write-through DB, moves item to top of history, then simulates paste.
/// When `as_path` is true and the entry is an Image, its temp PNG path is
/// placed on the clipboard as plain text instead of `public.file-url`.
fn select_and_paste_impl(mut item: ClipboardEntry, as_path: bool) -> c_int {
    #[cfg(target_os = "macos")]
    {
        // Cmd+V simulation needs accessibility permission. Gate BEFORE any
        // pasteboard write: the write replaces the user's clipboard, so
        // proceeding without permission would destroy their content on a paste
        // that can never happen — and the old fall-through still reported
        // success (1). No permission → explicit failure, clipboard untouched.
        if !macos::check_permission() {
            crate::error_log!("CopyAttach: accessibility permission not granted — paste aborted, clipboard untouched");
            return 0;
        }
    }

    // The entry is moved to the top of history below. Stamp it with the current
    // time so the list order (most-recently-used) stays consistent with the
    // entry's timestamp — the day separator groups rely on this invariant.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    match &mut item {
        ClipboardEntry::Text { ref mut timestamp, .. }
        | ClipboardEntry::Image { ref mut timestamp, .. } => {
            *timestamp = now;
        }
    }

    // Text paste needs the full body, which lives in SQLite — the in-memory
    // entry only carries preview/label/hash. A text entry with db_id=0 was
    // never persisted (DB write failed) and cannot be pasted: explicit
    // failure, clipboard untouched, mirroring the image load failure below.
    // The guard marks the body's pages reusable on drop: the text is
    // transient here (written to the pasteboard and re-persisted from a
    // slice), so its pages must leave the footprint at scope end on every
    // return path — release-path symmetry with the claim in
    // `load_text_by_db_id`.
    let full_text: Option<crate::backend::MarkStringReusableOnDrop> = match &item {
        ClipboardEntry::Text { db_id, .. } => {
            if *db_id == 0 {
                crate::error_log!("CopyAttach: select_and_paste aborted for text entry {}: db_id=0 (entry not persisted)", item.entry_id());
                return 0;
            }
            match backend().db.lock() {
                Ok(conn) => match load_text_by_db_id(&conn, *db_id) {
                    Some(t) => Some(crate::backend::MarkStringReusableOnDrop(t)),
                    None => {
                        crate::error_log!("CopyAttach: select_and_paste DB text load failed for entry {} (db_id={}) — paste aborted", item.entry_id(), *db_id);
                        return 0;
                    }
                },
                Err(e) => {
                    crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste text load: {e}");
                    return 0;
                }
            }
        }
        _ => None,
    };

    let mut image_blobs: Option<crate::backend::MarkImageBlobsReusableOnDrop> = None;
    let mut image_thumb_dims: Option<(u32, u32)> = None;

    if let ClipboardEntry::Image { db_id, id, .. } = &item {
        if *db_id != 0 {
            let conn = match backend().db.lock() {
                Ok(c) => c,
                Err(e) => {
                    crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste image load: {e}");
                    return 0;
                }
            };
            match conn.query_row(
                "SELECT png_data, thumb_data, thumb_width, thumb_height FROM clipboard_history WHERE id = ?",
                rusqlite::params![*db_id],
                |row| Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                )),
            ) {
                Ok((png, thumb, tw, th)) => {
                    // Claim any reusable-marked pages the allocator handed
                    // back: these blobs are written to the pasteboard.
                    crate::backend::claim_pages(png.as_ptr(), png.capacity());
                    crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity());
                    image_thumb_dims = Some((tw as u32, th as u32));
                    image_blobs = Some(crate::backend::MarkImageBlobsReusableOnDrop { png, thumb });
                }
                Err(e) => {
                    crate::error_log!("CopyAttach: select_and_paste DB load failed for image entry {} (db_id={}): {e} — paste aborted", id, *db_id);
                    return 0;
                }
            }
        }
    }

    // Text paste needs the arboard clipboard handle; image paste writes the
    // pasteboard directly via NSPasteboard (set_pasteboard_file_url) and must
    // not fail on an arboard handle it never uses.
    let b = backend();
    let _event_guard = b.pasteboard_event_lock.lock().unwrap();
    // Image paste always uses drag-style file-path mode — the single,
    // universal convention: the image is materialized as a temp PNG and only
    // its file URL goes on the pasteboard (Finder "copy file" semantics).
    // Terminals translate the URL into the path text (TUI agents like Claude
    // Code consume exactly this form); chat/notes apps attach the file.
    match &item {
        ClipboardEntry::Text { .. } => {
            let text = match &full_text {
                Some(t) => t,
                None => {
                    crate::error_log!("CopyAttach: select_and_paste text body missing — paste aborted");
                    return 0;
                }
            };
            let mut cb = match Clipboard::new() { Ok(c) => c, Err(_) => return 0 };
            if cb.set_text(&text.0).is_err() { return 0; }
        }
        ClipboardEntry::Image { id, .. } => {
            let blobs = match &image_blobs {
                Some(b) if !b.png.is_empty() => b,
                _ => return 0,
            };
            let path = match write_paste_image_file(&blobs.png, *id) {
                Some(p) => p,
                None => return 0,
            };
            if as_path {
                let mut cb = match Clipboard::new() { Ok(c) => c, Err(_) => return 0 };
                if cb.set_text(&path).is_err() { return 0; }
            } else if !macos::set_pasteboard_file_url(&path) {
                return 0;
            }
        }
    }
    let change_count = macos::pasteboard_change_count()
        .expect("CopyAttach: cannot identify self-written pasteboard change");
    *b.pending_self_write.lock().unwrap() = Some(
        PendingSelfWrite { change_count },
    );
    drop(_event_guard);

    if let Some(b) = try_backend() {
        match b.db.lock() {
            Ok(mut conn) => {
                let png_for_db = image_blobs.as_ref().map(|b| b.png.as_slice());
                let thumb_for_db = image_blobs.as_ref().and_then(|b| {
                    image_thumb_dims.map(|(tw, th)| (b.thumb.as_slice(), tw, th))
                });

                match crate::db::persist_entry_to_db(
                    &mut conn,
                    &item,
                    full_text.as_ref().map(|g| g.0.as_str()),
                    png_for_db,
                    thumb_for_db,
                    b.cleanup_threshold.load(Ordering::Relaxed),
                ) {
                    Ok(new_row_id) => {
                        match &mut item {
                            ClipboardEntry::Image { ref mut db_id, .. } |
                            ClipboardEntry::Text { ref mut db_id, .. } => {
                                *db_id = new_row_id;
                            }
                        }
                    }
                    Err(()) => {
                        crate::error_log!("CopyAttach: select_and_paste DB insert failed — entry stays with db_id=0");
                    }
                }
            }
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste persist: {e} — entry stays with db_id=0");
            }
        }
    }

    {
        let b = backend();
        let mut hist = b.history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), item);
        while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
            hist.pop();
        }
        mark_history_changed();
    }

    let front_pid = try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .map_or(0, |src| src.pid);

    thread::sleep(Duration::from_millis(50));
    #[cfg(target_os = "macos")]
    {
        // Permission was already verified up front; here only the key event
        // can fail.
        if !macos::simulate_cmd_v(front_pid) {
            crate::error_log!("CopyAttach: simulate_cmd_v failed");
            return 0;
        }
    }
    1
}

/// Legacy: select and paste by array index. Prefer `clipboard_select_and_paste_by_id`.
#[no_mangle]
pub extern "C" fn clipboard_select_and_paste(index: c_int) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    select_and_paste_impl(item, false)
}

/// Select and paste by stable entry ID (not array index).
#[no_mangle]
pub extern "C" fn clipboard_select_and_paste_by_id(entry_id: u64) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        match hist.iter().find(|e| match e {
            ClipboardEntry::Text { id, .. } => *id == entry_id,
            ClipboardEntry::Image { id, .. } => *id == entry_id,
        }).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    select_and_paste_impl(item, false)
}

/// Select and paste as path text by stable entry ID (e.g. Shift+Enter).
#[no_mangle]
pub extern "C" fn clipboard_select_and_paste_as_path_by_id(entry_id: u64) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        match hist.iter().find(|e| match e {
            ClipboardEntry::Text { id, .. } => *id == entry_id,
            ClipboardEntry::Image { id, .. } => *id == entry_id,
        }).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    select_and_paste_impl(item, true)
}

/// Load full text by entry ID (for on-demand preview loading). The body lives
/// in SQLite, so the entry's db_id is resolved in memory, then loaded from DB.
/// Returns null if `entry_id` is not found, is not a text entry, or the body
/// is not persisted (db_id=0 — DB write pending/failed).
/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_text_by_id(entry_id: u64) -> *mut c_char {
    let b = match try_backend() {
        Some(b) => b,
        None => return std::ptr::null_mut(),
    };
    let db_id = {
        let hist = b.history.lock().unwrap();
        let mut found = None;
        for entry in hist.iter() {
            if let ClipboardEntry::Text { id, db_id, .. } = entry {
                if *id == entry_id {
                    found = Some(*db_id);
                    break;
                }
            }
        }
        match found {
            Some(d) => d,
            None => return std::ptr::null_mut(),
        }
    };
    if db_id == 0 {
        crate::error_log!("CopyAttach: get_text_by_id for entry {entry_id}: db_id=0 (entry not persisted)");
        return std::ptr::null_mut();
    }
    let text = match b.db.lock() {
        Ok(conn) => match load_text_by_db_id(&conn, db_id) {
            Some(t) => t,
            None => return std::ptr::null_mut(),
        },
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading text for entry {entry_id}: {e}");
            return std::ptr::null_mut();
        }
    };
    // Transient body: mark its pages reusable once the FFI CString is built.
    let guard = crate::backend::MarkStringReusableOnDrop(text);
    to_ffi_cstring(&guard.0)
}
