//! Stub platform implementation for unsupported targets (Linux CI, etc.).
//!
//! Every clipboard operation fails explicitly with a log — per the project's
//! no-silent-fallback policy. This module exists so the crate compiles and
//! runs its platform-independent test suite on other hosts; it is never
//! shipped as a product.

use crate::backend::ImageDecodeBuffer;

pub(crate) fn change_count() -> Option<i64> {
    None
}

pub(crate) fn has_files() -> bool {
    false
}

pub(crate) fn file_paths() -> Vec<String> {
    vec![]
}

pub(crate) fn read_text() -> Option<String> {
    crate::error_log!("CopyAttach: clipboard text read is not supported on this platform");
    None
}

pub(crate) fn capture_image() -> Option<(ImageDecodeBuffer, u32, u32)> {
    crate::error_log!("CopyAttach: clipboard image capture is not supported on this platform");
    None
}

pub(crate) fn set_clipboard_text(_text: &str) -> bool {
    crate::error_log!("CopyAttach: clipboard text write is not supported on this platform");
    false
}

pub(crate) fn set_clipboard_image(_png_data: &[u8]) -> bool {
    crate::error_log!("CopyAttach: clipboard image write is not supported on this platform");
    false
}

pub(crate) fn simulate_paste(_pid: i32) -> bool {
    crate::error_log!("CopyAttach: paste simulation is not supported on this platform");
    false
}

pub(crate) fn check_permission() -> bool {
    true
}

pub(crate) fn open_preferences() {}
