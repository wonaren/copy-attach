use std::ffi::{c_char, c_int};
use std::sync::atomic::Ordering;
use std::thread;
use std::time::Duration;

use crate::backend::{backend, try_backend, copyattach_temp_root, mark_history_changed, PendingSelfWrite};
use crate::db::load_text_by_db_id;
use crate::history::add_to_history;
use crate::platform;
use crate::types::ClipboardEntry;
use super::to_ffi_cstring;

/// Maximum age for a materialized paste PNG. Cmd+V is delivered asynchronously
/// (`CGEventPostToPid`), so a busy target may read the *previous* paste's file
/// after the next paste begins; the file must outlive that window. Anything
/// older than this can no longer be in flight and is safe to purge.
const PASTE_IMAGE_TTL: Duration = Duration::from_secs(60);

/// Bundle identifiers whose Cmd+V handler does not translate a Finder-style
/// `public.file-url` pasteboard item into path text. VS Code's integrated
/// terminal reads plain text on paste; its file-resource fallback only
/// understands VS Code's private `code/file-list` clipboard format, never the
/// `public.file-url` item that native terminals translate into a path.
/// For these targets the materialized image path must be written as plain
/// text so Cmd+V inserts the same path string that drag-and-drop inserts.
#[cfg(target_os = "macos")]
const TEXT_PATH_PASTE_BUNDLE_IDS: &[&str] = &[
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.microsoft.VSCodeExploration",
    "com.visualstudio.code.oss",
    "com.vscodium",
];

/// Whether an image paste into `bundle_id` must put the temp PNG path on the
/// pasteboard as `public.utf8-plain-text` instead of `public.file-url`.
#[cfg(target_os = "macos")]
fn image_target_needs_text_path(bundle_id: &str) -> bool {
    TEXT_PATH_PASTE_BUNDLE_IDS.contains(&bundle_id)
}

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
#[cfg(target_os = "macos")]
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
fn select_and_paste_impl(mut item: ClipboardEntry) -> c_int {
    // Paste simulation may need an OS permission gate (macOS accessibility).
    // Gate BEFORE any clipboard write: the write replaces the user's
    // clipboard, so proceeding without permission would destroy their content
    // on a paste that can never happen. No permission → explicit failure,
    // clipboard untouched. (Windows: SendInput needs no gate, returns true.)
    if !platform::check_permission() {
        crate::error_log!("CopyAttach: paste permission not granted — paste aborted, clipboard untouched");
        return 0;
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

    let db_item = match &item {
        ClipboardEntry::Image { db_id, .. } if *db_id != 0 => {
            let mut loaded = item.clone();
            if let ClipboardEntry::Image { ref mut png_data, ref mut thumb_data, ref mut thumb_width, ref mut thumb_height, .. } = loaded {
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
                        *png_data = png;
                        *thumb_data = thumb;
                        *thumb_width = tw as u32;
                        *thumb_height = th as u32;
                    }
                    Err(e) => {
                        crate::error_log!("CopyAttach: select_and_paste DB load failed for image entry {} (db_id={}): {e} — paste aborted", item.entry_id(), *db_id);
                        return 0;
                    }
                }
            }
            loaded
        }
        _ => item.clone(),
    };
    // The DB-loaded blobs above are transient (re-persisted from slices
    // below, never stored). The guard marks their pages reusable at scope
    // end on every return path — release-path symmetry with the claim at
    // load time.
    let db_item = crate::backend::MarkEntryBlobsReusableOnDrop(db_item);

    // Text paste needs the arboard clipboard handle; image paste writes the
    // pasteboard directly via NSPasteboard (set_pasteboard_file_url) and must
    // not fail on an arboard handle it never uses.
    let b = backend();
    let _event_guard = b.pasteboard_event_lock.lock().unwrap();
    // Image paste uses drag-style file-path mode: the image is materialized
    // as a temp PNG and only its file URL goes on the pasteboard (Finder
    // "copy file" semantics). Terminals translate the URL into the path text
    // (TUI agents like Claude Code consume exactly this form); chat/notes
    // apps attach the file. VS Code's integrated terminal is the exception:
    // its Cmd+V handler only reads plain text, so the path is written as text
    // for that target.
    match &db_item.0 {
        ClipboardEntry::Text { .. } => {
            let text = match &full_text {
                Some(t) => t,
                None => {
                    crate::error_log!("CopyAttach: select_and_paste text body missing — paste aborted");
                    return 0;
                }
            };
            if !platform::set_clipboard_text(&text.0) {
                crate::error_log!("CopyAttach: clipboard text write failed — paste aborted");
                return 0;
            }
        }
        ClipboardEntry::Image { png_data, id, .. } => {
            if png_data.is_empty() { return 0; }
            #[cfg(target_os = "macos")]
            {
                // Image paste uses drag-style file-path mode: the image is
                // materialized as a temp PNG and only its file URL goes on
                // the pasteboard (Finder "copy file" semantics). Terminals
                // translate the URL into the path text (TUI agents like
                // Claude Code consume exactly this form); chat/notes apps
                // attach the file. VS Code's integrated terminal is the
                // exception: its Cmd+V handler only reads plain text, so the
                // path is written as text for that target.
                let path = match write_paste_image_file(png_data, *id) {
                    Some(p) => p,
                    None => return 0,
                };
                let target_bundle_id = b.source_app.lock()
                    .ok()
                    .map(|src| src.bundle_id.clone())
                    .unwrap_or_default();
                if image_target_needs_text_path(&target_bundle_id) {
                    crate::debug_log!("CopyAttach: image paste as path text for target {target_bundle_id}");
                    if !platform::set_clipboard_text(&path) { return 0; }
                } else if !platform::set_clipboard_file_url(&path) {
                    return 0;
                }
            }
            #[cfg(not(target_os = "macos"))]
            {
                // No file-URL paste convention off macOS: the decoded image
                // itself goes on the clipboard (CF_DIB on Windows).
                let _ = id;
                if !platform::set_clipboard_image(png_data) {
                    return 0;
                }
            }
        }
    }
    let change_count = platform::change_count()
        .expect("CopyAttach: cannot identify self-written clipboard change");
    *b.pending_self_write.lock().unwrap() = Some(
        PendingSelfWrite { change_count },
    );
    drop(_event_guard);

    if let Some(b) = try_backend() {
        match b.db.lock() {
            Ok(mut conn) => {
                let png_for_db = match &db_item.0 {
                    ClipboardEntry::Image { png_data, .. } if !png_data.is_empty() => {
                        Some(png_data.as_slice())
                    }
                    _ => None,
                };
                let thumb_for_db = match &db_item.0 {
                    ClipboardEntry::Image { thumb_data, thumb_width, thumb_height, .. } if !thumb_data.is_empty() => {
                        Some((thumb_data.as_slice(), *thumb_width, *thumb_height))
                    }
                    _ => None,
                };

                match crate::db::persist_entry_to_db(
                    &mut conn,
                    &db_item.0,
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
    // Permission was already verified up front; here only the key event can fail.
    if !platform::simulate_paste(front_pid) {
        crate::error_log!("CopyAttach: simulate_paste failed");
        return 0;
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
    select_and_paste_impl(item)
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
    select_and_paste_impl(item)
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

#[cfg(all(test, target_os = "macos"))]
mod image_paste_target_tests {
    use super::image_target_needs_text_path;

    #[test]
    fn vs_code_targets_need_plain_text_paths() {
        assert!(image_target_needs_text_path("com.microsoft.VSCode"));
        assert!(image_target_needs_text_path("com.microsoft.VSCodeInsiders"));
        assert!(image_target_needs_text_path("com.microsoft.VSCodeExploration"));
        assert!(image_target_needs_text_path("com.visualstudio.code.oss"));
        assert!(image_target_needs_text_path("com.vscodium"));
    }

    #[test]
    fn native_terminals_keep_file_url_paste() {
        assert!(!image_target_needs_text_path("com.mitchellh.ghostty"));
        assert!(!image_target_needs_text_path("com.apple.Terminal"));
        assert!(!image_target_needs_text_path("com.googlecode.iterm2"));
        assert!(!image_target_needs_text_path("net.kovidgoyal.kitty"));
        assert!(!image_target_needs_text_path(""));
    }
}
