//! Windows clipboard, capture, and paste-simulation implementation.
//!
//! - Change detection uses `GetClipboardSequenceNumber` (equivalent of the
//!   macOS `changeCount`): cheap, requires no clipboard open, and increments
//!   for our own writes — the `pending_self_write` mechanism works unchanged.
//! - Image capture reads whatever `arboard` translates from `CF_DIB`.
//! - Image paste writes a decoded RGBA image through `arboard` (`CF_DIB`),
//!   which mainstream Windows apps (Paint/Word/chat clients) accept directly.
//!   The macOS file-URL paste convention does not exist on Windows.
//! - Paste simulation is `SendInput` Ctrl+V aimed at the foreground window;
//!   `pid` is unused (foreground-target tracking comes with the Windows
//!   frontend's foreground-window tracking, later iteration).

use arboard::Clipboard;

use crate::backend::ImageDecodeBuffer;

/// Clipboard sequence number; the Windows counterpart of `changeCount`.
pub(crate) fn change_count() -> Option<i64> {
    // SAFETY: GetClipboardSequenceNumber takes no arguments and never opens
    // the clipboard.
    unsafe {
        Some(windows_sys::Win32::System::DataExchange::GetClipboardSequenceNumber() as i64)
    }
}

/// Whether the clipboard carries a file drop list (CF_HDROP). Not captured in
/// the Windows MVP; file-copy capture is a later iteration.
pub(crate) fn has_files() -> bool {
    false
}

/// Absolute paths of file drop entries. Unused while [`has_files`] is `false`.
pub(crate) fn file_paths() -> Vec<String> {
    vec![]
}

/// Read UTF-16 text from the clipboard. Opens a fresh handle: the clipboard
/// must never be held open across poll iterations on Windows.
pub(crate) fn read_text() -> Option<String> {
    match Clipboard::new() {
        Ok(mut cb) => match cb.get_text() {
            Ok(text) => Some(text),
            Err(e) => {
                crate::debug_log!("CopyAttach: clipboard text read failed: {e}");
                None
            }
        },
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open clipboard for text read: {e}");
            None
        }
    }
}

/// Capture a full-resolution image as RGBA. `arboard` converts `CF_DIB` to
/// RGBA; the buffer is claimed on the reusable-page contract on the way in.
pub(crate) fn capture_image() -> Option<(ImageDecodeBuffer, u32, u32)> {
    let mut cb = match Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open clipboard for image capture: {e}");
            return None;
        }
    };
    match cb.get_image() {
        Ok(img) => {
            if img.width == 0 || img.height == 0 {
                return None;
            }
            let rgba = img.bytes.into_owned();
            let buf = ImageDecodeBuffer::from_vec(rgba);
            Some((buf, img.width as u32, img.height as u32))
        }
        Err(_) => None, // No image on the clipboard (normal for text copies).
    }
}

/// Write UTF-8 text to the clipboard.
pub(crate) fn set_clipboard_text(text: &str) -> bool {
    match Clipboard::new() {
        Ok(mut cb) => cb.set_text(text).is_ok(),
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open clipboard for text write: {e}");
            false
        }
    }
}

/// Decode `png_data` and put the image on the clipboard as RGBA (`CF_DIB`).
pub(crate) fn set_clipboard_image(png_data: &[u8]) -> bool {
    let img = match image::load_from_memory(png_data) {
        Ok(img) => img.to_rgba8(),
        Err(e) => {
            crate::error_log!("CopyAttach: cannot decode paste PNG ({:?}): {e}", &png_data[..png_data.len().min(8)]);
            return false;
        }
    };
    let (w, h) = (img.width() as usize, img.height() as usize);
    let data = img.into_raw();
    match Clipboard::new() {
        Ok(mut cb) => {
            let arboard_img = arboard::ImageData {
                width: w,
                height: h,
                bytes: std::borrow::Cow::Borrowed(&data),
            };
            match cb.set_image(arboard_img) {
                Ok(()) => true,
                Err(e) => {
                    crate::error_log!("CopyAttach: clipboard image write failed ({w}x{h}): {e}");
                    false
                }
            }
        }
        Err(e) => {
            crate::error_log!("CopyAttach: failed to open clipboard for image write: {e}");
            false
        }
    }
}

/// Simulate Ctrl+V on the foreground window via `SendInput`.
/// The `pid` argument is accepted for API parity with macOS; Windows input
/// goes to the foreground window.
pub(crate) fn simulate_paste(_pid: i32) -> bool {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT,
        KEYEVENTF_KEYUP, VK_CONTROL, VK_V,
    };

    fn key_input(vk: u16, keyup: bool) -> INPUT {
        let mut ki = KEYBDINPUT {
            wVk: vk,
            wScan: 0,
            dwFlags: 0,
            time: 0,
            dwExtraInfo: 0,
        };
        if keyup {
            ki.dwFlags = KEYEVENTF_KEYUP;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki },
        }
    }

    let inputs = [
        key_input(VK_CONTROL as u16, false),
        key_input(VK_V as u16, false),
        key_input(VK_V as u16, true),
        key_input(VK_CONTROL as u16, true),
    ];
    // SAFETY: `inputs` is a valid array of INPUT; cbSize matches its element
    // size as required by SendInput.
    let sent = unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_ptr(),
            std::mem::size_of::<INPUT>() as i32,
        )
    };
    if sent != inputs.len() as u32 {
        crate::error_log!("CopyAttach: SendInput delivered {sent}/{} events for Ctrl+V", inputs.len());
        return false;
    }
    true
}

/// Windows needs no accessibility gate for SendInput.
pub(crate) fn check_permission() -> bool {
    true
}

/// No system preferences pane to open on Windows.
pub(crate) fn open_preferences() {}
