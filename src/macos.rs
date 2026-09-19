//! macOS-specific pasteboard, paste simulation, and accessibility utilities.

use std::ffi::c_int;
use std::process::Command;
use std::sync::OnceLock;
use objc2::msg_send;
use objc2_core_graphics::{
    CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID,
};

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
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

/// Read the first supported image representation in fixed preference order.
pub(crate) fn pasteboard_image_data() -> Option<Vec<u8>> {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        // If the pasteboard represents a file copy or carries a file/app icon
        // preview (e.g. `com.apple.icns` auto-bridged by macOS to `public.tiff`),
        // reject it: this is an icon representation, not a user image copy.
        if pasteboard_has_files() {
            return None;
        }

        let cls = nspasteboard_class()?;
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return None;
        }
        let nsstr_cls = objc2::runtime::AnyClass::get(c"NSString")?;
        // Fixed priority order, not a size comparison: the first type present
        // on the pasteboard wins (so PNG wins over a smaller JPEG).
        for uti in [c"public.png", c"public.tiff", c"public.jpeg",
                    c"com.compuserve.gif", c"org.webmproject.webp", c"com.microsoft.bmp"] {
            let ns_uti: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: uti.as_ptr()];
            if ns_uti.is_null() {
                continue;
            }
            let data: *mut objc2::runtime::NSObject = msg_send![pasteboard, dataForType: ns_uti];
            if data.is_null() {
                continue;
            }
            let len: usize = msg_send![data, length];
            if len == 0 {
                continue;
            }
            let ptr: *const core::ffi::c_void = msg_send![data, bytes];
            if ptr.is_null() {
                continue;
            }
            let bytes = std::slice::from_raw_parts(ptr as *const u8, len);
            let owned = bytes.to_vec();
            // Claim reusable-marked pages before the capture pipeline decodes them.
            // An unclaimable buffer must not be decoded: the kernel could zero
            // it mid-decode. Returning None means "no image representation" —
            // the monitor then falls through to its other capture paths.
            if !crate::backend::claim_pages(owned.as_ptr(), owned.capacity()) {
                crate::error_log!("CopyAttach: pasteboard image bytes ({len} bytes) could not be claimed — skipped");
                return None;
            }
            return Some(owned);
        }
        None
    })
}

/// Cached `NSPasteboard` class to keep the hot poll path allocation-free.
static NSPASTEBOARD_CLASS: OnceLock<Option<&'static objc2::runtime::AnyClass>> = OnceLock::new();

fn nspasteboard_class() -> Option<&'static objc2::runtime::AnyClass> {
    *NSPASTEBOARD_CLASS.get_or_init(|| objc2::runtime::AnyClass::get(c"NSPasteboard"))
}

/// Lightweight pasteboard change count; wrapped in an autorelease pool.
pub(crate) fn pasteboard_change_count() -> Option<i64> {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let cls = nspasteboard_class()?;
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return None;
        }
        let count: isize = msg_send![pasteboard, changeCount];
        Some(count as i64)
    })
}

/// Check whether the pasteboard carries a sensitive-content marker.
///
/// Four types are matched, and only these four: the three standard
/// nspasteboard.org opt-out markers, plus 1Password's own legacy type.
/// Bitwarden, KeePassXC and Apple Keychain are *not* matched by name — they
/// are covered only as far as they honour the standard `ConcealedType` /
/// `TransientType` markers, so an app that bypasses them is captured.
pub(crate) fn pasteboard_has_sensitive_content() -> bool {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let cls = match nspasteboard_class() {
            Some(c) => c,
            None => return false,
        };
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return false;
        }
        let types: *mut objc2::runtime::NSObject = msg_send![pasteboard, types];
        if types.is_null() {
            return false;
        }
        let count: usize = msg_send![types, count];
        if count == 0 {
            return false;
        }
        let nsstr_cls = match objc2::runtime::AnyClass::get(c"NSString") {
            Some(c) => c,
            None => return false,
        };
        for uti in [
            c"org.nspasteboard.ConcealedType",
            c"org.nspasteboard.AutoGeneratedType",
            c"org.nspasteboard.TransientType",
            c"com.agilebits.onepassword",
        ] {
            let ns_uti: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: uti.as_ptr()];
            if ns_uti.is_null() {
                continue;
            }
            let contains: bool = msg_send![types, containsObject: ns_uti];
            if contains {
                return true;
            }
        }
        false
    })
}

/// Whether the pasteboard represents a file copy or file/app icon preview.
///
/// In macOS, copying files (in Finder, WPS, Office, etc.) populates the pasteboard
/// with file URLs or filename types, and attaches `com.apple.icns` (auto-bridged
/// to `public.tiff` for legacy compatibility). Checking `types` directly is O(1)
/// and catches both modern and legacy file representations.
pub(crate) fn pasteboard_has_files() -> bool {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let cls = match nspasteboard_class() {
            Some(c) => c,
            None => return false,
        };
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return false;
        }
        let types: *mut objc2::runtime::NSObject = msg_send![pasteboard, types];
        if types.is_null() {
            return false;
        }
        let count: usize = msg_send![types, count];
        if count == 0 {
            return false;
        }
        let nsstr_cls = match objc2::runtime::AnyClass::get(c"NSString") {
            Some(c) => c,
            None => return false,
        };
        for uti in [
            c"public.file-url",
            c"NSFilenamesPboardType",
            c"com.apple.finder.noderef",
            c"com.apple.pasteboard.promised-file-url",
            c"Apple URL pasteboard type",
            c"com.apple.icns",
        ] {
            let ns_uti: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: uti.as_ptr()];
            if ns_uti.is_null() {
                continue;
            }
            let contains: bool = msg_send![types, containsObject: ns_uti];
            if contains {
                return true;
            }
        }
        !pasteboard_file_url_strings().is_empty()
    })
}

/// Extract absolute file paths from pasteboard file URLs; skips unusable ones.
pub(crate) fn pasteboard_file_paths() -> Vec<String> {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let url_strings = pasteboard_file_url_strings();
        if url_strings.is_empty() {
            return vec![];
        }

        // NSURL/NSString should always exist; don't fall back to raw file:// strings.
        let nsurl_cls = if let Some(c) = objc2::runtime::AnyClass::get(c"NSURL") { c } else {
            crate::error_log!("CopyAttach: NSURL class not found in ObjC runtime, cannot convert file URLs");
            return vec![];
        };
        let nsstr_cls = if let Some(c) = objc2::runtime::AnyClass::get(c"NSString") { c } else {
            crate::error_log!("CopyAttach: NSString class not found in ObjC runtime, cannot convert file URLs");
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
    })
}

/// Internal helper: extract raw `file://` URL strings from pasteboard items.
unsafe fn pasteboard_file_url_strings() -> Vec<String> {
    let cls = match nspasteboard_class() {
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

/// Put a single file URL on the pasteboard for the Finder "copy file" convention.
///
/// Clears the pasteboard first; on failure the caller must treat the paste as aborted.
pub(crate) fn set_pasteboard_file_url(path: &str) -> bool {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let pasteboard_cls = match nspasteboard_class() {
            Some(c) => c,
            None => {
                crate::error_log!("CopyAttach: NSPasteboard class not found in ObjC runtime");
                return false;
            }
        };
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![pasteboard_cls, generalPasteboard];
        if pasteboard.is_null() {
            crate::error_log!("CopyAttach: generalPasteboard unavailable");
            return false;
        }

        let nsstr_cls = match objc2::runtime::AnyClass::get(c"NSString") {
            Some(c) => c,
            None => {
                crate::error_log!("CopyAttach: NSString class not found in ObjC runtime");
                return false;
            }
        };
        let c_path = match std::ffi::CString::new(path) {
            Ok(s) => s,
            Err(_) => {
                crate::error_log!("CopyAttach: path contains NUL: {path:?}");
                return false;
            }
        };
        let path_obj: *mut objc2::runtime::NSObject =
            msg_send![nsstr_cls, stringWithUTF8String: c_path.as_ptr()];
        if path_obj.is_null() {
            crate::error_log!("CopyAttach: failed to build NSString for path {path}");
            return false;
        }

        let nsurl_cls = match objc2::runtime::AnyClass::get(c"NSURL") {
            Some(c) => c,
            None => {
                crate::error_log!("CopyAttach: NSURL class not found in ObjC runtime");
                return false;
            }
        };
        let url_obj: *mut objc2::runtime::NSObject = msg_send![nsurl_cls, fileURLWithPath: path_obj];
        if url_obj.is_null() {
            crate::error_log!("CopyAttach: failed to build NSURL for path {path}");
            return false;
        }

        let url_str: *mut objc2::runtime::NSObject = msg_send![url_obj, absoluteString];
        if url_str.is_null() {
            crate::error_log!("CopyAttach: failed to read absoluteString of file URL {path}");
            return false;
        }

        // NSPasteboardTypeFileURL == "public.file-url"
        let type_bytes = b"public.file-url\0";
        let file_url_type: *mut objc2::runtime::NSObject =
            msg_send![nsstr_cls, stringWithUTF8String: type_bytes.as_ptr().cast::<i8>()];
        if file_url_type.is_null() {
            crate::error_log!("CopyAttach: failed to build public.file-url type string");
            return false;
        }

        let _: isize = msg_send![pasteboard, clearContents];
        let ok: bool = msg_send![pasteboard, setString: url_str, forType: file_url_type];
        if !ok {
            crate::error_log!("CopyAttach: setString:forType: failed for file URL {path}");
        }
        ok
    })
}

/// Simulate Cmd+V key press via `CGEventPostToPid`.
/// `pid` must be the frontmost application's process identifier (> 0).
/// Returns `false` if pid is 0 or event creation fails.
pub(crate) fn simulate_cmd_v(pid: i32) -> bool {
    if pid <= 0 {
        crate::error_log!("CopyAttach: simulate_cmd_v: no target PID (frontmost app unknown)");
        return false;
    }
    // Verify target process is still alive before posting synthesized key event
    if unsafe { kill(pid, 0) != 0 } {
        let err = std::io::Error::last_os_error();
        // ESRCH (3): No such process
        if err.raw_os_error() == Some(3) {
            crate::error_log!("CopyAttach: simulate_cmd_v: target PID {pid} is no longer running");
            return false;
        }
    }
    let source = CGEventSource::new(CGEventSourceStateID::Private);
    let source = source.as_deref();
    let key_down = CGEvent::new_keyboard_event(source, 9, true);
    let key_up = CGEvent::new_keyboard_event(source, 9, false);
    if let (Some(kd), Some(ku)) = (key_down, key_up) {
        CGEvent::set_flags(Some(&*kd), CGEventFlags::MaskCommand);
        CGEvent::set_flags(Some(&*ku), CGEventFlags::MaskCommand);

        CGEvent::post_to_pid(pid, Some(&*kd));
        CGEvent::post_to_pid(pid, Some(&*ku));
        true
    } else {
        crate::error_log!("CopyAttach: failed to create CGEvent for paste simulation");
        false
    }
}

#[cfg(test)]
mod paste_tests {
    use super::*;
    use arboard::Clipboard;
    use std::sync::Mutex;

    static PASTEBOARD_TEST_LOCK: Mutex<()> = Mutex::new(());

    /// Roundtrip file-URL pasteboard write/read, restoring the user's clipboard.
    #[test]
    fn test_set_pasteboard_file_url_roundtrip() {
        let _guard = PASTEBOARD_TEST_LOCK.lock().unwrap();
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        let path = "/tmp/copyattach-paste-check.png";
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

    #[test]
    fn test_pasteboard_has_files_detects_file_url_and_rejects_image() {
        let _guard = PASTEBOARD_TEST_LOCK.lock().unwrap();
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        let path = "/tmp/copyattach-paste-check.png";
        let ok_set = set_pasteboard_file_url(path);
        assert!(ok_set, "set_pasteboard_file_url must succeed");

        assert!(pasteboard_has_files(), "pasteboard_has_files must detect file URL");
        assert!(pasteboard_image_data().is_none(), "pasteboard_image_data must reject file URL pasteboard");

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }
    }

    #[test]
    fn test_pasteboard_has_files_detects_filenames_pboard_type() {
        use objc2::rc::autoreleasepool;
        let _guard = PASTEBOARD_TEST_LOCK.lock().unwrap();
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        autoreleasepool(|_| unsafe {
            let cls = nspasteboard_class().unwrap();
            let pb: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
            let _: isize = msg_send![pb, clearContents];
            let nsstr_cls = objc2::runtime::AnyClass::get(c"NSString").unwrap();
            let filenames_type: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: c"NSFilenamesPboardType".as_ptr()];
            let array_cls = objc2::runtime::AnyClass::get(c"NSArray").unwrap();
            let types_arr: *mut objc2::runtime::NSObject =
                msg_send![array_cls, arrayWithObject: filenames_type];
            let _: isize = msg_send![pb, declareTypes: types_arr, owner: core::ptr::null::<objc2::runtime::NSObject>()];
        });

        assert!(pasteboard_has_files(), "pasteboard_has_files must detect NSFilenamesPboardType");
        assert!(pasteboard_image_data().is_none(), "pasteboard_image_data must reject NSFilenamesPboardType");

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }
    }

    #[test]
    fn test_pasteboard_has_files_detects_icns_and_blocks_icon_capture() {
        use objc2::rc::autoreleasepool;
        let _guard = PASTEBOARD_TEST_LOCK.lock().unwrap();
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        autoreleasepool(|_| unsafe {
            let cls = nspasteboard_class().unwrap();
            let pb: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
            let _: isize = msg_send![pb, clearContents];
            let nsstr_cls = objc2::runtime::AnyClass::get(c"NSString").unwrap();
            let icns_type: *mut objc2::runtime::NSObject =
                msg_send![nsstr_cls, stringWithUTF8String: c"com.apple.icns".as_ptr()];
            let nsdata_cls = objc2::runtime::AnyClass::get(c"NSData").unwrap();
            let dummy_bytes = b"dummy_icns_bytes";
            let data_obj: *mut objc2::runtime::NSObject =
                msg_send![nsdata_cls, dataWithBytes: dummy_bytes.as_ptr().cast::<core::ffi::c_void>(), length: dummy_bytes.len()];
            let _: bool = msg_send![pb, setData: data_obj, forType: icns_type];
        });

        assert!(pasteboard_has_files(), "pasteboard_has_files must detect com.apple.icns");
        assert!(pasteboard_image_data().is_none(), "pasteboard_image_data must reject com.apple.icns");

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }
    }

    #[test]
    fn test_pasteboard_has_files_returns_false_for_plain_text() {
        let _guard = PASTEBOARD_TEST_LOCK.lock().unwrap();
        let mut cb = Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        cb.set_text("regular text without files").unwrap();
        assert!(!pasteboard_has_files(), "pasteboard_has_files must be false for plain text");

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }
    }
}
