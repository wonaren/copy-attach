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
use rusqlite::Connection;

// ═══════════════════════════════════════════
// Types
// ═══════════════════════════════════════════

/// Source app info
#[derive(Clone, Debug, Default)]
struct SourceApp {
    name: String,
    bundle_id: String,
}

/// A clipboard history entry
#[derive(Clone, Debug)]
enum ClipboardEntry {
    Text {
        text: String,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
    },
    Image {
        png_data: Vec<u8>,
        width: u32,
        height: u32,
        thumb_data: Vec<u8>,
        thumb_width: u32,
        thumb_height: u32,
        hash: u64,
        timestamp: u64,
        source_name: String,
        source_bundle_id: String,
        /// SQLite row id for loading full image on demand (0 = unset).
        db_id: i64,
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

const CLEANUP_THRESHOLD: usize = 3000;
const POLL_INTERVAL_MS: u64 = 300;

// ═══════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════

struct Backend {
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    source_app: Arc<Mutex<SourceApp>>,
    last_seen_text: Arc<Mutex<Option<String>>>,
    last_seen_image_hash: Arc<Mutex<Option<u64>>>,
    db: Arc<Mutex<Connection>>,
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
    history
}

// ═══════════════════════════════════════════
// Persistence — SQLite (write-through)
// ═══════════════════════════════════════════

fn get_persist_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = PathBuf::from(&home).join("Library/Application Support/CopyAttach");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn open_db() -> Option<Connection> {
    let db_path = get_persist_dir()?.join("history.db");
    let conn = Connection::open(&db_path).map_err(|e| {
        eprintln!("CopyAttach: failed to open database: {}", e);
    }).ok()?;
    // Use mmap for BLOB reads (OS-managed page cache, reclaimable under pressure)
    // + minimal SQLite page cache (512KB instead of default 2MB+)
    let _ = conn.execute_batch(
        "PRAGMA mmap_size = 268435456;
         PRAGMA cache_size = -512;"
    );
    Some(conn)
}

fn ensure_history_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_type      INTEGER NOT NULL,
            text            TEXT,
            png_data        BLOB,
            width           INTEGER,
            height          INTEGER,
            thumb_data      BLOB,
            thumb_width     INTEGER,
            thumb_height    INTEGER,
            hash            INTEGER,
            timestamp       INTEGER NOT NULL,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT ''
        );"
    )
}

fn load_history_from_db(conn: &Connection) -> Vec<ClipboardEntry> {
    let mut stmt = match conn.prepare(
        "SELECT id, entry_type, text,
                width, height,
                thumb_data, thumb_width, thumb_height, hash,
                timestamp, source_name, source_bundle_id
         FROM clipboard_history
         ORDER BY id DESC
         LIMIT ?"
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("CopyAttach: failed to prepare load query: {}", e);
            return Vec::new();
        }
    };

    let rows = match stmt.query_map([CLEANUP_THRESHOLD as i64], |row| {
        let entry_type: i32 = row.get(1)?;
        Ok((entry_type,
            row.get::<_, i64>(0)?,               // id
            row.get::<_, Option<String>>(2)?,    // text
            row.get::<_, Option<i64>>(3)?,       // width
            row.get::<_, Option<i64>>(4)?,       // height
            row.get::<_, Option<Vec<u8>>>(5)?,   // thumb_data
            row.get::<_, Option<i64>>(6)?,       // thumb_width
            row.get::<_, Option<i64>>(7)?,       // thumb_height
            row.get::<_, Option<i64>>(8)?,       // hash
            row.get::<_, i64>(9)?,               // timestamp
            row.get::<_, String>(10)?,           // source_name
            row.get::<_, String>(11)?))          // source_bundle_id
    }) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("CopyAttach: failed to query history: {}", e);
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    let mut skipped = 0u32;
    for row in rows {
        let (entry_type, db_id, text, width, height, _thumb_data,
             thumb_width, thumb_height, hash, timestamp, source_name, source_bundle_id) = match row {
            Ok(r) => r,
            Err(e) => {
                eprintln!("CopyAttach: row read error at index {}: {}", result.len() + skipped as usize + 1, e);
                skipped += 1;
                continue;
            }
        };
        match entry_type {
            0 => result.push(ClipboardEntry::Text {
                text: text.unwrap_or_default(),
                timestamp: timestamp as u64,
                source_name,
                source_bundle_id,
            }),
            1 => result.push(ClipboardEntry::Image {
                png_data: Vec::new(),
                width: width.unwrap_or(0) as u32,
                height: height.unwrap_or(0) as u32,
                thumb_data: Vec::new(),
                thumb_width: thumb_width.unwrap_or(0) as u32,
                thumb_height: thumb_height.unwrap_or(0) as u32,
                hash: hash.unwrap_or(0) as u64,
                timestamp: timestamp as u64,
                source_name,
                source_bundle_id,
                db_id,
            }),
            _ => {
                eprintln!("CopyAttach: unknown entry_type {} in DB, skipped", entry_type);
                skipped += 1;
            }
        }
    }
    if skipped > 0 {
        eprintln!("CopyAttach: skipped {} corrupt or unknown row(s) during history load", skipped);
    }
    result
}

fn insert_entry_to_db(conn: &Connection, entry: &ClipboardEntry,
                      image_png: Option<&[u8]>, image_thumb: Option<(&[u8], u32, u32)>) {
    let result = match entry {
        ClipboardEntry::Text { text, timestamp, source_name, source_bundle_id } => {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id)
                 VALUES (0, ?1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?2, ?3, ?4)",
                rusqlite::params![text, *timestamp as i64, source_name, source_bundle_id],
            ).map(|_| ())
        }
        ClipboardEntry::Image { width, height,
                                thumb_width: _, thumb_height: _, hash,
                                timestamp, source_name, source_bundle_id, .. } => {
            let png = match image_png {
                Some(data) => data,
                None => return,
            };
            let (thumb_data, tw, th) = match image_thumb {
                Some(t) => t,
                None => return,
            };
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, png_data, width, height,
                     thumb_data, thumb_width, thumb_height, hash,
                     timestamp, source_name, source_bundle_id)
                 VALUES (1, NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                rusqlite::params![
                    png, *width as i64, *height as i64,
                    thumb_data, tw as i64, th as i64,
                    *hash as i64, *timestamp as i64,
                    source_name, source_bundle_id,
                ],
            ).map(|_| ())
        }
    };
    if let Err(e) = result {
        eprintln!("CopyAttach: failed to insert entry: {}", e);
    }
}

fn delete_matching_entry(conn: &Connection, entry: &ClipboardEntry) {
    let result = match entry {
        ClipboardEntry::Text { text, .. } => {
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 0 AND text = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 0 AND text = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![text],
            ).map(|_| ())
        }
        ClipboardEntry::Image { hash, .. } => {
            conn.execute(
                "DELETE FROM clipboard_history
                 WHERE entry_type = 1 AND hash = ?1
                   AND id != (SELECT id FROM clipboard_history
                              WHERE entry_type = 1 AND hash = ?1
                              ORDER BY id DESC LIMIT 1)",
                rusqlite::params![*hash as i64],
            ).map(|_| ())
        }
    };
    if let Err(e) = result {
        eprintln!("CopyAttach: failed to delete matching entry: {}", e);
    }
}

fn trim_db_history(conn: &Connection) {
    if let Err(e) = conn.execute(
        "DELETE FROM clipboard_history WHERE id NOT IN (
            SELECT id FROM clipboard_history ORDER BY id DESC LIMIT ?)",
        rusqlite::params![CLEANUP_THRESHOLD as i64],
    ) {
        eprintln!("CopyAttach: failed to trim DB history: {}", e);
    }
}

// Migration from legacy JSON file (feature-gated — remove after all users have migrated)
#[cfg(feature = "migration")]
fn migrate_from_json_to_db(conn: &mut Connection) {
    let dir = match get_persist_dir() {
        Some(d) => d,
        None => return,
    };

    let json_path = dir.join("history.json");
    if !json_path.exists() {
        return;
    }

    // Skip migration if DB already has data
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0),
    ).unwrap_or(0);
    if count > 0 {
        let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
        return;
    }

    let content = match std::fs::read_to_string(&json_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("CopyAttach: cannot read history.json for migration: {}", e);
            return;
        }
    };

    // Uses serde_json + base64 (transitive from serde_json feature)
    #[derive(serde::Deserialize)]
    struct LegacyText {
        text: String,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        source_name: String,
        #[serde(default)]
        source_bundle_id: String,
    }

    #[derive(serde::Deserialize)]
    struct LegacyImage {
        #[serde(default, deserialize_with = "decode_base64")]
        png_data: Vec<u8>,
        #[serde(default)]
        width: u32,
        #[serde(default)]
        height: u32,
        #[serde(default, deserialize_with = "decode_base64")]
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
    }

    fn decode_base64<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        let s = <String as serde::Deserialize>::deserialize(d)?;
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, &s)
            .map_err(serde::de::Error::custom)
    }

    #[derive(serde::Deserialize)]
    enum LegacyEntry {
        Text(LegacyText),
        Image(LegacyImage),
    }

    let entries: Vec<LegacyEntry> = match serde_json::from_str(&content) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("CopyAttach: failed to parse history.json: {}", e);
            return;
        }
    };

    // Insert oldest-first so autoincrement IDs increase with age
    let tx = match conn.transaction() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("CopyAttach: failed to begin migration transaction: {}", e);
            return;
        }
    };
    for entry in entries.iter().rev() {
        let result = match entry {
            LegacyEntry::Text(lt) => {
                tx.execute(
                    "INSERT INTO clipboard_history (entry_type, text, timestamp, source_name, source_bundle_id)
                     VALUES (0, ?1, ?2, ?3, ?4)",
                    rusqlite::params![lt.text, lt.timestamp as i64, lt.source_name, lt.source_bundle_id],
                )
            }
            LegacyEntry::Image(li) => {
                tx.execute(
                    "INSERT INTO clipboard_history (entry_type, png_data, width, height, thumb_data, thumb_width, thumb_height, hash, timestamp, source_name, source_bundle_id)
                     VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    rusqlite::params![
                        li.png_data, li.width as i64, li.height as i64,
                        li.thumb_data, li.thumb_width as i64, li.thumb_height as i64,
                        li.hash as i64, li.timestamp as i64,
                        li.source_name, li.source_bundle_id,
                    ],
                )
            }
        };
        if let Err(e) = result {
            eprintln!("CopyAttach: migration insert error: {}", e);
            return;
        }
    }
    if let Err(e) = tx.commit() {
        eprintln!("CopyAttach: failed to commit migration: {}", e);
        return;
    }

    // Mark JSON as migrated
    let _ = std::fs::rename(&json_path, dir.join("history.json.migrated"));
    let _ = std::fs::remove_file(dir.join("history.json.tmp"));
}

#[cfg(not(feature = "migration"))]
fn migrate_from_json_to_db(_conn: &mut Connection) {}

// ═══════════════════════════════════════════
// macOS: Paste Simulation & Permission Check
// ═══════════════════════════════════════════

#[cfg(target_os = "macos")]
mod mac {
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

    pub fn check_permission() -> bool {
        let result = unsafe { AXIsProcessTrusted() };
        result != 0
    }

    pub fn open_preferences() {
        let _ = Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn();
    }

    /// Lightweight check: returns the pasteboard change count without
    /// reading or converting any image data. Returns None if pasteboard
    /// is inaccessible (should not happen on a functional macOS system).
    pub fn pasteboard_change_count() -> Option<i64> {
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

    /// Returns true if Cmd+V was successfully simulated, false if CGEvent
    /// creation failed (e.g., accessibility permissions revoked).
    pub fn simulate_cmd_v() -> bool {
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
}

#[cfg(not(target_os = "macos"))]
mod mac {
    pub fn check_permission() -> bool { true }
    pub fn open_preferences() {}
    pub fn simulate_cmd_v() -> bool {
        eprintln!("Warning: paste simulation only supported on macOS");
        false
    }
    pub fn pasteboard_change_count() -> Option<i64> { None }
}

// ═══════════════════════════════════════════
// Clipboard Monitor (background thread)
// ═══════════════════════════════════════════

fn clipboard_monitor(
    history: Arc<Mutex<Vec<ClipboardEntry>>>,
    running: Arc<AtomicBool>,
    source_app: Arc<Mutex<SourceApp>>,
    db: Arc<Mutex<Connection>>,
    last_seen_text: Arc<Mutex<Option<String>>>,
    last_seen_image_hash: Arc<Mutex<Option<u64>>>,
) {
    let mut cb = match Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("clipboard-monitor: failed to open clipboard: {e}");
            return;
        }
    };

    // Track NSPasteboard changeCount to avoid expensive image reads
    // when the clipboard has not actually changed.
    let mut last_change_count: Option<i64> = None;

    while running.load(Ordering::SeqCst) {
        // Lightweight check: skip all pasteboard reads if changeCount matches.
        match (mac::pasteboard_change_count(), last_change_count) {
            (Some(cc), Some(last)) if cc == last => {
                // Clipboard unchanged — sleep and retry.
                for _ in 0..10 {
                    if !running.load(Ordering::SeqCst) { return; }
                    thread::sleep(Duration::from_millis(POLL_INTERVAL_MS / 10));
                }
                continue;
            }
            (Some(cc), _) => last_change_count = Some(cc),
            _ => {} // can't check changeCount, proceed normally
        }

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
            let is_new = {
                let last = last_seen_image_hash.lock().unwrap();
                match *last {
                    Some(h) => h != hash,
                    None => true,
                }
            };

            if is_new && img_data.width > 0 && img_data.height > 0 {
                if let Some(png_data) = encode_png(
                    img_data.width as u32, img_data.height as u32, &img_data.bytes,
                ) {
                    let thumb = create_thumbnail(
                        img_data.width as u32, img_data.height as u32, &img_data.bytes, 300,
                    );
                    let (thumb_data, thumb_w, thumb_h) = match thumb {
                        Some(t) => t,
                        None => {
                            eprintln!("CopyAttach: thumbnail creation failed for image {}x{}",
                                      img_data.width, img_data.height);
                            (Vec::new(), 0, 0)
                        }
                    };

                    let item = ClipboardEntry::Image {
                        png_data: Vec::new(),
                        width: img_data.width as u32,
                        height: img_data.height as u32,
                        thumb_data: Vec::new(),
                        thumb_width: thumb_w,
                        thumb_height: thumb_h,
                        hash,
                        timestamp: now,
                        source_name: src.name,
                        source_bundle_id: src.bundle_id,
                        db_id: 0,
                    };

                    let mut hist = history.lock().unwrap();
                    *hist = add_to_history(std::mem::take(&mut *hist), item);
                    while hist.len() > CLEANUP_THRESHOLD {
                        hist.pop();
                    }

                    // Write-through to DB — png_data stays as local, never cloned, never enters Vec
                    if let Ok(conn) = db.lock() {
                        insert_entry_to_db(&conn, &hist[0], Some(&png_data), Some((&thumb_data, thumb_w, thumb_h)));
                        delete_matching_entry(&conn, &hist[0]);
                        let row_id = conn.last_insert_rowid();
                        trim_db_history(&conn);
                        if let Some(ClipboardEntry::Image { db_id, .. }) = hist.get_mut(0) {
                            *db_id = row_id;
                        }
                    }
                }
                *last_seen_image_hash.lock().unwrap() = Some(hash);
                *last_seen_text.lock().unwrap() = None;
            } else if is_new {
                *last_seen_image_hash.lock().unwrap() = Some(hash);
                *last_seen_text.lock().unwrap() = None;
            }
        } else {
            // No image, try text
            if let Ok(text) = cb.get_text() {
                let is_new = {
                    let last = last_seen_text.lock().unwrap();
                    match &*last {
                        Some(last) => &text != last,
                        None => !text.is_empty(),
                    }
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
                        *hist = add_to_history(std::mem::take(&mut *hist), item);
                        while hist.len() > CLEANUP_THRESHOLD {
                            hist.pop();
                        }

                        // Write-through to DB
                        if let Ok(conn) = db.lock() {
                            insert_entry_to_db(&conn, &hist[0], None, None);
                            delete_matching_entry(&conn, &hist[0]);
                            trim_db_history(&conn);
                        }
                    }
                    *last_seen_text.lock().unwrap() = Some(text);
                    *last_seen_image_hash.lock().unwrap() = None;
                }
            }
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
    // Open database
    let mut conn = match open_db() {
        Some(c) => c,
        None => {
            eprintln!("CopyAttach: failed to open database, init failed");
            return 0;
        }
    };

    // Ensure schema exists
    if let Err(e) = ensure_history_table(&conn) {
        eprintln!("CopyAttach: failed to create table: {}", e);
        return 0;
    }

    // Migrate from legacy JSON if present
    migrate_from_json_to_db(&mut conn);

    // Trim DB to threshold on startup
    trim_db_history(&conn);

    // Load persisted history from DB
    let saved = load_history_from_db(&conn);
    let saved: Vec<ClipboardEntry> = saved.into_iter().take(CLEANUP_THRESHOLD).collect();

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(SourceApp::default()));
    let last_seen_text: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_seen_image_hash: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
    let db = Arc::new(Mutex::new(conn));

    let backend = Backend {
        history: Arc::clone(&history),
        running: Arc::clone(&running),
        monitor_handle: Mutex::new(None),
        source_app: Arc::clone(&source_app),
        last_seen_text: Arc::clone(&last_seen_text),
        last_seen_image_hash: Arc::clone(&last_seen_image_hash),
        db: Arc::clone(&db),
    };

    let prev = BACKEND.set(backend);
    match prev {
        Err(_) => return 0, // Already initialized
        Ok(()) => {}
    }

    // Spawn the monitor thread after BACKEND is live.
    let handle = thread::spawn(|| clipboard_monitor(
        history, running, source_app, db,
        last_seen_text, last_seen_image_hash,
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
        // Signal the monitor thread to stop — its current iteration's
        // write-through will complete before the thread exits.
        b.running.store(false, Ordering::SeqCst);

        // Wait for the monitor to finish (write-through already in sync).
        if let Ok(mut handle) = b.monitor_handle.lock() {
            if let Some(h) = handle.take() {
                let _ = h.join();
            }
        }
        // No final save needed — write-through guarantees DB is in sync.
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
    // Read db_id under history lock, then load thumb from SQLite (no history lock held)
    let db_id = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize) {
            Some(ClipboardEntry::Image { db_id, .. }) => *db_id,
            _ => return std::ptr::null_mut(),
        }
    };

    if db_id == 0 {
        return std::ptr::null_mut();
    }

    let thumb_data = match backend().db.lock() {
        Ok(conn) => {
            match conn.query_row(
                "SELECT thumb_data FROM clipboard_history WHERE id = ?",
                rusqlite::params![db_id],
                |row| row.get::<_, Vec<u8>>(0),
            ) {
                Ok(data) => data,
                Err(e) => {
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={}: {}", db_id, e);
                    return std::ptr::null_mut();
                }
            }
        }
        Err(_) => return std::ptr::null_mut(),
    };

    let len = thumb_data.len() as c_int;
    if out_len.is_null() { return std::ptr::null_mut(); }
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

#[no_mangle]
pub extern "C" fn clipboard_get_image_full(index: c_int, out_len: *mut c_int) -> *mut u8 {
    if out_len.is_null() { return std::ptr::null_mut(); }

    // Read db_id and cached png_data under a single history lock
    let (png_data, db_id) = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize) {
            Some(ClipboardEntry::Image { png_data, db_id, .. }) => {
                (png_data.clone(), *db_id)
            }
            _ => return std::ptr::null_mut(),
        }
    };

    let data = if !png_data.is_empty() {
        png_data
    } else if db_id != 0 {
        // Load full image from DB on demand
        match backend().db.lock() {
            Ok(conn) => {
                match conn.query_row(
                    "SELECT png_data FROM clipboard_history WHERE id = ?",
                    rusqlite::params![db_id],
                    |row| row.get(0),
                ) {
                    Ok(data) => data,
                    Err(e) => {
                        eprintln!("CopyAttach: failed to load full image for db_id={}: {}", db_id, e);
                        return std::ptr::null_mut();
                    }
                }
            }
            Err(_) => return std::ptr::null_mut(),
        }
    } else {
        return std::ptr::null_mut();
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
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

    // Build a copy with full png_data and thumb_data loaded from DB in one query.
    // The in-memory entry keeps only metadata (png_data and thumb_data stay empty).
    let db_item = match &item {
        ClipboardEntry::Image { db_id, .. } if *db_id != 0 => {
            let mut loaded = item.clone();
            if let ClipboardEntry::Image { ref mut png_data, ref mut thumb_data, ref mut thumb_width, ref mut thumb_height, .. } = loaded {
                if let Ok(conn) = backend().db.lock() {
                    if let Ok((png, thumb, tw, th)) = conn.query_row(
                        "SELECT png_data, thumb_data, thumb_width, thumb_height FROM clipboard_history WHERE id = ?",
                        rusqlite::params![*db_id],
                        |row| Ok((
                            row.get::<_, Vec<u8>>(0)?,
                            row.get::<_, Vec<u8>>(1)?,
                            row.get::<_, i64>(2)?,
                            row.get::<_, i64>(3)?,
                        )),
                    ) {
                        *png_data = png;
                        *thumb_data = thumb;
                        *thumb_width = tw as u32;
                        *thumb_height = th as u32;
                    }
                }
            }
            loaded
        }
        _ => item.clone(),
    };

    // Paste from db_item's loaded data (or item's text for text entries).
    let mut cb = match Clipboard::new() { Ok(c) => c, Err(_) => return 0 };

    match &db_item {
        ClipboardEntry::Text { text, .. } => {
            if cb.set_text(text).is_err() { return 0; }
            let b = backend();
            *b.last_seen_text.lock().unwrap() = Some(text.clone());
            *b.last_seen_image_hash.lock().unwrap() = None;
        }
        ClipboardEntry::Image { png_data, width, height, hash, .. } => {
            if png_data.is_empty() { return 0; }
            if let Some((rgba, _, _)) = decode_png(png_data) {
                let img = arboard::ImageData {
                    width: *width as usize,
                    height: *height as usize,
                    bytes: rgba.into(),
                };
                if cb.set_image(img).is_err() { return 0; }
                let b = backend();
                *b.last_seen_text.lock().unwrap() = None;
                *b.last_seen_image_hash.lock().unwrap() = Some(*hash);
            } else { return 0; }
        }
    }

    // Move the selected item to top of history immediately so the UI
    // reflects the new order right away, without waiting for the monitor thread.
    {
        let mut hist = backend().history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), item);
        while hist.len() > CLEANUP_THRESHOLD {
            hist.pop();
        }
    }

    // Write-through to DB: delete old row and insert new (gets higher id, = top)
    if let Some(b) = BACKEND.get() {
        if let Ok(conn) = b.db.lock() {
            let png_for_insert = match &db_item {
                ClipboardEntry::Image { png_data, .. } if !png_data.is_empty() => {
                    Some(png_data.as_slice())
                }
                _ => None,
            };
            let thumb_for_insert = match &db_item {
                ClipboardEntry::Image { thumb_data, thumb_width, thumb_height, .. } if !thumb_data.is_empty() => {
                    Some((thumb_data.as_slice(), *thumb_width, *thumb_height))
                }
                _ => None,
            };
            delete_matching_entry(&conn, &db_item);
            insert_entry_to_db(&conn, &db_item, png_for_insert, thumb_for_insert);
            trim_db_history(&conn);
        }
    }

    thread::sleep(Duration::from_millis(50));
    #[cfg(target_os = "macos")]
    { if mac::check_permission() && !mac::simulate_cmd_v() { return 0; } }
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
        // Clear DB
        if let Ok(conn) = b.db.lock() {
            if let Err(e) = conn.execute("DELETE FROM clipboard_history", []) {
                eprintln!("CopyAttach: failed to clear DB history: {}", e);
            }
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
            db_id: 0,
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
