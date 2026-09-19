use std::ffi::{c_char, c_int, CStr};

use crate::backend::try_backend;

/// Search all history entries for a case-insensitive substring over the stored
/// full text (FTS5 trigram index for ≥3-char queries, LIKE fallback for
/// shorter ones — see `db::search_history`; the fallback is deliberate so
/// 1-2 char queries keep matching the middle of long documents, not just the
/// rendered previews). Returns a malloc'd array of matching entry_ids
/// (`out_count` = number of ids), or null when there are no matches. Caller
/// must free with `clipboard_free_u64_array()`. Metadata matching (label,
/// custom_label, source_name) runs in this same call, inside `db::search_history`.
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
    let perf = crate::perf::PerfSpan::start("rust", "search.query");
    let ids = crate::db::search_history(&conn, &q);
    let len = ids.len();
    if let Some(mut span) = perf {
        span.val = Some(len as i64);
        span.data = Some(if q.chars().count() >= 3 { "fts".to_string() } else { "like".to_string() });
    }
    if len == 0 {
        return std::ptr::null_mut();
    }
    let boxed = ids.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u64;
    // Same hand-off contract as `vec_to_raw`: claim any reusable-marked pages
    // the allocator may have handed back before Swift reads the ids.
    if !crate::backend::claim_pages(
        ptr as *const u8,
        len * std::mem::size_of::<u64>(),
    ) {
        crate::backend::mark_pages_reusable(ptr as *const u8, len * std::mem::size_of::<u64>());
        crate::error_log!("CopyAttach: search result ids could not be claimed — returning null");
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
        return std::ptr::null_mut();
    }
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
    let slice_ptr = std::ptr::slice_from_raw_parts_mut(ptr, len as usize);
    unsafe { drop(Box::from_raw(slice_ptr)); }
}
