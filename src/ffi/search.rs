use std::ffi::{c_char, c_int, CStr};

use crate::backend::try_backend;

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
    crate::backend::mark_pages_reusable(ptr as *const u8, (len as usize) * std::mem::size_of::<u64>());
    let slice_ptr = std::ptr::slice_from_raw_parts_mut(ptr, len as usize);
    unsafe { drop(Box::from_raw(slice_ptr)); }
}
