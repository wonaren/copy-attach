use std::ffi::{c_char, c_int, CString};
use std::sync::atomic::Ordering;

use crate::backend::{try_backend, DEFAULT_CLEANUP_THRESHOLD, HISTORY_REVISION, IMAGE_ENCODING_COUNTER};
use crate::macos;
use super::vec_to_raw;

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let Some(b) = try_backend() else { return 0 };
    b.history.lock().unwrap().len() as c_int
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

// Image Loading (by db_id)

/// Load full image directly by database row id (no history lock).
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_full_by_db_id(db_id: i64, out_len: *mut c_int) -> *mut u8 {
    if db_id == 0 || out_len.is_null() {
        return std::ptr::null_mut();
    }

    let Some(b) = try_backend() else { return std::ptr::null_mut() };
    let data = match b.db.lock() {
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

    // Same blob-read contract as preview/paste/undo.
    if !crate::backend::claim_pages(data.as_ptr(), data.capacity()) {
        crate::error_log!("CopyAttach: full image blob for db_id={db_id} could not be claimed — returning null");
        return std::ptr::null_mut();
    }
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

    let Some(b) = try_backend() else { return std::ptr::null_mut() };
    let perf = crate::perf::PerfSpan::start("rust", "thumb.load_db");
    let thumb_data = match b.db.lock() {
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

    // Same blob-read contract as preview/paste/undo.
    if !crate::backend::claim_pages(thumb_data.as_ptr(), thumb_data.capacity()) {
        crate::error_log!("CopyAttach: thumbnail blob for db_id={db_id} could not be claimed — returning null");
        return std::ptr::null_mut();
    }
    if let Some(mut span) = perf {
        span.val = Some(thumb_data.len() as i64);
    }
    let len = thumb_data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

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

    let perf = crate::perf::PerfSpan::start("rust", "preview.decode");

    let Some(b) = try_backend() else { return std::ptr::null_mut() };
    let png: Vec<u8> = match b.db.lock() {
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
    // Claim pages before the decoder reads the blob; an unclaimable blob is
    // reported as a decode failure rather than decoded from reclaimable pages.
    if !crate::backend::claim_pages(png.as_ptr(), png.capacity()) {
        crate::error_log!("CopyAttach: preview blob for db_id={db_id} could not be claimed — returning null");
        return std::ptr::null_mut();
    }
    let png_guard = crate::backend::MarkBlobReusableOnDrop(png);
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
                // Claim pages before Swift owns the long-lived buffer. This buffer
                // is delivered to the UI as a CGImage and lives until the preview
                // closes, so it must never be reclaimable: an unclaimable one is
                // released and reported as a decode failure.
                if !crate::backend::claim_pages(dst, byte_len) {
                    crate::error_log!("CopyAttach: preview buffer for db_id={db_id} could not be claimed — returning null");
                    unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                    return std::ptr::null_mut();
                }
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
                    if !crate::backend::claim_pages(dst, byte_len) {
                        crate::error_log!("CopyAttach: preview buffer for db_id={db_id} could not be claimed — returning null");
                        crate::backend::mark_pages_reusable(rgba.as_ptr(), rgba.capacity());
                        unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                        return std::ptr::null_mut();
                    }
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
            if let Some(mut span) = perf {
                span.val = Some(byte_len as i64);
            }
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
    if data.is_null() || len < 0 { return; }
    // Mark pages reusable before freeing (small/unaligned buffers are no-ops).
    crate::backend::mark_pages_reusable(data, len as usize);
    let slice_ptr = std::ptr::slice_from_raw_parts_mut(data, len as usize);
    unsafe { drop(Box::from_raw(slice_ptr)); }
}

// Cleanup Threshold

#[no_mangle]
pub extern "C" fn clipboard_get_cleanup_threshold() -> i32 {
    try_backend()
        .map_or(DEFAULT_CLEANUP_THRESHOLD as i32, |b| b.cleanup_threshold.load(Ordering::Relaxed) as i32)
}

/// Clamped to [100, 10000]. Immediately trims both DB and in-memory history.
///
/// Conforms to the "DB failure leaves memory intact" contract: the DB trim
/// is executed first. If the DB operation fails (e.g. read-only or locked),
/// in-memory history is left untouched so entries never "resurrect" on restart.
#[no_mangle]
pub extern "C" fn clipboard_set_cleanup_threshold(threshold: i32) {
    if let Some(b) = try_backend() {
        let t = threshold.clamp(100, 10000) as usize;
        b.cleanup_threshold.store(t, Ordering::Relaxed);

        // Step 1: trim DB first. If DB fails, leave memory intact.
        let db_trimmed = match b.db.lock() {
            Ok(conn) => match crate::db::trim_db_history(&conn, t) {
                Ok(()) => true,
                Err(()) => {
                    crate::error_log!("CopyAttach: set_cleanup_threshold DB trim failed — history left intact");
                    false
                }
            },
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned in set_cleanup_threshold: {e} — history left intact");
                false
            }
        };

        // Step 2: only trim memory when DB trim succeeded.
        if db_trimmed {
            let mut hist = b.history.lock().unwrap();
            let before = hist.len();
            while hist.len() > t {
                hist.pop();
            }
            if hist.len() != before {
                crate::backend::mark_history_changed();
            }
        }
    }
}

// Storage & Permissions

/// Release unused SQLite page-cache memory back to the OS. Safe to call only
/// when no transaction is active; the popup-close path invokes this after the
/// monitor has gone idle, so the next search/thumbnail read simply rebuilds the
/// (bounded, ≤4MB) cache from disk.
#[no_mangle]
pub extern "C" fn clipboard_shrink_db_memory() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in shrink_db_memory: {e}");
            return 0;
        }
    };
    match conn.execute_batch("PRAGMA shrink_memory;") {
        Ok(()) => {
            crate::debug_log!("CopyAttach: shrink_db_memory ok");
            1
        }
        Err(e) => {
            crate::error_log!("CopyAttach: shrink_db_memory failed: {e}");
            0
        }
    }
}

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
