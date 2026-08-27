use std::ffi::{c_char, c_int, c_longlong, CString};
use std::sync::atomic::Ordering;

use crate::backend::{backend, try_backend, DEFAULT_CLEANUP_THRESHOLD, HISTORY_REVISION, IMAGE_ENCODING_COUNTER};
use crate::db::load_text_by_db_id;
use crate::macos;
use crate::types::ClipboardEntry;
use super::{to_ffi_cstring, vec_to_raw};

// Legacy Index-Based Accessors

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.len() as c_int
}

/// Monotonic counter bumped when Phase 2 image encoding finishes.
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

/// Get text by index, loading the body from SQLite.
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
            // The guard marks the body's pages reusable on drop — the text is
            // transient here (copied into the FFI CString).
            Some(t) => {
                let guard = crate::backend::MarkStringReusableOnDrop(t);
                to_ffi_cstring(&guard.0)
            }
            None => std::ptr::null_mut(),
        },
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading text at index {index}: {e}");
            std::ptr::null_mut()
        }
    }
}

// Image Loading (Index-Based & by db_id)

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
                    crate::debug_log!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
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
                        crate::error_log!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                        return std::ptr::null_mut();
                    }
                }
            }
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
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

/// Load full image directly by database row id (no history lock).
/// Caller must free with `clipboard_free_bytes()`.
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
                    crate::error_log!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

/// Load thumbnail directly by database row id (no history lock).
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
                    crate::debug_log!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = thumb_data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

use crate::backend::MarkBlobReusableOnDrop;

/// Decode a stored image downscaled to at most `max_dim`, returning an RGBA8
/// buffer owned by the caller (release via `clipboard_preview_buffer_release`).
/// Animated GIFs are flagged and returned as null so Swift can use NSImage(data:).
#[no_mangle]
pub extern "C" fn clipboard_decode_preview_by_db_id(
    db_id: i64,
    max_dim: c_int,
    out_len: *mut c_int,
    out_w: *mut c_int,
    out_h: *mut c_int,
    out_is_gif: *mut c_int,
) -> *mut u8 {
    if db_id == 0
        || out_len.is_null()
        || out_w.is_null()
        || out_h.is_null()
        || out_is_gif.is_null()
    {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len = 0;
        *out_w = 0;
        *out_h = 0;
        *out_is_gif = 0;
    }
    crate::debug_log!("CopyAttach: preview_decode db_id={db_id} max_dim={max_dim}");

    let png: Vec<u8> = match backend().db.lock() {
        Ok(conn) => match conn.query_row(
            "SELECT png_data FROM clipboard_history WHERE id = ? AND entry_type = 1",
            rusqlite::params![db_id],
            |row| row.get::<_, Vec<u8>>(0),
        ) {
            Ok(data) => data,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to load png for preview db_id={db_id}: {e}");
                return std::ptr::null_mut();
            }
        },
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading png for preview db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };
    // Claim pages before the decoder reads the blob.
    crate::backend::claim_pages(png.as_ptr(), png.capacity());
    let png_guard = MarkBlobReusableOnDrop(png);
    let png = &png_guard.0;
    if png.is_empty() {
        crate::debug_log!("CopyAttach: preview db_id={db_id}: stored png_data is empty");
        return std::ptr::null_mut();
    }
    // Let Swift handle animated GIFs via NSImage(data:) instead of decoding here.
    if png.starts_with(&[0x47, 0x49, 0x46, 0x38]) {
        unsafe { *out_is_gif = 1 };
        return std::ptr::null_mut();
    }

    let max_dim = max_dim.max(0) as u32;
    let layout_for = |byte_len: usize| {
        std::alloc::Layout::from_size_align(byte_len, 16)
            .expect("preview buffer layout must be valid")
    };

    // Decode into the pooled buffer or a fresh Vec; the delivered buffer is
    // a separate allocation owned by the caller.
    let mut pooled = crate::backend::ImageDecodeBuffer::acquire();
    let delivered: Option<(*mut u8, u32, u32, usize)> =
        if let Some((w, h)) = crate::image::decode_png_rgba8_into(png, pooled.as_mut_vec()) {
            let (dw, dh) = crate::image::resize_dims(w, h, max_dim);
            let byte_len = (dw as usize) * (dh as usize) * 4;
            let dst = unsafe { std::alloc::alloc(layout_for(byte_len)) };
            if dst.is_null() {
                crate::error_log!("CopyAttach: preview alloc failed for {byte_len} bytes");
                None
            } else {
                // Claim pages before Swift owns the long-lived buffer.
                crate::backend::claim_pages(dst, byte_len);
                if (dw, dh) == (w, h) {
                    unsafe { std::ptr::copy_nonoverlapping(pooled.as_ptr(), dst, byte_len) };
                } else if let Some(resized) =
                    crate::image::resize_rgba(&pooled, w, h, dw, dh)
                {
                    unsafe { std::ptr::copy_nonoverlapping(resized.as_ptr(), dst, byte_len) };
                    crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
                } else {
                    crate::debug_log!("CopyAttach: preview resize failed for db_id={db_id}");
                    unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                    return std::ptr::null_mut();
                }
                drop(pooled);
                Some((dst, dw, dh, byte_len))
            }
        } else {
            drop(pooled);
            match image::load_from_memory(png) {
                Ok(img) => {
                    let img = img.to_rgba8();
                    let (w, h) = img.dimensions();
                    let rgba = img.into_raw();
                    let (dw, dh) = crate::image::resize_dims(w, h, max_dim);
                    let byte_len = (dw as usize) * (dh as usize) * 4;
                    let dst = unsafe { std::alloc::alloc(layout_for(byte_len)) };
                    if dst.is_null() {
                        crate::error_log!("CopyAttach: preview alloc failed for {byte_len} bytes");
                        return std::ptr::null_mut();
                    }
                    crate::backend::claim_pages(dst, byte_len);
                    if (dw, dh) == (w, h) {
                        unsafe { std::ptr::copy_nonoverlapping(rgba.as_ptr(), dst, byte_len) };
                    } else if let Some(resized) = crate::image::resize_rgba(&rgba, w, h, dw, dh) {
                        unsafe { std::ptr::copy_nonoverlapping(resized.as_ptr(), dst, byte_len) };
                        crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
                    } else {
                        crate::debug_log!("CopyAttach: preview resize failed for db_id={db_id}");
                        unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                        return std::ptr::null_mut();
                    }
                    crate::backend::mark_pages_reusable(rgba.as_ptr(), rgba.capacity());
                    Some((dst, dw, dh, byte_len))
                }
                Err(e) => {
                    crate::debug_log!("CopyAttach: preview db_id={db_id} undecodable: {e}");
                    return std::ptr::null_mut();
                }
            }
        };

    match delivered {
        Some((ptr, w, h, byte_len)) => {
            crate::debug_log!("CopyAttach: preview_decode done db_id={db_id} w={w} h={h} bytes={byte_len} gif={}",
                unsafe { *out_is_gif });
            unsafe {
                *out_len = byte_len as c_int;
                *out_w = w as c_int;
                *out_h = h as c_int;
            }
            ptr
        }
        None => std::ptr::null_mut(),
    }
}

/// Release a preview buffer, marking its pages reusable before freeing.
#[no_mangle]
pub extern "C" fn clipboard_preview_buffer_release(ptr: *mut u8, len: c_int) {
    if ptr.is_null() || len <= 0 {
        return;
    }
    crate::debug_log!("CopyAttach: preview_buffer_release len={len} ptr=0x{:x}", ptr as usize);
    let byte_len = len as usize;
    crate::backend::mark_pages_reusable(ptr, byte_len);
    let layout = std::alloc::Layout::from_size_align(byte_len, 16)
        .expect("preview buffer layout must match the allocation");
    unsafe { std::alloc::dealloc(ptr, layout) }
}

// Image Size
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

// Memory Management Helpers

#[no_mangle]
pub extern "C" fn clipboard_free_string(s: *mut c_char) {
    if s.is_null() { return; }
    // Mark pages reusable before freeing, matching `clipboard_free_bytes`.
    let byte_len = unsafe { std::ffi::CStr::from_ptr(s).to_bytes().len() + 1 };
    crate::backend::mark_pages_reusable(s as *const u8, byte_len);
    unsafe { let _ = CString::from_raw(s); }
}

#[no_mangle]
pub extern "C" fn clipboard_free_bytes(data: *mut u8, len: c_int) {
    if data.is_null() { return; }
    // Mark pages reusable before freeing (small/unaligned buffers are no-ops).
    crate::backend::mark_pages_reusable(data, len as usize);
    unsafe { let _ = Vec::from_raw_parts(data, len as usize, len as usize); }
}

// Cleanup Threshold

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

// Storage & Permissions

#[no_mangle]
pub extern "C" fn clipboard_get_storage_size() -> i64 {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in get_storage_size: {e}");
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
            crate::error_log!("CopyAttach: failed to query storage size: {e}");
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

/// Reload in-memory history from the DB using the current cleanup threshold.
#[no_mangle]
pub extern "C" fn clipboard_reload_history() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    if b.db.lock().is_err() {
        return 0;
    }
    crate::backend::reload_history_from_db(b) as c_int
}
