//! macOS-specific utilities: pasteboard access, paste simulation, accessibility permissions.
//!
//! This file is only compiled on macOS (the `mod macos;` declaration in lib.rs
//! is gated with `#[cfg(target_os = "macos")]`). A no-op stub in lib.rs covers
//! non-macOS builds so the crate compiles everywhere.

use std::ffi::c_int;
use std::process::Command;
use objc2::msg_send;
use objc2_core_graphics::{
    CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID,
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

/// Check whether the general pasteboard contains file URLs.
///
/// When a file is copied in Finder, macOS populates the pasteboard with
/// `public.file-url` types and provides the file icon as an image preview.
/// This function checks for the presence of `public.file-url` so callers
/// can skip capturing the icon as a clipboard image entry.
///
/// Returns `false` if the pasteboard is inaccessible or no file items exist.
pub(crate) fn pasteboard_has_files() -> bool {
    unsafe { !pasteboard_file_url_strings().is_empty() }
}

/// Extract file paths from the general pasteboard.
///
/// When files are copied in Finder, each pasteboard item with `public.file-url`
/// type corresponds to a file URL. This function converts those URLs to
/// absolute file paths using NSURL's `path` method for proper percent-decoding.
///
/// Returns an empty `Vec` if the pasteboard is inaccessible or has no file URLs.
/// Malformed or unconvertible URLs are silently skipped (not returned as
/// degraded data) — the caller receives only usable absolute paths.
pub(crate) fn pasteboard_file_paths() -> Vec<String> {
    unsafe {
        let url_strings = pasteboard_file_url_strings();
        if url_strings.is_empty() {
            return vec![];
        }

        // NSURL + NSString always exist in the ObjC runtime on macOS.
        // Return empty if somehow absent — don't fall back to raw file:// strings.
        let nsurl_cls = if let Some(c) = objc2::runtime::AnyClass::get(c"NSURL") { c } else {
            eprintln!("CopyAttach: NSURL class not found in ObjC runtime, cannot convert file URLs");
            return vec![];
        };
        let nsstr_cls = if let Some(c) = objc2::runtime::AnyClass::get(c"NSString") { c } else {
            eprintln!("CopyAttach: NSString class not found in ObjC runtime, cannot convert file URLs");
            return vec![];
        };

        let mut paths = Vec::with_capacity(url_strings.len());
        for url_str in &url_strings {
            let c_bytes = match std::ffi::CString::new(url_str.as_str()) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let ns_url_str: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: c_bytes.as_ptr()];
            if ns_url_str.is_null() {
                continue;
            }

            let url_obj: *mut objc2::runtime::NSObject =
                msg_send![nsurl_cls, URLWithString: ns_url_str];
            if url_obj.is_null() {
                continue;
            }

            let path_obj: *mut objc2::runtime::NSObject = msg_send![url_obj, path];
            if path_obj.is_null() {
                continue;
            }

            let c_path: *const i8 = msg_send![path_obj, UTF8String];
            if c_path.is_null() {
                continue;
            }

            let path = std::ffi::CStr::from_ptr(c_path)
                .to_string_lossy()
                .into_owned();
            paths.push(path);
        }
        paths
    }
}

/// Internal helper: extract raw `file://` URL strings from pasteboard items.
unsafe fn pasteboard_file_url_strings() -> Vec<String> {
    let cls = match objc2::runtime::AnyClass::get(c"NSPasteboard") {
        Some(c) => c,
        None => return vec![],
    };
    let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
    if pasteboard.is_null() {
        return vec![];
    }

    let items: *mut objc2::runtime::NSObject = msg_send![pasteboard, pasteboardItems];
    if items.is_null() {
        return vec![];
    }

    let count: usize = msg_send![items, count];
    if count == 0 {
        return vec![];
    }

    let nsstr_cls = match objc2::runtime::AnyClass::get(c"NSString") {
        Some(c) => c,
        None => return vec![],
    };
    let c_bytes = b"public.file-url\0";
    let file_url_type: *mut objc2::runtime::NSObject =
        msg_send![nsstr_cls, stringWithUTF8String: c_bytes.as_ptr().cast::<i8>()];
    if file_url_type.is_null() {
        return vec![];
    }

    let mut results = vec![];
    for i in 0..count {
        let item: *mut objc2::runtime::NSObject = msg_send![items, objectAtIndex: i];
        if item.is_null() {
            continue;
        }

        let url_str: *mut objc2::runtime::NSObject =
            msg_send![item, stringForType: file_url_type];
        if url_str.is_null() {
            continue;
        }

        let c_str: *const i8 = msg_send![url_str, UTF8String];
        if c_str.is_null() {
            continue;
        }

        if let Ok(s) = std::ffi::CStr::from_ptr(c_str).to_str() {
            results.push(s.to_owned());
        }
    }
    results
}

/// Put a single file URL on the general pasteboard — the Finder "copy file"
/// convention. Terminal emulators translate `public.file-url` into the
/// absolute path when the user pastes, so TUI agents (Claude Code et al.)
/// receive the path text; the paste target consumes the file immediately
/// after the simulated Cmd+V.
///
/// Returns `false` (with nothing written) if the pasteboard is inaccessible
/// or the URL cannot be built.
pub(crate) fn set_pasteboard_file_url(path: &str) -> bool {
    unsafe {
        let pasteboard_cls = match objc2::runtime::AnyClass::get(c"NSPasteboard") {
            Some(c) => c,
            None => return false,
        };
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![pasteboard_cls, generalPasteboard];
        if pasteboard.is_null() {
            return false;
        }

        let nsstr_cls = match objc2::runtime::AnyClass::get(c"NSString") {
            Some(c) => c,
            None => return false,
        };
        let c_path = match std::ffi::CString::new(path) {
            Ok(s) => s,
            Err(_) => return false,
        };
        let path_obj: *mut objc2::runtime::NSObject =
            msg_send![nsstr_cls, stringWithUTF8String: c_path.as_ptr()];
        if path_obj.is_null() {
            return false;
        }

        let nsurl_cls = match objc2::runtime::AnyClass::get(c"NSURL") {
            Some(c) => c,
            None => return false,
        };
        let url_obj: *mut objc2::runtime::NSObject = msg_send![nsurl_cls, fileURLWithPath: path_obj];
        if url_obj.is_null() {
            return false;
        }

        let url_str: *mut objc2::runtime::NSObject = msg_send![url_obj, absoluteString];
        if url_str.is_null() {
            return false;
        }

        // NSPasteboardTypeFileURL == "public.file-url"
        let type_bytes = b"public.file-url\0";
        let file_url_type: *mut objc2::runtime::NSObject =
            msg_send![nsstr_cls, stringWithUTF8String: type_bytes.as_ptr().cast::<i8>()];
        if file_url_type.is_null() {
            return false;
        }

        let _: isize = msg_send![pasteboard, clearContents];
        let ok: bool = msg_send![pasteboard, setString: url_str, forType: file_url_type];
        ok
    }
}

/// Simulate Cmd+V key press via `CGEventPostToPid`.
/// `pid` must be the frontmost application's process identifier (> 0).
/// Returns `false` if pid is 0 or event creation fails.
pub(crate) fn simulate_cmd_v(pid: i32) -> bool {
    simulate_paste_v(pid, false)
}

/// Simulate paste key press (V key) via `CGEventPostToPid`.
/// When `use_ctrl` is true, sends Ctrl+V; otherwise sends Cmd+V.
/// `pid` must be the frontmost application's process identifier (> 0).
/// Returns `false` if pid is 0 or event creation fails.
pub(crate) fn simulate_paste_v(pid: i32, use_ctrl: bool) -> bool {
    if pid <= 0 {
        eprintln!("CopyAttach: simulate_paste_v: no target PID (frontmost app unknown)");
        return false;
    }
    let source = CGEventSource::new(CGEventSourceStateID::Private);
    let source = source.as_deref();
    let key_down = CGEvent::new_keyboard_event(source, 9, true);
    let key_up = CGEvent::new_keyboard_event(source, 9, false);
    if let (Some(kd), Some(ku)) = (key_down, key_up) {
        let flags = if use_ctrl {
            CGEventFlags::MaskControl
        } else {
            CGEventFlags::MaskCommand
        };
        CGEvent::set_flags(Some(&*kd), flags);
        CGEvent::set_flags(Some(&*ku), flags);

        CGEvent::post_to_pid(pid, Some(&*kd));
        CGEvent::post_to_pid(pid, Some(&*ku));
        true
    } else {
        eprintln!("CopyAttach: failed to create CGEvent for paste simulation");
        false
    }
}

#[cfg(test)]
mod paste_tests {
    use super::*;
    use arboard::Clipboard;

    /// Roundtrip check for the drag-style file-URL pasteboard write:
    /// set a file URL, read it back as a path, then restore the previous
    /// text/image clipboard content (this test briefly touches the user's
    /// real pasteboard).
    #[test]
    fn test_set_pasteboard_file_url_roundtrip() {
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        let path = "/tmp/copyattach-paste-check.png";
        // Run the actual write/read, restore the user's clipboard first, then
        // assert — a failed assertion must never leave the pasteboard clobbered.
        let ok_set = set_pasteboard_file_url(path);
        let paths = pasteboard_file_paths();

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }

        assert!(ok_set, "set_pasteboard_file_url must succeed");
        assert_eq!(
            paths,
            vec![path.to_string()],
            "pasteboard must expose exactly the written path"
        );
    }
}
