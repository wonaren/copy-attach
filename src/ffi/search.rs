use std::ffi::{c_char, c_int, CStr};

use crate::backend::try_backend;

/// Search all history entries for a case-insensitive substring over the stored
/// full text (FTS5 trigram index for ≥3-char queries, LIKE fallback for
/// shorter ones — see `db::search_history`; the fallback is deliberate so
/// 1-2 char queries keep matching the middle of long documents, not just the
/// rendered previews). Returns a malloc'd array of matching entry_ids
/// (`out_count` = number of ids), or null when there are no matches. Caller
/// must free with `clipboard_free_u64_array()`. Label/source-name matching is
/// done on the Swift side, which already holds those fields.
#[no_mangle]
pub extern "C" fn clipboard_search_ids(query: *const c_char, out_count: *mut c_int) -> *mut u64 {
    if !out_count.is_null() {
        unsafe { *out_count = 0; }
    }
    if query.is_null() {
        return std::ptr::null_mut();
    }
    let q = unsafe { CStr::from_ptr(query) }.to_string_lossy();
    if q.is_empty() {
        return std::ptr::null_mut();
    }
    // Search reads the DB (full text lives there, not in the history Vec).
    let conn = match try_backend().map(|b| b.db.lock()) {
        Some(Ok(c)) => c,
        _ => return std::ptr::null_mut(),
    };
    let mut ids = crate::db::search_history(&conn, &q);
    let len = ids.len();
    if len == 0 {
        return std::ptr::null_mut();
    }
    // Pin capacity == len so `clipboard_free_u64_array` can reconstruct the
    // Vec with from_raw_parts(ptr, len, len) without layout mismatch.
    ids.shrink_to_fit();
    let ptr = ids.as_mut_ptr();
    std::mem::forget(ids);
    unsafe { *out_count = len as c_int; }
    ptr
}

#[no_mangle]
pub extern "C" fn clipboard_free_u64_array(ptr: *mut u64, len: c_int) {
    if ptr.is_null() || len <= 0 { return; }
    // Same footprint contract as `clipboard_free_bytes`: mark the block
    // reusable before returning it to the allocator so large match sets do not
    // leave freed-but-retained memory in the process footprint.
    crate::backend::mark_pages_reusable(ptr as *const u8, (len as usize) * std::mem::size_of::<u64>());
    unsafe { let _ = Vec::from_raw_parts(ptr, len as usize, len as usize); }
}
