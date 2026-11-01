#![allow(dead_code)]

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if crate::backend::debug_log_enabled() {
            crate::backend::debug_log_fmt(format_args!($($arg)*));
        }
    };
}

macro_rules! error_log {
    ($($arg:tt)*) => {
        crate::backend::error_log_fmt(format_args!($($arg)*))
    };
}

pub(crate) use debug_log;
pub(crate) use error_log;

mod types;
mod backend;
mod image;
mod history;
mod db;
mod ignore;
mod perf;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(not(target_os = "macos"))]
mod macos {
    pub(crate) fn check_permission() -> bool { true }
    pub(crate) fn open_preferences() {}
    pub(crate) fn simulate_cmd_v() -> bool {
        crate::debug_log!("Warning: paste simulation only supported on macOS");
        false
    }
    pub(crate) fn pasteboard_change_count() -> Option<i64> { None }
    pub(crate) fn pasteboard_has_files() -> bool { false }
    pub(crate) fn pasteboard_file_paths() -> Vec<String> { vec![] }
    pub(crate) fn pasteboard_url_string() -> Option<String> { None }
    pub(crate) fn pasteboard_has_sensitive_content() -> bool { false }
}

mod monitor;
mod ffi;

#[cfg(feature = "stress-test")]
pub mod stress;

#[cfg(feature = "demo-data")]
pub mod demo;

#[cfg(test)]
mod tests;

#[cfg(all(test, feature = "stress-test"))]
mod bench_tests;
