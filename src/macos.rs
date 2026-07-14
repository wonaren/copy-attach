//! macOS-specific utilities: pasteboard access, paste simulation, accessibility permissions.
//!
//! This file is only compiled on macOS (the `mod macos;` declaration in lib.rs
//! is gated with `#[cfg(target_os = "macos")]`). A no-op stub in lib.rs covers
//! non-macOS builds so the crate compiles everywhere.

use std::ffi::c_int;
use std::process::Command;
use objc2::msg_send;
use objc2_core_graphics::{
    CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID, CGEventTapLocation,
};

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> c_int;
}

/// Check whether the app has accessibility permissions (required for Cmd+V simulation).
pub(crate) fn check_permission() -> bool {
    let result = unsafe { AXIsProcessTrusted() };
    result != 0
}

/// Open the Accessibility privacy pane in System Settings.
pub(crate) fn open_preferences() {
    let _ = Command::new("open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .spawn();
}

/// Lightweight check: returns the pasteboard change count without reading
/// or converting any image data. Returns `None` if pasteboard is inaccessible.
pub(crate) fn pasteboard_change_count() -> Option<i64> {
    unsafe {
        let cls = objc2::runtime::AnyClass::get(c"NSPasteboard")?;
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return None;
        }
        let count: isize = msg_send![pasteboard, changeCount];
        Some(count as i64)
    }
}

/// Simulate Cmd+V key press via CGEventPost.
/// Returns `true` if the events were posted successfully.
pub(crate) fn simulate_cmd_v() -> bool {
    let source = CGEventSource::new(CGEventSourceStateID::Private);
    let source = source.as_ref().map(|s| &**s);
    let key_down = CGEvent::new_keyboard_event(source, 9, true);
    let key_up = CGEvent::new_keyboard_event(source, 9, false);
    match (key_down, key_up) {
        (Some(kd), Some(ku)) => {
            CGEvent::set_flags(Some(&*kd), CGEventFlags::MaskCommand);
            CGEvent::post(CGEventTapLocation::SessionEventTap, Some(&*kd));
            CGEvent::set_flags(Some(&*ku), CGEventFlags::MaskCommand);
            CGEvent::post(CGEventTapLocation::SessionEventTap, Some(&*ku));
            true
        }
        _ => {
            eprintln!("CopyAttach: failed to create CGEvent for paste simulation");
            false
        }
    }
}
