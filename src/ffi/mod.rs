//! C FFI exports — the interface between the Rust backend and the Swift frontend.
//!
//! Most `#[no_mangle] pub extern "C"` functions live here — the FFI surface is
//! split, with `clipboard_wait_for_history_change` and
//! `clipboard_history_counters` in `backend.rs` and the perf controls
//! (`clipboard_set_perf_enabled`, `clipboard_perf_enabled`,
//! `clipboard_perf_emit_probe`, `clipboard_perf_selfcheck`) in `perf.rs`.
//! They are thin wrappers that lock the backend, perform the requested
//! operation, and return results to the caller. Memory ownership follows the
//! `*_free_string` / `*_free_bytes` contract documented on each group of
//! functions.
//!
//! The exports are grouped into submodules by responsibility (snapshot, search,
//! init, accessors, paste, history, stress); the `pub(crate) use` re-exports
//! keep the historical `crate::ffi::*` paths stable for internal callers and
//! the test suite.

use std::ffi::{c_char, CString};

mod snapshot;
mod search;
mod init;
mod accessors;
#[cfg_attr(not(test), allow(unused))]
pub(crate) mod paste;
mod history;
mod stress;
mod backup;

// Re-export so `crate::ffi::*` paths stay stable for the test suite and any
// internal callers. Most exports are consumed by Swift purely as C symbols, so
// Rust-side references are sparse — the globs read as "unused" in non-test
// builds, which is expected at the FFI boundary.
#[allow(unused_imports)]
pub(crate) use snapshot::*;
#[allow(unused_imports)]
pub(crate) use search::*;
#[allow(unused_imports)]
pub(crate) use init::*;
#[allow(unused_imports)]
pub(crate) use accessors::*;
#[allow(unused_imports)]
pub(crate) use paste::*;
#[allow(unused_imports)]
pub(crate) use history::*;
#[allow(unused_imports)]
pub(crate) use stress::*;
#[allow(unused_imports)]
pub(crate) use backup::*;

pub(super) fn vec_to_raw(v: Vec<u8>) -> *mut u8 {
    let len = v.len();
    // Convert to boxed slice so allocation layout is strictly bound to `len`,
    // avoiding allocator-dependent size class mismatches when reconstructed.
    let boxed = v.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u8;
    // The allocator may have handed back a block whose pages are still marked
    // `MADV_FREE_REUSABLE` from a previous scratch buffer (freed-but-marked
    // blocks are reused as-is). Such pages stay kernel-reclaimable — and
    // uncounted — until claimed, so a live buffer read by Swift could be
    // zeroed under memory pressure. Claim before the caller touches it.
    //
    // A rejected claim means this hand-off cannot be honoured: the caller
    // would read memory the kernel may reclaim at any moment. Returning null
    // is the honest answer — every Swift call site already treats null as
    // "this load failed" — and it keeps a corrupted payload out of the UI.
    if !crate::backend::claim_pages(ptr, len) {
        crate::error_log!("CopyAttach: FFI hand-off buffer len={len} could not be claimed — returning null instead of reclaimable bytes");
        crate::backend::mark_pages_reusable(ptr, len);
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
        return std::ptr::null_mut();
    }
    ptr
}

/// Convert a Rust string to a `CString` for FFI return. If the string contains
/// an interior null byte, truncate at the first null and log a warning instead
/// of silently returning an empty string.
fn to_ffi_cstring(s: &str) -> *mut c_char {
    let raw = if let Ok(cs) = CString::new(s) { cs.into_raw() } else {
        let null_pos = s.find('\0').unwrap_or(s.len());
        crate::debug_log!("CopyAttach: FFI string contains interior null byte at offset {} (len={}), truncating",
                  null_pos, s.len());
        let truncated: String = s.chars().take_while(|&c| c != '\0').collect();
        CString::new(truncated).unwrap_or_default().into_raw()
    };
    if !raw.is_null() {
        let len = unsafe { std::ffi::CStr::from_ptr(raw) }.to_bytes_with_nul().len();
        // Same hand-off rule as `vec_to_raw`: an unclaimable CString may read
        // back zeroed, so decline instead of handing the caller bad bytes.
        if !crate::backend::claim_pages(raw as *const u8, len) {
            crate::error_log!("CopyAttach: FFI string len={len} could not be claimed — returning null");
            crate::backend::mark_pages_reusable(raw as *const u8, len);
            unsafe { drop(CString::from_raw(raw)) };
            return std::ptr::null_mut();
        }
    }
    raw
}

pub(super) fn parse_ids_str(s: *const c_char) -> Vec<u64> {
    if s.is_null() {
        return Vec::new();
    }
    let c_str = match unsafe { std::ffi::CStr::from_ptr(s) }.to_str() {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    c_str
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse::<u64>().ok())
        .collect()
}

pub(super) fn parse_ids_set(s: *const c_char) -> std::collections::HashSet<u64> {
    parse_ids_str(s).into_iter().collect()
}
