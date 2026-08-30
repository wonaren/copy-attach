//! macOS pasteboard, paste simulation, and accessibility implementation.
//!
//! Moved from the former top-level `macos` module and extended to the
//! unified `platform` API. Image capture keeps the macOS-optimized path:
//! read the smallest full-resolution representation (PNG → TIFF → JPEG →
//! GIF → WebP → BMP) directly instead of `arboard` (whose macOS backend
//! reads `public.tiff`, ~22.5 MB per screenshot), then decode.

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

/// Read the first supported image representation, preferring smaller formats.
pub(crate) fn pasteboard_image_data() -> Option<Vec<u8>> {
    use objc2::rc::autoreleasepool;
    autoreleasepool(|_| unsafe {
        let cls = nspasteboard_class()?;
        let pasteboard: *mut objc2::runtime::NSObject = msg_send![cls, generalPasteboard];
        if pasteboard.is_null() {
            return None;
        }
        let nsstr_cls = objc2::runtime::AnyClass::get(c"NSString")?;
        // Smallest full-resolution representation first.
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
            crate::backend::claim_pages(owned.as_ptr(), owned.capacity());
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
pub(crate) fn change_count() -> Option<i64> {
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

/// Whether the pasteboard contains file URLs (to skip capturing the icon).
pub(crate) fn has_files() -> bool {
    unsafe { !pasteboard_file_url_strings().is_empty() }
}

/// Extract absolute file paths from pasteboard file URLs; skips unusable ones.
pub(crate) fn file_paths() -> Vec<String> {
    unsafe {
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
    }
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
pub(crate) fn set_clipboard_file_url(path: &str) -> bool {
    unsafe {
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
    }
}

/// Read UTF-8 text from the pasteboard via `arboard`.
pub(crate) fn read_text() -> Option<String> {
    match arboard::Clipboard::new() {
        Ok(mut cb) => cb.get_text().ok(),
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open pasteboard for text read: {e}");
            None
        }
    }
}

/// Capture a full-resolution clipboard image as RGBA, using the direct
/// pasteboard representation read (not `arboard`) plus the shared decode
/// pipeline: fast path for 8-bit RGBA PNGs, generic decoder otherwise.
pub(crate) fn capture_image() -> Option<(crate::backend::ImageDecodeBuffer, u32, u32)> {
    // The guard marks the raw pasteboard bytes' pages reusable on drop —
    // release-path symmetry with the claim in `pasteboard_image_data`
    // (the buffer is dead after decoding).
    let img_bytes = pasteboard_image_data().map(crate::backend::MarkBlobReusableOnDrop)?;
    let decoded: Result<(crate::backend::ImageDecodeBuffer, u32, u32), image::ImageError> = {
        let mut pooled = crate::backend::ImageDecodeBuffer::acquire();
        match crate::image::decode_png_rgba8_into(&img_bytes.0, pooled.as_mut_vec()) {
            Some((w, h)) => Ok((pooled, w, h)),
            None => {
                drop(pooled);
                image::load_from_memory(&img_bytes.0).map(|img| {
                    let rgba = img.to_rgba8();
                    let (w, h) = rgba.dimensions();
                    (
                        crate::backend::ImageDecodeBuffer::from_vec(rgba.into_raw()),
                        w, h,
                    )
                })
            }
        }
    };
    match decoded {
        Ok(result) => Some(result),
        Err(e) => {
            // Undecodable image data: fail explicitly, don't fabricate a capture.
            crate::debug_log!("CopyAttach: pasteboard image data ({} bytes) undecodable: {e}", img_bytes.0.len());
            None
        }
    }
}

/// Write UTF-8 text to the pasteboard via `arboard`.
pub(crate) fn set_clipboard_text(text: &str) -> bool {
    let mut cb = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open pasteboard for text write: {e}");
            return false;
        }
    };
    match cb.set_text(text) {
        Ok(()) => true,
        Err(e) => {
            crate::error_log!("CopyAttach: pasteboard text write failed: {e}");
            false
        }
    }
}

/// Not used on macOS (image paste goes through the file-URL convention in
/// `ffi::paste`), but part of the unified platform API.
pub(crate) fn set_clipboard_image(png_data: &[u8]) -> bool {
    let img = match image::load_from_memory(png_data) {
        Ok(img) => img.to_rgba8(),
        Err(e) => {
            crate::error_log!("CopyAttach: cannot decode paste PNG: {e}");
            return false;
        }
    };
    let (w, h) = (img.width() as usize, img.height() as usize);
    let data = img.into_raw();
    let mut cb = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open pasteboard for image write: {e}");
            return false;
        }
    };
    let arboard_img = arboard::ImageData {
        width: w,
        height: h,
        bytes: std::borrow::Cow::Borrowed(&data),
    };
    cb.set_image(arboard_img).is_ok()
}

/// Simulate Cmd+V key press via `CGEventPostToPid`.
/// `pid` must be the frontmost application's process identifier (> 0).
/// Returns `false` if pid is 0 or event creation fails.
pub(crate) fn simulate_paste(pid: i32) -> bool {
    if pid <= 0 {
        crate::error_log!("CopyAttach: simulate_paste: no target PID (frontmost app unknown)");
        return false;
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

    /// Roundtrip file-URL pasteboard write/read, restoring the user's clipboard.
    #[test]
    fn test_set_pasteboard_file_url_roundtrip() {
        let mut cb = arboard::Clipboard::new().unwrap();
        let saved_text = cb.get_text().ok();
        let saved_image = cb.get_image().ok();

        let path = "/tmp/copyattach-paste-check.png";
        let ok_set = set_clipboard_file_url(path);
        let paths = file_paths();

        if let Some(img) = saved_image {
            cb.set_image(img).unwrap();
        } else if let Some(text) = saved_text {
            cb.set_text(text).unwrap();
        }

        assert!(ok_set, "set_clipboard_file_url must succeed");
        assert_eq!(
            paths,
            vec![path.to_string()],
            "pasteboard must expose exactly the written path"
        );
    }
}
