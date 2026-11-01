use std::ffi::{c_char, c_int};

use super::to_ffi_cstring;

#[no_mangle]
pub extern "C" fn clipboard_stress_available() -> c_int {
    #[cfg(feature = "stress-test")] { 1 }
    #[cfg(not(feature = "stress-test"))] { 0 }
}

#[cfg(feature = "stress-test")]
#[no_mangle]
pub extern "C" fn clipboard_stress_inject(count: c_int, text_ratio: f64, seed: i64) -> c_int {
    crate::stress::ffi_inject(count, text_ratio, seed)
}

#[cfg(not(feature = "stress-test"))]
#[no_mangle]
pub extern "C" fn clipboard_stress_inject(_count: c_int, _text_ratio: f64, _seed: i64) -> c_int { 0 }

#[cfg(feature = "stress-test")]
#[no_mangle]
pub extern "C" fn clipboard_stress_reset() {
    crate::stress::ffi_reset();
}

#[cfg(not(feature = "stress-test"))]
#[no_mangle]
pub extern "C" fn clipboard_stress_reset() {}

#[cfg(feature = "stress-test")]
#[no_mangle]
pub extern "C" fn clipboard_stress_run_bench() -> *mut c_char {
    let snap_us = crate::stress::bench_snapshot_clone(100);
    let cnt_ns = crate::stress::bench_count(1000);
    let json = format!(
        r#"{{"snapshot_clone_avg_us":{:.1},"count_lock_avg_ns":{:.1}}}"#,
        snap_us, cnt_ns
    );
    to_ffi_cstring(&json)
}

#[cfg(not(feature = "stress-test"))]
#[no_mangle]
pub extern "C" fn clipboard_stress_run_bench() -> *mut c_char {
    to_ffi_cstring(r#"{"error":"stress-test feature not enabled"}"#)
}
