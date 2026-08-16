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

/// Wraps the stored-blob `Vec` loaded for a preview decode: its pages are
/// marked reusable when it drops, on every exit path (the blob is read into
/// a fresh large-zone block that otherwise lingers as freed-but-retained
/// residue — same class as the ImageIO decode buffers this FFI replaces).
struct MarkBlobReusableOnDrop(Vec<u8>);

impl Drop for MarkBlobReusableOnDrop {
    fn drop(&mut self) {
        crate::backend::mark_pages_reusable(self.0.as_ptr(), self.0.capacity());
    }
}

/// Decode the stored image downscaled to at most `max_dim` on its longest
/// side (aspect preserved; never upscales) into a Rust-owned RGBA8 buffer.
///
/// This is the preview decode path. The buffer is handed to the caller with
/// EXACTLY `w * h * 4` bytes and must be returned via
/// [`clipboard_preview_buffer_release`] — never `clipboard_free_bytes` (the
/// two allocations have different layouts). Release marks the pages
/// `MADV_FREE_REUSABLE` before freeing, so a closed preview's decode stops
/// counting against the process footprint: macOS does not return freed large
/// malloc pages by any other means (measured), which is why ImageIO-decoded
/// previews previously accumulated tens of MB of permanent residue per
/// session.
///
/// Decodes through the same codec paths as the capture pipeline (RGBA8 PNG
/// fast path, generic decoder otherwise). The full-resolution intermediate is
/// marked reusable before being dropped, so only the (downscaled) delivered
/// buffer counts while the preview is on screen. `out_is_gif` is set to 1 when
/// the stored blob is an animated GIF (Swift keeps the NSImage(data:) path for
/// those to preserve animation). Returns null on failure (missing row,
/// undecodable, zero-size). `max_dim <= 0` decodes at full resolution.
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
    eprintln!("CopyAttach: preview_decode db_id={db_id} max_dim={max_dim}");
    unsafe {
        *out_len = 0;
        *out_w = 0;
        *out_h = 0;
        *out_is_gif = 0;
    }

    let png: Vec<u8> = match backend().db.lock() {
        Ok(conn) => match conn.query_row(
            "SELECT png_data FROM clipboard_history WHERE id = ? AND entry_type = 1",
            rusqlite::params![db_id],
            |row| row.get::<_, Vec<u8>>(0),
        ) {
            Ok(data) => data,
            Err(e) => {
                eprintln!("CopyAttach: failed to load png for preview db_id={db_id}: {e}");
                return std::ptr::null_mut();
            }
        },
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading png for preview db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };
    // The blob's pages are returned to the system on every exit path below.
    // Claim first: the allocator may have handed back a block whose pages are
    // still marked reusable from a previous scratch — those pages stay
    // kernel-reclaimable (and uncounted) until claimed, and this buffer is
    // read by the decoder.
    crate::backend::claim_pages(png.as_ptr(), png.capacity());
    let png_guard = MarkBlobReusableOnDrop(png);
    let png = &png_guard.0;
    if png.is_empty() {
        eprintln!("CopyAttach: preview db_id={db_id}: stored png_data is empty");
        return std::ptr::null_mut();
    }
    // Animated GIFs are returned to Swift as-is (NSImage(data:) preserves the
    // animation); Swift must know before consuming the decoded buffer.
    if png.starts_with(&[0x47, 0x49, 0x46, 0x38]) {
        unsafe { *out_is_gif = 1 };
    }

    let max_dim = max_dim.max(0) as u32;
    let layout_for = |byte_len: usize| {
        std::alloc::Layout::from_size_align(byte_len, 16)
            .expect("preview buffer layout must be valid")
    };

    // Decode into the pooled buffer (fast path) or a fresh Vec (generic
    // path); either way the intermediate's pages end up marked reusable, so
    // the full-resolution decode never leaves permanent residue. The
    // delivered buffer is a separate, exactly-sized allocation owned by the
    // caller (released via `clipboard_preview_buffer_release`).
    let mut pooled = crate::backend::ImageDecodeBuffer::acquire();
    let delivered: Option<(*mut u8, u32, u32, usize)> =
        if let Some((w, h)) = crate::image::decode_png_rgba8_into(png, pooled.as_mut_vec()) {
            let (dw, dh) = crate::image::resize_dims(w, h, max_dim);
            let byte_len = (dw as usize) * (dh as usize) * 4;
            let dst = unsafe { std::alloc::alloc(layout_for(byte_len)) };
            if dst.is_null() {
                eprintln!("CopyAttach: preview alloc failed for {byte_len} bytes");
                None
            } else {
                // The delivered buffer is handed to Swift as long-lived, read-
                // only data: claim any reusable-marked pages the allocator may
                // have handed back so the kernel cannot reclaim them while the
                // preview is on screen.
                crate::backend::claim_pages(dst, byte_len);
                if (dw, dh) == (w, h) {
                    unsafe { std::ptr::copy_nonoverlapping(pooled.as_ptr(), dst, byte_len) };
                } else if let Some(resized) =
                    crate::image::resize_rgba(&pooled, w, h, dw, dh)
                {
                    unsafe { std::ptr::copy_nonoverlapping(resized.as_ptr(), dst, byte_len) };
                    crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
                } else {
                    eprintln!("CopyAttach: preview resize failed for db_id={db_id}");
                    unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                    return std::ptr::null_mut();
                }
                // `pooled` returns to the pool here (pages marked reusable) —
                // deliberately NOT taken out: the pool keeps its capacity.
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
                        eprintln!("CopyAttach: preview alloc failed for {byte_len} bytes");
                        return std::ptr::null_mut();
                    }
                    // See the fast-path comment: claim before Swift owns it.
                    crate::backend::claim_pages(dst, byte_len);
                    if (dw, dh) == (w, h) {
                        unsafe { std::ptr::copy_nonoverlapping(rgba.as_ptr(), dst, byte_len) };
                    } else if let Some(resized) = crate::image::resize_rgba(&rgba, w, h, dw, dh) {
                        unsafe { std::ptr::copy_nonoverlapping(resized.as_ptr(), dst, byte_len) };
                        crate::backend::mark_pages_reusable(resized.as_ptr(), resized.capacity());
                    } else {
                        eprintln!("CopyAttach: preview resize failed for db_id={db_id}");
                        unsafe { std::alloc::dealloc(dst, layout_for(byte_len)) };
                        return std::ptr::null_mut();
                    }
                    crate::backend::mark_pages_reusable(rgba.as_ptr(), rgba.capacity());
                    Some((dst, dw, dh, byte_len))
                }
                Err(e) => {
                    eprintln!("CopyAttach: preview db_id={db_id} undecodable: {e}");
                    return std::ptr::null_mut();
                }
            }
        };

    match delivered {
        Some((ptr, w, h, byte_len)) => {
            eprintln!("CopyAttach: preview_decode done db_id={db_id} w={w} h={h} bytes={byte_len} gif={}",
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

/// Return a buffer from [`clipboard_decode_preview_by_db_id`] to the system:
/// mark its pages reusable (so they stop counting against the footprint) and
/// free the allocation. Thread-safe; may be called from any thread (e.g. a
/// CGImage data-provider release callback).
#[no_mangle]
pub extern "C" fn clipboard_preview_buffer_release(ptr: *mut u8, len: c_int) {
    if ptr.is_null() || len <= 0 {
        return;
    }
    eprintln!("CopyAttach: preview_buffer_release len={len} ptr=0x{:x}", ptr as usize);
    let byte_len = len as usize;
    crate::backend::mark_pages_reusable(ptr, byte_len);
    let layout = std::alloc::Layout::from_size_align(byte_len, 16)
        .expect("preview buffer layout must match the allocation");
    unsafe { std::alloc::dealloc(ptr, layout) }
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
