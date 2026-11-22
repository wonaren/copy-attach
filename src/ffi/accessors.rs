use std::ffi::{c_char, c_int, CString};
use std::sync::atomic::Ordering;

use crate::backend::{try_backend, DEFAULT_CLEANUP_THRESHOLD, HISTORY_REVISION, IMAGE_ENCODING_COUNTER};
use crate::macos;
use super::vec_to_raw;

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let Some(b) = try_backend() else { return 0 };
    let Ok(hist) = b.history.lock() else { return 0 };
    crate::history::visible_history(&hist).len() as c_int
}

#[no_mangle]
pub extern "C" fn clipboard_get_image_encoding_counter() -> u64 {
    IMAGE_ENCODING_COUNTER.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn clipboard_get_history_revision() -> u64 {
    HISTORY_REVISION.load(Ordering::Relaxed)
}

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

    if !crate::backend::claim_pages(data.as_ptr(), data.capacity()) {
        crate::error_log!("CopyAttach: full image blob for db_id={db_id} could not be claimed — returning null");
        return std::ptr::null_mut();
    }
    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

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

#[no_mangle]
pub extern "C" fn clipboard_preview_dims(
    width: c_int,
    height: c_int,
    max_dim: c_int,
    out_w: *mut c_int,
    out_h: *mut c_int,
) -> c_int {
    if out_w.is_null() || out_h.is_null() || width <= 0 || height <= 0 {
        return 0;
    }
    let (w, h) = crate::image::resize_dims(width as u32, height as u32, max_dim.max(0) as u32);
    unsafe {
        *out_w = w as c_int;
        *out_h = h as c_int;
    }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_decode_preview_into(
    db_id: i64,
    max_dim: c_int,
    dst: *mut u8,
    dst_len: c_int,
    stride: c_int,
    out_w: *mut c_int,
    out_h: *mut c_int,
    out_is_gif: *mut c_int,
) -> c_int {
    if db_id == 0
        || dst.is_null()
        || dst_len <= 0
        || stride <= 0
        || out_w.is_null()
        || out_h.is_null()
        || out_is_gif.is_null()
    {
        return 0;
    }
    unsafe {
        *out_w = 0;
        *out_h = 0;
        *out_is_gif = 0;
    }
    crate::debug_log!("CopyAttach: preview_decode db_id={db_id} max_dim={max_dim} stride={stride}");

    let perf = crate::perf::PerfSpan::start("rust", "preview.decode");

    let Some(b) = try_backend() else { return 0 };
    let png: Vec<u8> = match b.db.lock() {
        Ok(conn) => match conn.query_row(
            "SELECT png_data FROM clipboard_history WHERE id = ? AND entry_type = 1",
            rusqlite::params![db_id],
            |row| row.get::<_, Vec<u8>>(0),
        ) {
            Ok(data) => data,
            Err(e) => {
                crate::error_log!("CopyAttach: failed to load png for preview db_id={db_id}: {e}");
                return 0;
            }
        },
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned loading png for preview db_id={db_id}: {e}");
            return 0;
        }
    };
    if !crate::backend::claim_pages(png.as_ptr(), png.capacity()) {
        crate::error_log!("CopyAttach: preview blob for db_id={db_id} could not be claimed — returning null");
        return 0;
    }
    let png_guard = crate::backend::MarkBlobReusableOnDrop(png);
    let png = &png_guard.0;
    if png.is_empty() {
        crate::debug_log!("CopyAttach: preview db_id={db_id}: stored png_data is empty");
        return 0;
    }
    if png.starts_with(&[0x47, 0x49, 0x46, 0x38]) {
        unsafe { *out_is_gif = 1 };
        return 0;
    }

    let Some((src_w, src_h)) = crate::image::stream_png_dims(png) else {
        crate::debug_log!("CopyAttach: preview db_id={db_id} has an unsupported png");
        return 0;
    };
    let (dw, dh) = crate::image::resize_dims(src_w, src_h, max_dim.max(0) as u32);
    let stride = stride as usize;
    let dst_len = dst_len as usize;
    if stride < (dw as usize) * 4 || dst_len < stride * (dh as usize - 1) + (dw as usize) * 4 {
        crate::error_log!("CopyAttach: preview dst too small db_id={db_id} dst={dst_len} stride={stride}");
        return 0;
    }
    let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_len) };
    if crate::image::stream_resize_preview_into(png, dw, dh, dst_slice, stride).is_none() {
        crate::debug_log!("CopyAttach: preview stream failed db_id={db_id}");
        return 0;
    }

    crate::debug_log!("CopyAttach: preview_decode done db_id={db_id} w={dw} h={dh} stride={stride}");
    if let Some(mut span) = perf {
        span.val = Some(stride as i64 * dh as i64);
    }
    unsafe {
        *out_w = dw as c_int;
        *out_h = dh as c_int;
    }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_free_string(s: *mut c_char) {
    if s.is_null() { return; }
    let byte_len = unsafe { std::ffi::CStr::from_ptr(s).to_bytes().len() + 1 };
    crate::backend::mark_pages_reusable(s as *const u8, byte_len);
    unsafe { let _ = CString::from_raw(s); }
}

#[no_mangle]
pub extern "C" fn clipboard_free_bytes(data: *mut u8, len: c_int) {
    if data.is_null() || len < 0 { return; }
    crate::backend::mark_pages_reusable(data, len as usize);
    let slice_ptr = std::ptr::slice_from_raw_parts_mut(data, len as usize);
    unsafe { drop(Box::from_raw(slice_ptr)); }
}

#[no_mangle]
pub extern "C" fn clipboard_get_cleanup_threshold() -> i32 {
    try_backend()
        .map_or(DEFAULT_CLEANUP_THRESHOLD as i32, |b| b.cleanup_threshold.load(Ordering::Relaxed) as i32)
}

#[no_mangle]
pub extern "C" fn clipboard_set_cleanup_threshold(threshold: i32) -> c_int {
    let Some(b) = try_backend() else { return 0 };
    let t = threshold.clamp(
        crate::backend::MIN_CLEANUP_THRESHOLD as i32,
        crate::backend::MAX_CLEANUP_THRESHOLD as i32,
    ) as usize;
    let conn = match b.db.lock() {
        Ok(conn) => conn,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in set_cleanup_threshold: {e}");
            return 0;
        }
    };
    let Ok(mut hist) = b.history.lock() else {
        crate::error_log!("CopyAttach: history mutex poisoned in set_cleanup_threshold");
        return 0;
    };
    let Ok(removed) = crate::db::trim_db_history(&conn, t) else { return 0 };
    b.cleanup_threshold.store(t, Ordering::Relaxed);
    if !removed.is_empty() {
        hist.retain(|entry| !removed.contains(&entry.db_id()));
        crate::backend::mark_history_changed();
    }
    1
}

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
pub extern "C" fn clipboard_get_storage_breakdown(
    text_bytes: *mut i64,
    image_bytes: *mut i64,
    undo_bytes: *mut i64,
) -> c_int {
    if text_bytes.is_null() || image_bytes.is_null() || undo_bytes.is_null() {
        return 0;
    }
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in get_storage_breakdown: {e}");
            return 0;
        }
    };
    match crate::db::storage_breakdown(&conn) {
        Ok((text, image, undo)) => {
            unsafe {
                *text_bytes = text;
                *image_bytes = image;
                *undo_bytes = undo;
            }
            1
        }
        Err(()) => 0,
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
