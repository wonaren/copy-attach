//! C FFI exports — the interface between the Rust backend and the Swift frontend.
//!
//! All `#[no_mangle] pub extern "C"` functions live here. They are thin wrappers
//! that lock the backend, perform the requested operation, and return results
//! to the caller. Memory ownership follows the `*_free_string` / `*_free_bytes`
//! contract documented on each group of functions.
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
mod paste;
mod history;
mod stress;

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

fn vec_to_raw(v: Vec<u8>) -> *mut u8 {
    let mut v = v;
    // Pin capacity == len so `clipboard_free_bytes` can reconstruct the Vec
    // with from_raw_parts(ptr, len, len) without layout mismatch — same
    // contract `clipboard_search_ids` upholds explicitly before handing the
    // buffer to the C caller.
    v.shrink_to_fit();
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    ptr
}

/// Convert a Rust string to a `CString` for FFI return. If the string contains
/// an interior null byte, truncate at the first null and log a warning instead
/// of silently returning an empty string.
fn to_ffi_cstring(s: &str) -> *mut c_char {
    if let Ok(cs) = CString::new(s) { cs.into_raw() } else {
        let null_pos = s.find('\0').unwrap_or(s.len());
        eprintln!("CopyAttach: FFI string contains interior null byte at offset {} (len={}), truncating",
                  null_pos, s.len());
        let truncated: String = s.chars().take_while(|&c| c != '\0').collect();
        CString::new(truncated).unwrap_or_default().into_raw()
    }
}
