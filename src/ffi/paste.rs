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

const PASTE_IMAGE_TTL: Duration = Duration::from_secs(60);

const DRAG_IMAGE_TTL: Duration = Duration::from_secs(60);

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

pub(crate) fn purge_stale_paste_images() {
    purge_age_out(copyattach_temp_root().join("Paste"), PASTE_IMAGE_TTL);
}

pub(crate) fn purge_stale_drag_images() {
    purge_age_out(copyattach_temp_root().join("Drag"), DRAG_IMAGE_TTL);
}

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

#[no_mangle]
pub extern "C" fn clipboard_purge_stale_drag_images() {
    purge_stale_drag_images();
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PasteDelivery {
    Keystroke,
    ClipboardOnly,
}

impl PasteDelivery {
    fn from_ffi(mode: c_int) -> Option<Self> {
        match mode {
            0 => Some(Self::Keystroke),
            1 => Some(Self::ClipboardOnly),
            _ => None,
        }
    }
}

fn prepare_paste_impl(mut item: ClipboardEntry, as_path: bool, delivery: PasteDelivery) -> c_int {
    let perf_total = crate::perf::PerfSpan::start("rust", "paste.prepare");
    if let Some(mut span) = perf_total {
        span.data = Some(match (delivery, as_path) {
            (PasteDelivery::ClipboardOnly, _) => "clipboard".to_string(),
            (PasteDelivery::Keystroke, true) => "path".to_string(),
            (PasteDelivery::Keystroke, false) => "normal".to_string(),
        });
    }
    #[cfg(target_os = "macos")]
    {
        if delivery == PasteDelivery::Keystroke && !macos::check_permission() {
            crate::error_log!("CopyAttach: accessibility permission not granted — paste aborted, clipboard untouched");
            return 0;
        }
    }

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

    let Some(b) = try_backend() else { return 0 };
    let _event_guard = b.pasteboard_event_lock.lock().unwrap();
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

    let Some(b) = try_backend() else { return 0 };
    let mut db_guard = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in select_and_paste persist: {e} — paste aborted");
            return 0;
        }
    };
    let png_for_db = image_blobs.as_ref().map(|b| b.png.as_slice());
    let thumb_for_db = image_blobs.as_ref().and_then(|b| {
        image_thumb_dims.map(|(tw, th)| (b.thumb.as_slice(), tw, th))
    });

    let new_row_id = match crate::db::persist_entry_to_db(
        &mut db_guard,
        &item,
        full_text.as_ref().map(|g| g.0.as_str()),
        png_for_db,
        thumb_for_db,
        b.cleanup_threshold.load(Ordering::Relaxed),
    ) {
        Ok(id) => id,
        Err(()) => {
            crate::error_log!("CopyAttach: select_and_paste DB insert failed — paste aborted");
            return 0;
        }
    };

    match &mut item {
        ClipboardEntry::Image { ref mut db_id, .. } |
        ClipboardEntry::Text { ref mut db_id, .. } => {
            *db_id = new_row_id;
        }
    }

    {
        let mut hist = b.history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), item);
        {
            let favorites = b.favorites.lock().unwrap();
            crate::backend::trim_history_memory(
                &mut hist,
                b.cleanup_threshold.load(Ordering::Relaxed),
                &favorites,
            );
        }
        mark_history_changed();
    }
    drop(db_guard);

    if delivery == PasteDelivery::ClipboardOnly {
        return 1;
    }

    match try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .map(|src| src.pid)
    {
        Some(pid) if pid > 0 => pid,
        _ => {
            crate::error_log!("CopyAttach: paste written but no target pid — keystroke skipped");
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_prepare_paste_by_id(entry_id: u64, as_path: bool, delivery_mode: c_int) -> c_int {
    let Some(delivery) = PasteDelivery::from_ffi(delivery_mode) else {
        crate::error_log!("CopyAttach: clipboard_prepare_paste_by_id: unknown delivery_mode {delivery_mode} — aborted");
        return 0;
    };
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
    prepare_paste_impl(item, as_path, delivery)
}

#[no_mangle]
pub extern "C" fn clipboard_send_paste(pid: c_int) -> c_int {
    #[cfg(target_os = "macos")]
    {
        if !macos::simulate_cmd_v(pid) {
            crate::error_log!("CopyAttach: clipboard_send_paste: simulate_cmd_v failed");
            return 0;
        }
        crate::debug_log!("CopyAttach: send_paste delivered ⌘V to pid {pid}");
        1
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = pid;
        0
    }
}

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
    let guard = crate::backend::MarkStringReusableOnDrop(text);
    to_ffi_cstring(&guard.0)
}
