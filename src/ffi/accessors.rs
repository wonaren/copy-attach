use std::ffi::{c_char, c_int, c_longlong, CString};
use std::sync::atomic::Ordering;

use crate::backend::{backend, try_backend, DEFAULT_CLEANUP_THRESHOLD, HISTORY_REVISION, IMAGE_ENCODING_COUNTER};
use crate::db::load_text_by_db_id;
use crate::macos;
use crate::types::ClipboardEntry;
use super::{to_ffi_cstring, vec_to_raw};

// ═══════════════════════════════════════════
// Legacy Index-Based Accessors
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.len() as c_int
}

/// Returns a monotonically increasing counter that increments each time a
/// Phase 2 image encoding finishes and updates `db_id` in memory. Swift uses
/// this to detect thumbnail-ready items without a change in entry count.
#[no_mangle]
pub extern "C" fn clipboard_get_image_encoding_counter() -> u64 {
    IMAGE_ENCODING_COUNTER.load(Ordering::Relaxed)
}

/// Monotonic revision of in-memory history ordering and metadata.
#[no_mangle]
pub extern "C" fn clipboard_get_history_revision() -> u64 {
    HISTORY_REVISION.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_type(index: c_int) -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(-1, ClipboardEntry::content_type)
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_timestamp(index: c_int) -> c_longlong {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(0, |item| item.timestamp() as c_longlong)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_name(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let name = match hist.get(index as usize) {
        Some(item) => item.source_name(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(name)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_bundle_id(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let bid = match hist.get(index as usize) {
        Some(item) => item.source_bundle_id(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(bid)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_label(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let label = match hist.get(index as usize) {
        Some(item) => item.label(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(&label)
}

/// Get text content by array index. Full text lives in SQLite, not the history
/// Vec — resolve the entry's db_id in memory, then load the body from DB.
/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_text(index: c_int) -> *mut c_char {
    let b = backend();
    let db_id = {
        let hist = b.history.lock().unwrap();
        match hist.get(index as usize) {
            Some(ClipboardEntry::Text { db_id, .. }) => *db_id,
            _ => return std::ptr::null_mut(),
        }
    };
    if db_id == 0 {
        return std::ptr::null_mut();
    }
    match b.db.lock() {
        Ok(conn) => match load_text_by_db_id(&conn, db_id) {
            Some(t) => to_ffi_cstring(&t),
            None => std::ptr::null_mut(),
        },
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading text at index {index}: {e}");
            std::ptr::null_mut()
        }
    }
}

// ═══════════════════════════════════════════
// Image Loading (Index-Based & by db_id)
// ═══════════════════════════════════════════

/// Load thumbnail by array index. Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_thumb(index: c_int, out_len: *mut c_int) -> *mut u8 {
    if out_len.is_null() { return std::ptr::null_mut(); }

    let db_id = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize) {
            Some(ClipboardEntry::Image { db_id, .. }) => *db_id,
            _ => return std::ptr::null_mut(),
        }
    };

    if db_id == 0 {
        return std::ptr::null_mut();
    }

    let thumb_data = match backend().db.lock() {
        Ok(conn) => {
            match conn.query_row(
                "SELECT thumb_data FROM clipboard_history WHERE id = ?",
                rusqlite::params![db_id],
                |row| row.get::<_, Vec<u8>>(0),
            ) {
                Ok(data) => data,
                Err(e) => {
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = thumb_data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

/// Load full image by array index. Checks in-memory cache first, then `SQLite`.
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_full(index: c_int, out_len: *mut c_int) -> *mut u8 {
    if out_len.is_null() { return std::ptr::null_mut(); }

    let (png_data, db_id) = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize) {
            Some(ClipboardEntry::Image { png_data, db_id, .. }) => {
                (png_data.clone(), *db_id)
            }
            _ => return std::ptr::null_mut(),
        }
    };

    let data = if !png_data.is_empty() {
        png_data
    } else if db_id != 0 {
        match backend().db.lock() {
            Ok(conn) => {
                match conn.query_row(
                    "SELECT png_data FROM clipboard_history WHERE id = ?",
                    rusqlite::params![db_id],
                    |row| row.get(0),
                ) {
                    Ok(data) => data,
                    Err(e) => {
                        eprintln!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                        return std::ptr::null_mut();
                    }
                }
            }
            Err(e) => {
                eprintln!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
                return std::ptr::null_mut();
            }
        }
    } else {
        return std::ptr::null_mut();
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

/// Load full image directly by database row id.
/// Pure SQLite load — the in-memory history entries never hold `png_data`
/// (metadata only, see the memory invariant), so there is no cache to consult
/// and no history lock is touched. Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_full_by_db_id(db_id: i64, out_len: *mut c_int) -> *mut u8 {
    if db_id == 0 || out_len.is_null() {
        return std::ptr::null_mut();
    }

    let data = match backend().db.lock() {
        Ok(conn) => {
            match conn.query_row(
                "SELECT png_data FROM clipboard_history WHERE id = ?",
                rusqlite::params![db_id],
                |row| row.get::<_, Vec<u8>>(0),
            ) {
                Ok(data) => data,
                Err(e) => {
                    eprintln!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

/// Load thumbnail directly by database row id. Does NOT touch the history lock.
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_thumb_by_db_id(db_id: i64, out_len: *mut c_int) -> *mut u8 {
    if db_id == 0 || out_len.is_null() {
        return std::ptr::null_mut();
    }

    let thumb_data = match backend().db.lock() {
        Ok(conn) => {
            match conn.query_row(
                "SELECT thumb_data FROM clipboard_history WHERE id = ?",
                rusqlite::params![db_id],
                |row| row.get::<_, Vec<u8>>(0),
            ) {
                Ok(data) => data,
                Err(e) => {
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = thumb_data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

// ═══════════════════════════════════════════
// Image Size
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_image_size(index: c_int, out_width: *mut c_int, out_height: *mut c_int) -> c_int {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Image { width, height, .. }) => {
            if !out_width.is_null() { unsafe { *out_width = *width as c_int; } }
            if !out_height.is_null() { unsafe { *out_height = *height as c_int; } }
            1
        }
        _ => 0,
    }
}

// ═══════════════════════════════════════════
// Memory Management Helpers
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_free_string(s: *mut c_char) {
    if s.is_null() { return; }
    unsafe { let _ = CString::from_raw(s); }
}

#[no_mangle]
pub extern "C" fn clipboard_free_bytes(data: *mut u8, len: c_int) {
    if data.is_null() { return; }
    unsafe { let _ = Vec::from_raw_parts(data, len as usize, len as usize); }
}

// ═══════════════════════════════════════════
// Cleanup Threshold
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_cleanup_threshold() -> i32 {
    try_backend()
        .map_or(DEFAULT_CLEANUP_THRESHOLD as i32, |b| b.cleanup_threshold.load(Ordering::Relaxed) as i32)
}

/// Clamped to [100, 10000]. Immediately trims both DB and in-memory history.
#[no_mangle]
pub extern "C" fn clipboard_set_cleanup_threshold(threshold: i32) {
    if let Some(b) = try_backend() {
        let t = threshold.clamp(100, 10000) as usize;
        b.cleanup_threshold.store(t, Ordering::Relaxed);
        {
            let mut hist = b.history.lock().unwrap();
            while hist.len() > t {
                hist.pop();
            }
        }
        if let Ok(conn) = b.db.lock() {
            crate::db::trim_db_history(&conn, t);
        }
    }
}

// ═══════════════════════════════════════════
// Storage & Permissions
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_storage_size() -> i64 {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned in get_storage_size: {e}");
            return 0;
        }
    };
    match conn.query_row(
        "SELECT COALESCE(SUM(LENGTH(text)), 0) + COALESCE(SUM(LENGTH(png_data)), 0) + COALESCE(SUM(LENGTH(thumb_data)), 0) FROM clipboard_history",
        [],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(size) => size,
        Err(e) => {
            eprintln!("CopyAttach: failed to query storage size: {e}");
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_check_permission() -> c_int {
    #[cfg(target_os = "macos")]
    { c_int::from(macos::check_permission()) }
    #[cfg(not(target_os = "macos"))]
    { 1 }
}

#[no_mangle]
pub extern "C" fn clipboard_open_preferences() {
    #[cfg(target_os = "macos")]
    macos::open_preferences();
}

/// Reload the in-memory history from the database using the current cleanup
/// threshold.  Useful after changing the threshold or injecting test data.
/// Returns the number of entries loaded.
#[no_mangle]
pub extern "C" fn clipboard_reload_history() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    // Verify DB lock is healthy before calling the shared helper.
    if b.db.lock().is_err() {
        return 0;
    }
    crate::backend::reload_history_from_db(b) as c_int
}
