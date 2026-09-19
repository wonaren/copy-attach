use std::ffi::{c_char, c_int};
use std::sync::atomic::Ordering;
use std::time::Duration;

use arboard::Clipboard;

use crate::backend::{try_backend, copyattach_temp_root, mark_history_changed, PendingSelfWrite};
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

/// Maximum age for a materialized drag PNG.
///
/// The drag file is referenced by the pasteboard for the duration of the drag
/// session, and a drop destination may finish consuming it slightly after the
/// gesture ends — so it needs the same grace window as a paste, not "until the
/// next drag". That previous rule was a leak in practice: a user who dragged an
/// image once and never dragged another left the file in $TMPDIR indefinitely
/// (measured: a 207 KB PNG from the previous day still present across several
/// restarts). The TTL plus the startup sweep bounds it the same way `Paste` is
/// bounded.
const DRAG_IMAGE_TTL: Duration = Duration::from_secs(60);


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
    purge_age_out(copyattach_temp_root().join("Paste"), PASTE_IMAGE_TTL);
}

/// Purge materialized drag PNGs older than [`DRAG_IMAGE_TTL`].
///
/// Runs at backend init (a long stretch without image drags would otherwise
/// leave the last drag's file until the OS cleans $TMPDIR) and is exposed to
/// Swift, which calls it as each new drag materializes its file — the same
/// write-then-sweep order the paste path uses, so the file the current drag
/// references is never the one removed.
pub(crate) fn purge_stale_drag_images() {
    purge_age_out(copyattach_temp_root().join("Drag"), DRAG_IMAGE_TTL);
}

/// Delete files under `dir` whose mtime is at least `ttl` old. Missing
/// directory is not an error: it just means nothing was ever materialized.
pub(crate) fn purge_age_out(dir: std::path::PathBuf, ttl: Duration) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let Ok(entries) = std::fs::read_dir(&dir) else { return };
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(modified) = meta.modified() else { continue };
        let Ok(mtime) = modified.duration_since(std::time::UNIX_EPOCH) else { continue };
        if now.saturating_sub(mtime) >= ttl {
            if let Err(e) = std::fs::remove_file(entry.path()) {
                crate::debug_log!("CopyAttach: failed to purge stale temp file {}: {e}", entry.path().display());
            }
        }
    }
}

/// FFI: sweep aged-out drag images. Called by the drag provider right after it
/// materializes a new file, so the directory is bounded without a timer.
#[no_mangle]
pub extern "C" fn clipboard_purge_stale_drag_images() {
    purge_stale_drag_images();
}

// NOTE: the former single-phase select_and_paste_impl() lived here. It
// slept 50 ms on the caller thread between writing the pasteboard and posting
// Cmd+V, on the assumption that the popup would resign key on its own. That
// assumption is exactly what the two-phase split exists to reject: the popup
// is a canBecomeKey nonactivating panel and only close() resigns key, so the
// keystroke could arrive while the panel was still key (measured 7/7; WeChat
// dropped short pastes). It also blocked the main thread. The popup uses
// clipboard_prepare_paste_by_id + clipboard_send_paste instead, and nothing
// else called this, so it was removed rather than left as a trap.

/// Loads full image data from DB if needed, writes to the system clipboard,
/// write-through DB, and moves the item to the top of history — everything a
/// paste needs except the keystroke itself.
///
/// Returns the pid the paste keystroke must be delivered to, or 0 on failure
/// (in which case the pasteboard may or may not have been written, but no
/// keystroke may be sent).
/// When `as_path` is true and the entry is an Image, its temp PNG path is
/// placed on the clipboard as plain text instead of `public.file-url`.
fn prepare_paste_impl(mut item: ClipboardEntry, as_path: bool) -> c_int {
    let perf_total = crate::perf::PerfSpan::start("rust", "paste.prepare");
    if let Some(mut span) = perf_total {
        span.data = Some(if as_path { "path".to_string() } else { "normal".to_string() });
    }
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
            let Some(b) = try_backend() else { return 0 };
            let perf_text = crate::perf::PerfSpan::start("rust", "paste.load_text");
            match b.db.lock() {
                Ok(conn) => match load_text_by_db_id(&conn, *db_id) {
                    Some(t) => {
                        if let Some(mut span) = perf_text {
                            span.val = Some(t.len() as i64);
                        }
                        Some(crate::backend::MarkStringReusableOnDrop(t))
                    }
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
            let Some(b) = try_backend() else { return 0 };
            let conn = match b.db.lock() {
                Ok(c) => c,
                Err(e) => {
                    crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste image load: {e}");
                    return 0;
                }
            };
            let perf_blob = crate::perf::PerfSpan::start("rust", "paste.load_image_blobs");
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
                    if let Some(mut span) = perf_blob {
                        span.val = Some(png.len() as i64);
                    }
                    // Claim any reusable-marked pages the allocator handed
                    // back: these blobs are written to the pasteboard, and a
                    // rejected claim means the pasted payload could be read from
                    // reclaimable pages. Refuse the paste (callers already treat
                    // 0 as "nothing pasted").
                    if !crate::backend::claim_pages(png.as_ptr(), png.capacity())
                        || !crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity())
                    {
                        crate::error_log!("CopyAttach: paste image blobs for entry {id} could not be claimed — paste aborted");
                        return 0;
                    }
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
    let Some(b) = try_backend() else { return 0 };
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
            let perf_write = crate::perf::PerfSpan::start("rust", "paste.write_temp_png");
            if let Some(mut span) = perf_write {
                span.val = Some(blobs.png.len() as i64);
            }
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
    // A missing pasteboard is a real (if rare) failure. Without the changeCount
    // the self-write cannot be suppressed, so the monitor would re-capture our
    // own paste as a new entry. Refuse the paste instead of panicking: the
    // pasteboard was written, but no keystroke is sent, so nothing is pasted
    // and no duplicate is captured. Explicit failure, never a crash.
    let change_count = match macos::pasteboard_change_count() {
        Some(cc) => cc,
        None => {
            crate::error_log!("CopyAttach: pasteboard changeCount unavailable — paste aborted to avoid self re-capture");
            return 0;
        }
    };
    *b.pending_self_write.lock().unwrap() = Some(
        PendingSelfWrite { change_count },
    );
    drop(_event_guard);

    // The DB write-through and the in-memory write-through must happen under
    // ONE DB lock. Releasing it in between lets a concurrent same-content
    // insert (monitor capture or image Phase 2) dedup the row we just
    // committed before our memory update lands, leaving the entry pointing at
    // a deleted row — a ghost the UI can neither preview, paste, nor delete.
    // Every other DB writer (monitor text capture, Phase 2, undo) already
    // holds the DB lock across its memory write; this path was the only one
    // that did not.
    let Some(b) = try_backend() else { return 0 };
    let mut db_guard = match b.db.lock() {
        Ok(c) => Some(c),
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste persist: {e} — entry stays with db_id=0");
            None
        }
    };
    if let Some(conn) = db_guard.as_mut() {
        let png_for_db = image_blobs.as_ref().map(|b| b.png.as_slice());
        let thumb_for_db = image_blobs.as_ref().and_then(|b| {
            image_thumb_dims.map(|(tw, th)| (b.thumb.as_slice(), tw, th))
        });

        match crate::db::persist_entry_to_db(
            conn,
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

    {
        let mut hist = b.history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), item);
        while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
            hist.pop();
        }
        mark_history_changed();
    }
    // Release the DB lock before returning so the capture monitor is never
    // blocked while the caller dismisses the window and sends keystrokes.
    drop(db_guard);

    // The caller owns the keystroke: it must not be posted until the popup has
    // resigned key status (see `clipboard_prepare_paste_by_id`).
    try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .map_or(0, |src| src.pid)
}

/// Phase 1 of a two-phase paste: write the entry to the pasteboard and update
/// history, but do NOT post the paste keystroke yet. Returns the pid that
/// phase 2 must deliver to (>0), or 0 on failure.
///
/// The split exists because the paste keystroke must arrive when the popup is
/// no longer the key window. Only `close()` resigns key status, and it runs
/// after the paste call — so a single-phase paste always posted the keystroke
/// while the panel was still key. Measured via PASTEDIAG (2026-09-12):
/// `popupKey=true` on every paste, and a target that resolves the paste against
/// its own key window (WeChat) intermittently dropped short-text pastes.
/// Callers MUST dismiss the popup between phase 1 and phase 2.
#[no_mangle]
pub extern "C" fn clipboard_prepare_paste_by_id(entry_id: u64, as_path: bool) -> c_int {
    let item = {
        let Some(b) = try_backend() else { return 0 };
        let hist = b.history.lock().unwrap();
        match hist.iter().find(|e| match e {
            ClipboardEntry::Text { id, .. } => *id == entry_id,
            ClipboardEntry::Image { id, .. } => *id == entry_id,
        }).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    prepare_paste_impl(item, as_path)
}

/// Phase 2 of a two-phase paste: post the paste keystroke to `pid` (the value
/// returned by phase 1). Returns 1 on success, 0 if the event could not be
/// posted.
///
/// A non-positive `pid` needs no guard here: `simulate_cmd_v` already refuses
/// it, so a failed phase 1 cannot cause a keystroke.
#[no_mangle]
pub extern "C" fn clipboard_send_paste(pid: c_int) -> c_int {
    #[cfg(target_os = "macos")]
    {
        if !macos::simulate_cmd_v(pid) {
            crate::error_log!("CopyAttach: clipboard_send_paste: simulate_cmd_v failed");
            return 0;
        }
        1
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = pid;
        0
    }
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

