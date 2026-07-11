//! 🗂️ CopyAttach - Rust Backend Library
//!
//! Provides clipboard monitoring, history management, and C FFI for use by a Swift frontend.

#![allow(dead_code)]

use std::ffi::{c_char, c_int, c_longlong, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use arboard::Clipboard;
use serde::{Deserialize, Serialize};

// ═══════════════════════════════════════════
// serde helpers — base64 for binary Vec<u8>
// ═══════════════════════════════════════════

mod base64_serde {
    use base64::{Engine as _, engine::general_purpose};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        <String as Deserialize>::deserialize(deserializer).and_then(|s| {
            general_purpose::STANDARD.decode(&s).map_err(serde::de::Error::custom)
        })
    }
}

// ═══════════════════════════════════════════
// Types
// ═══════════════════════════════════════════

/// Source app info
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct SourceApp {
    name: String,
    bundle_id: String,
}

/// A clipboard history entry
///
/// NOTE: When adding new fields to any variant, make sure to add `#[serde(default)]`
/// to maintain forward compatibility with previously persisted files.
#[derive(Clone, Debug, Serialize, Deserialize)]
enum ClipboardEntry {
    Text {
        text: String,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        source_name: String,
        #[serde(default)]
        source_bundle_id: String,
    },
    Image {
        #[serde(with = "base64_serde")]
        png_data: Vec<u8>,
        width: u32,
        height: u32,
        /// Thumbnail PNG data. Uses empty vec as default for forward compat.
        #[serde(default, with = "base64_serde")]
        thumb_data: Vec<u8>,
        #[serde(default)]
        thumb_width: u32,
        #[serde(default)]
        thumb_height: u32,
        #[serde(default)]
        hash: u64,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        source_name: String,
        #[serde(default)]
        source_bundle_id: String,
    },
}

impl ClipboardEntry {
    fn timestamp(&self) -> u64 {
        match self {
            ClipboardEntry::Text { timestamp, .. } => *timestamp,
            ClipboardEntry::Image { timestamp, .. } => *timestamp,
        }
    }

    fn content_type(&self) -> i32 {
        match self {
            ClipboardEntry::Text { .. } => 0,
            ClipboardEntry::Image { .. } => 1,
        }
    }

    fn source_name(&self) -> &str {
        match self {
            ClipboardEntry::Text { source_name, .. } => source_name,
            ClipboardEntry::Image { source_name, .. } => source_name,
        }
    }

    fn source_bundle_id(&self) -> &str {
        match self {
            ClipboardEntry::Text { source_bundle_id, .. } => source_bundle_id,
            ClipboardEntry::Image { source_bundle_id, .. } => source_bundle_id,
        }
    }

    fn label(&self) -> String {
        match self {
            ClipboardEntry::Text { text, .. } => {
                let first = text
                    .lines()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or(text);
                // Count characters, not bytes, to avoid UTF-8 slicing issues
                let char_count: usize = first.chars().count();
                if char_count > 60 {
                    // Take first 59 characters, then add '…'
                    let truncated: String = first.chars().take(59).collect();
                    format!("{}…", truncated)
                } else {
                    first.to_string()
                }
            }
            ClipboardEntry::Image { width, height, .. } => {
                format!("📷 图片 ({}×{})", width, height)
            }
        }
    }
}

// ═══════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════

const MAX_HISTORY: usize = 1000;
const POLL_INTERVAL_MS: u64 = 300;

// ═══════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════

struct Backend {
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    source_app: Arc<Mutex<SourceApp>>,
    save_needed: Arc<AtomicBool>,
}

static BACKEND: OnceLock<Backend> = OnceLock::new();

fn backend() -> &'static Backend {
    BACKEND.get().expect("Clipboard backend not initialized. Call clipboard_init() first.")
}

// ═══════════════════════════════════════════
// Image Processing
// ═══════════════════════════════════════════

fn encode_png(width: u32, height: u32, rgba_bytes: &[u8]) -> Option<Vec<u8>> {
    use image::{ImageBuffer, Rgba};
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let mut output = Vec::new();
    img.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some(output)
}

fn decode_png(png_data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let img = image::load_from_memory(png_data).ok()?;
    let rgba = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    Some((rgba.into_raw(), w, h))
}

fn create_thumbnail(width: u32, height: u32, rgba_bytes: &[u8], max_dim: u32) -> Option<(Vec<u8>, u32, u32)> {
    use image::{ImageBuffer, Rgba, imageops::FilterType};
    let scale = (max_dim as f64 / width.max(height) as f64).min(1.0);
    if scale >= 1.0 {
        return encode_png(width, height, rgba_bytes).map(|d| (d, width, height));
    }
    let new_w = (width as f64 * scale).round() as u32;
    let new_h = (height as f64 * scale).round() as u32;
    let img = ImageBuffer::<Rgba<u8>, &[u8]>::from_raw(width, height, rgba_bytes)?;
    let thumb = image::imageops::resize(&img, new_w.max(1), new_h.max(1), FilterType::Lanczos3);
    let mut output = Vec::new();
    thumb.write_to(&mut std::io::Cursor::new(&mut output), image::ImageFormat::Png).ok()?;
    Some((output, new_w.max(1), new_h.max(1)))
}

fn image_hash(data: &[u8], width: u32, height: u32) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    width.hash(&mut hasher);
    height.hash(&mut hasher);
    data.hash(&mut hasher);
    hasher.finish()
}

// ═══════════════════════════════════════════
// History Management
// ═══════════════════════════════════════════

fn add_to_history(mut history: Vec<ClipboardEntry>, item: ClipboardEntry) -> Vec<ClipboardEntry> {
    match &item {
        ClipboardEntry::Text { text, .. } => {
            history.retain(|e| match e {
                ClipboardEntry::Text { text: t, .. } => t != text,
                _ => true,
            });
        }
        ClipboardEntry::Image { hash, .. } => {
            history.retain(|e| match e {
                ClipboardEntry::Image { hash: h, .. } => h != hash,
                _ => true,
            });
        }
    }
    history.insert(0, item);
    while history.len() > MAX_HISTORY {
        history.pop();
    }
    // Mark save needed (done periodically from monitor thread)
    if let Some(b) = BACKEND.get() {
        b.save_needed.store(true, Ordering::SeqCst);
    }
    history
}

// ═══════════════════════════════════════════
// Persistence
// ═══════════════════════════════════════════

/// Returns the path to the history JSON file.
fn get_persist_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("history.json"))
}

/// Load history from the persistence file.
fn load_history_from_file() -> Vec<ClipboardEntry> {
    let path = match get_persist_path() {
        Some(p) => p,
        None => return Vec::new(),
    };
    let data = match std::fs::read(&path) {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };
    serde_json::from_slice(&data).unwrap_or_else(|e| {
        eprintln!("CopyAttach: failed to parse history file: {}", e);
        Vec::new()
    })
}

/// Save history to the persistence file atomically (write to temp, then rename).
fn save_history_to_file(history: &[ClipboardEntry]) {
    let path = match get_persist_path() {
        Some(p) => p,
        None => return,
    };
    let json = match serde_json::to_string(history) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("CopyAttach: failed to serialize history: {}", e);
            return;
        }
    };
    // Write to a temp file first, then atomically rename to avoid corruption on crash.
    let tmp = path.with_extension("json.tmp");
    if let Err(e) = std::fs::write(&tmp, &json) {
        eprintln!("CopyAttach: failed to write history file: {}", e);
        return;
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        eprintln!("CopyAttach: failed to rename history file: {}", e);
        let _ = std::fs::remove_file(&tmp);
    }
}

// ═══════════════════════════════════════════
// macOS: Paste Simulation & Permission Check
// ═══════════════════════════════════════════

#[cfg(target_os = "macos")]
mod mac {
    use std::ffi::c_int;
    use std::process::Command;
    use objc2_core_graphics::{
        CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID, CGEventTapLocation,
    };

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> c_int;
    }

    pub fn check_permission() -> bool {
        let result = unsafe { AXIsProcessTrusted() };
        result != 0
    }

    pub fn open_preferences() {
        let _ = Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn();
    }

    pub fn simulate_cmd_v() {
        let source = CGEventSource::new(CGEventSourceStateID::Private);
        let source = source.as_ref().map(|s| &**s);
        if let Some(ev) = CGEvent::new_keyboard_event(source, 9, true) {
            CGEvent::set_flags(Some(&*ev), CGEventFlags::MaskCommand);
            CGEvent::post(CGEventTapLocation::SessionEventTap, Some(&*ev));
        }
        if let Some(ev) = CGEvent::new_keyboard_event(source, 9, false) {
            CGEvent::set_flags(Some(&*ev), CGEventFlags::MaskCommand);
            CGEvent::post(CGEventTapLocation::SessionEventTap, Some(&*ev));
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod mac {
    pub fn check_permission() -> bool { true }
    pub fn open_preferences() {}
    pub fn simulate_cmd_v() {
        eprintln!("Warning: paste simulation only supported on macOS");
    }
}

// ═══════════════════════════════════════════
// Clipboard Monitor (background thread)
// ═══════════════════════════════════════════

fn clipboard_monitor(
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    source_app: Arc<Mutex<SourceApp>>,
    save_needed: Arc<AtomicBool>,
) {
    let mut cb = match Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("clipboard-monitor: failed to open clipboard: {e}");
            return;
        }
    };

    let mut last_text: Option<String> = None;
    let mut last_image_hash: Option<u64> = None;

    while running.load(Ordering::SeqCst) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // Capture the current source app (set by Swift from the main thread)
        let src = source_app.lock().unwrap().clone();

        // Try image FIRST. On macOS, image clips often also have text representation.
        let image_result = cb.get_image();

        if let Ok(img_data) = image_result {
            let hash = image_hash(&img_data.bytes, img_data.width as u32, img_data.height as u32);
            let is_new = match last_image_hash {
                Some(h) => h != hash,
                None => true,
            };

            if is_new && img_data.width > 0 && img_data.height > 0 {
                if let Some(png_data) = encode_png(
                    img_data.width as u32, img_data.height as u32, &img_data.bytes,
                ) {
                    let thumb = create_thumbnail(
                        img_data.width as u32, img_data.height as u32, &img_data.bytes, 300,
                    );
                    let (thumb_data, thumb_w, thumb_h) = thumb.unwrap_or_else(|| {
                        (png_data.clone(), img_data.width as u32, img_data.height as u32)
                    });

                    let item = ClipboardEntry::Image {
                        png_data,
                        width: img_data.width as u32,
                        height: img_data.height as u32,
                        thumb_data,
                        thumb_width: thumb_w,
                        thumb_height: thumb_h,
                        hash,
                        timestamp: now,
                        source_name: src.name,
                        source_bundle_id: src.bundle_id,
                    };

                    let mut hist = history.lock().unwrap();
                    let new_hist = add_to_history(std::mem::take(&mut *hist), item);
                    *hist = new_hist;
                    last_image_hash = Some(hash);
                    last_text = None;
                }
            } else if is_new {
                last_image_hash = Some(hash);
            }
        } else {
            // No image, try text
            if let Ok(text) = cb.get_text() {
                let is_new = match &last_text {
                    Some(last) => &text != last,
                    None => !text.is_empty(),
                };

                if !text.is_empty() && is_new {
                    // Skip very short or whitespace-only text (likely system artifacts)
                    let trimmed = text.trim();
                    if trimmed.len() >= 2 {
                        let item = ClipboardEntry::Text {
                            text: text.clone(),
                            timestamp: now,
                            source_name: src.name,
                            source_bundle_id: src.bundle_id,
                        };

                        let mut hist = history.lock().unwrap();
                        let new_hist = add_to_history(std::mem::take(&mut *hist), item);
                        *hist = new_hist;
                    }
                    last_text = Some(text);
                    last_image_hash = None;
                }
            }
        }

        // Periodically save history if needed
        if save_needed.load(Ordering::Relaxed) {
            let hist_copy = history.lock().unwrap().clone();
            save_history_to_file(&hist_copy);
            save_needed.store(false, Ordering::SeqCst);
        }

        for _ in 0..10 {
            if !running.load(Ordering::SeqCst) { return; }
            thread::sleep(Duration::from_millis(POLL_INTERVAL_MS / 10));
        }
    }
}

// ═══════════════════════════════════════════
// C FFI - Exported Functions
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_init() -> c_int {
    // Load persisted history from disk
    let saved = load_history_from_file();
    // Trim to MAX_HISTORY in case the file grew beyond the cap
    let saved: Vec<ClipboardEntry> = saved.into_iter().take(MAX_HISTORY).collect();

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(SourceApp::default()));
    let save_needed = Arc::new(AtomicBool::new(false));

    let backend = Backend {
        history: Arc::clone(&history),
        running: Arc::clone(&running),
        monitor_handle: Mutex::new(None),
        source_app: Arc::clone(&source_app),
        save_needed: Arc::clone(&save_needed),
    };

    // Set BACKEND BEFORE spawning the monitor thread, so add_to_history
    // can always find the global and set save_needed correctly.
    let prev = BACKEND.set(backend);
    match prev {
        Err(_) => return 0, // Already initialized
        Ok(()) => {}
    }

    // Spawn the monitor thread after BACKEND is live.
    let handle = thread::spawn(|| clipboard_monitor(
        history, running, source_app, save_needed,
    ));

    // Store the join handle so cleanup can join it.
    if let Some(b) = BACKEND.get() {
        if let Ok(mut h) = b.monitor_handle.lock() {
            *h = Some(handle);
        }
    }

    1
}

#[no_mangle]
pub extern "C" fn clipboard_cleanup() {
    if let Some(b) = BACKEND.get() {
        // Signal the monitor thread to stop FIRST, before any save.
        b.running.store(false, Ordering::SeqCst);

        // Wait for the monitor to finish (it may do a final save).
        if let Ok(mut handle) = b.monitor_handle.lock() {
            if let Some(h) = handle.take() {
                let _ = h.join();
            }
        }

        // Now it's safe to do a final save — no concurrent writes.
        let hist_copy = b.history.lock().unwrap().clone();
        save_history_to_file(&hist_copy);
    }
}

/// Set the current frontmost app info (called periodically from Swift).
#[no_mangle]
pub extern "C" fn clipboard_set_source_app(name: *const c_char, bundle_id: *const c_char) {
    let name = if name.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    let bundle_id = if bundle_id.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(bundle_id) }.to_string_lossy().into_owned()
    };
    if let Some(b) = BACKEND.get() {
        let mut src = b.source_app.lock().unwrap();
        src.name = name;
        src.bundle_id = bundle_id;
    }
}

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.len() as c_int
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_type(index: c_int) -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(-1, |item| item.content_type())
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_timestamp(index: c_int) -> c_longlong {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(0, |item| item.timestamp() as c_longlong)
}

/// Get source app name. Caller must free with clipboard_free_string().
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_name(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let name = match hist.get(index as usize) {
        Some(item) => item.source_name(),
        None => return std::ptr::null_mut(),
    };
    CString::new(name).unwrap_or_default().into_raw()
}

/// Get source app bundle ID. Caller must free with clipboard_free_string().
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_bundle_id(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let bid = match hist.get(index as usize) {
        Some(item) => item.source_bundle_id(),
        None => return std::ptr::null_mut(),
    };
    CString::new(bid).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_label(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let label = match hist.get(index as usize) {
        Some(item) => item.label(),
        None => return std::ptr::null_mut(),
    };
    CString::new(label).unwrap_or_default().into_raw()
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_text(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Text { text, .. }) => {
            CString::new(text.as_str()).unwrap_or_default().into_raw()
        }
        _ => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_get_image_thumb(index: c_int, out_len: *mut c_int) -> *mut u8 {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Image { thumb_data, .. }) => {
            let len = thumb_data.len() as c_int;
            if out_len.is_null() { return std::ptr::null_mut(); }
            unsafe { *out_len = len; }
            vec_to_raw(thumb_data.clone())
        }
        _ => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_get_image_full(index: c_int, out_len: *mut c_int) -> *mut u8 {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Image { png_data, .. }) => {
            let len = png_data.len() as c_int;
            if out_len.is_null() { return std::ptr::null_mut(); }
            unsafe { *out_len = len; }
            vec_to_raw(png_data.clone())
        }
        _ => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_get_image_size(index: c_int, out_width: *mut c_int, out_height: *mut c_int) -> c_int {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Image { width, height, .. }) => {
            if !out_width.is_null() { unsafe { *out_width = *width as c_int; } }
            if !out_height.is_null() { unsafe { *out_height = *height as c_int; } }
            1
        }
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_free_string(s: *mut c_char) {
    if s.is_null() { return; }
    unsafe { let _ = CString::from_raw(s); }
}

#[no_mangle]
pub extern "C" fn clipboard_free_bytes(data: *mut u8, len: c_int) {
    if data.is_null() { return; }
    unsafe { let _ = Vec::from_raw_parts(data, len as usize, len as usize); }
}

fn vec_to_raw(v: Vec<u8>) -> *mut u8 {
    let mut v = v;
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    ptr
}

#[no_mangle]
pub extern "C" fn clipboard_select_and_paste(index: c_int) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        hist.get(index as usize).cloned()
    };
    let item = match item { Some(i) => i, None => return 0 };

    let mut cb = match Clipboard::new() { Ok(c) => c, Err(_) => return 0 };

    match &item {
        ClipboardEntry::Text { text, .. } => {
            if cb.set_text(text).is_err() { return 0; }
        }
        ClipboardEntry::Image { png_data, width, height, .. } => {
            if let Some((rgba, _, _)) = decode_png(png_data) {
                let img = arboard::ImageData {
                    width: *width as usize,
                    height: *height as usize,
                    bytes: rgba.into(),
                };
                if cb.set_image(img).is_err() { return 0; }
            } else { return 0; }
        }
    }

    thread::sleep(Duration::from_millis(50));
    #[cfg(target_os = "macos")]
    { if mac::check_permission() { mac::simulate_cmd_v(); } }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_check_permission() -> c_int {
    #[cfg(target_os = "macos")]
    { mac::check_permission() as c_int }
    #[cfg(not(target_os = "macos"))]
    { 1 }
}

#[no_mangle]
pub extern "C" fn clipboard_open_preferences() {
    #[cfg(target_os = "macos")]
    mac::open_preferences();
}

#[no_mangle]
pub extern "C" fn clipboard_clear_history() {
    if let Some(b) = BACKEND.get() {
        // Clear in-memory history
        {
            let mut hist = b.history.lock().unwrap();
            hist.clear();
        }
        // Delete the persistence file
        if let Some(path) = get_persist_path() {
            let _ = std::fs::remove_file(&path);
            // Also remove temp file if present
            let tmp = path.with_extension("json.tmp");
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

// ═══════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn make_text(text: &str, ts: u64) -> ClipboardEntry {
        ClipboardEntry::Text {
            text: text.to_string(),
            timestamp: ts,
            source_name: String::new(),
            source_bundle_id: String::new(),
        }
    }

    fn make_image(data: &[u8], w: u32, h: u32, ts: u64) -> ClipboardEntry {
        let hash = image_hash(data, w, h);
        let png = encode_png(w, h, data).unwrap();
        let thumb = create_thumbnail(w, h, data, 100).unwrap();
        ClipboardEntry::Image {
            png_data: png,
            width: w,
            height: h,
            thumb_data: thumb.0,
            thumb_width: thumb.1,
            thumb_height: thumb.2,
            hash,
            timestamp: ts,
            source_name: String::new(),
            source_bundle_id: String::new(),
        }
    }

    fn make_test_image_rgba(w: u32, h: u32, fill_byte: u8) -> Vec<u8> {
        vec![fill_byte; (w * h * 4) as usize]
    }

    #[test]
    fn test_add_text_item() {
        let history = vec![];
        let item = make_text("hello world", 100);
        let result = add_to_history(history, item);
        assert_eq!(result.len(), 1);
        if let ClipboardEntry::Text { text, .. } = &result[0] {
            assert_eq!(text, "hello world");
        } else { panic!("Expected Text entry"); }
    }

    #[test]
    fn test_text_deduplication() {
        let history = vec![make_text("duplicate", 100)];
        let item = make_text("duplicate", 200);
        let result = add_to_history(history, item);
        assert_eq!(result.len(), 1);
        if let ClipboardEntry::Text { timestamp, .. } = &result[0] {
            assert_eq!(*timestamp, 200);
        }
    }

    #[test]
    fn test_max_history_limit() {
        let mut history = vec![];
        for i in 0..MAX_HISTORY + 50 {
            let item = make_text(&format!("item_{}", i), i as u64);
            history = add_to_history(history, item);
        }
        assert_eq!(history.len(), MAX_HISTORY);
        if let ClipboardEntry::Text { text, .. } = &history[0] {
            assert!(text.starts_with("item_"));
        }
    }

    #[test]
    fn test_text_and_image_mixed() {
        let history = vec![];
        let t1 = make_text("text1", 100);
        let img_data = make_test_image_rgba(10, 10, 128);
        let i1 = make_image(&img_data, 10, 10, 200);
        let history = add_to_history(history, t1);
        let history = add_to_history(history, i1);
        assert_eq!(history.len(), 2);
        assert!(matches!(history[0], ClipboardEntry::Image { .. }));
        assert!(matches!(history[1], ClipboardEntry::Text { .. }));
    }

    #[test]
    fn test_image_deduplication() {
        let img_data = make_test_image_rgba(8, 8, 200);
        let img1 = make_image(&img_data, 8, 8, 100);
        let img2 = make_image(&img_data, 8, 8, 200);
        let history = vec![img1];
        let result = add_to_history(history, img2);
        assert_eq!(result.len(), 1);
        if let ClipboardEntry::Image { timestamp, .. } = &result[0] {
            assert_eq!(*timestamp, 200);
        }
    }

    #[test]
    fn test_encode_decode_png() {
        let rgba = make_test_image_rgba(16, 16, 100);
        let png = encode_png(16, 16, &rgba).expect("encode should succeed");
        assert!(!png.is_empty());
        let (decoded, w, h) = decode_png(&png).expect("decode should succeed");
        assert_eq!(w, 16);
        assert_eq!(h, 16);
        assert_eq!(decoded.len(), 16 * 16 * 4);
    }

    #[test]
    fn test_create_thumbnail() {
        let rgba = make_test_image_rgba(200, 100, 150);
        let thumb = create_thumbnail(200, 100, &rgba, 50);
        assert!(thumb.is_some());
        let (_, tw, th) = thumb.unwrap();
        assert!(tw <= 50 && th <= 50);
    }

    #[test]
    fn test_image_hash_consistency() {
        let data1 = make_test_image_rgba(10, 10, 200);
        let data2 = make_test_image_rgba(10, 10, 200);
        assert_eq!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
    }

    #[test]
    fn test_image_hash_different() {
        let data1 = make_test_image_rgba(10, 10, 200);
        let data2 = make_test_image_rgba(10, 10, 100);
        assert_ne!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
    }

    #[test]
    fn test_source_app_fields() {
        let mut t = make_text("hello", 1);
        let img_data = make_test_image_rgba(5, 5, 50);
        let mut i = make_image(&img_data, 5, 5, 2);
        // Set source app info
        if let ClipboardEntry::Text { ref mut source_name, ref mut source_bundle_id, .. } = t {
            *source_name = "Safari".into();
            *source_bundle_id = "com.apple.Safari".into();
        }
        if let ClipboardEntry::Image { ref mut source_name, ref mut source_bundle_id, .. } = i {
            *source_name = "Photos".into();
            *source_bundle_id = "com.apple.Photos".into();
        }
        assert_eq!(t.source_name(), "Safari");
        assert_eq!(t.source_bundle_id(), "com.apple.Safari");
        assert_eq!(i.source_name(), "Photos");
        assert_eq!(i.source_bundle_id(), "com.apple.Photos");
    }

    #[test]
    fn test_item_types() {
        let t = make_text("test", 1);
        let img_data = make_test_image_rgba(5, 5, 50);
        let i = make_image(&img_data, 5, 5, 2);
        assert_eq!(t.content_type(), 0);
        assert_eq!(i.content_type(), 1);
    }

    #[test]
    fn test_item_timestamps() {
        let t = make_text("a", 1000);
        let img_data = make_test_image_rgba(5, 5, 50);
        let i = make_image(&img_data, 5, 5, 2000);
        assert_eq!(t.timestamp(), 1000);
        assert_eq!(i.timestamp(), 2000);
    }

    #[test]
    fn test_add_multiple_items_order() {
        let history = vec![];
        let items = vec!["c", "b", "a"];
        let mut history = history;
        for (i, &s) in items.iter().enumerate() {
            history = add_to_history(history, make_text(s, i as u64));
        }
        assert_eq!(history.len(), 3);
        if let ClipboardEntry::Text { text, .. } = &history[0] {
            assert_eq!(text, "a");
        }
    }

    #[test]
    fn test_label_text() {
        let t = make_text("Hello World", 100);
        assert_eq!(t.label(), "Hello World");
    }

    #[test]
    fn test_label_image() {
        let img_data = make_test_image_rgba(1920, 1080, 128);
        let i = make_image(&img_data, 1920, 1080, 100);
        assert_eq!(i.label(), "📷 图片 (1920×1080)");
    }

    #[test]
    fn test_label_multibyte() {
        // Ensure slicing doesn't break on multi-byte characters
        let cn = "这是一个测试中文文本用于验证标签截断功能是否正常工作";
        let t = make_text(cn, 100);
        let label = t.label();
        // Label should not panic and should contain '…' if truncated
        assert!(label.chars().count() <= 61); // 60 chars max + maybe '…'
        assert!(label.contains("这是一个"));
    }

    #[test]
    fn test_free_string_null_safe() {
        clipboard_free_string(std::ptr::null_mut());
    }
}
