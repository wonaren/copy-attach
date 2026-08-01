//! C FFI exports — the interface between the Rust backend and the Swift frontend.
//!
//! All `#[no_mangle] pub extern "C"` functions live here. They are thin wrappers
//! that lock the backend, perform the requested operation, and return results
//! to the caller. Memory ownership follows the `*_free_string` / `*_free_bytes`
//! contract documented on each group of functions.

use std::ffi::{c_char, c_int, c_longlong, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicUsize, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use arboard::Clipboard;

use crate::backend::{backend, set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD};
use crate::types::ClipboardEntry;
use crate::ignore::IgnoreRules;
use crate::image::{decode_png, image_hash};
use crate::history::add_to_history;
use crate::db::{open_db, ensure_history_table, load_history_from_db,
                insert_entry_to_db, delete_matching_entry, trim_db_history,
                migrate_from_json_to_db};
use crate::monitor::clipboard_monitor;
use crate::{macos};

// ═══════════════════════════════════════════
// Snapshot API
// ═══════════════════════════════════════════

/// Opaque handle to a cloned snapshot of clipboard history, taken under a
/// single history lock. All reads from this snapshot are race-free — the
/// background monitor thread cannot modify it.
pub struct Snapshot(Vec<ClipboardEntry>);

/// Acquire a consistent snapshot of all history entries under one lock.
/// Returns an opaque handle (or null if the backend is uninitialized).
/// Caller must release with `clipboard_snapshot_release()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_acquire() -> *mut Snapshot {
    let hist = match crate::backend::try_backend() {
        Some(b) => b.history.lock().unwrap(),
        None => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(Snapshot(hist.clone())))
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_count(snap: *const Snapshot) -> c_int {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.len() as c_int
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_type(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() { return -1; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(-1, super::types::ClipboardEntry::content_type)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Text { id, .. }) => *id as i64,
        Some(ClipboardEntry::Image { id, .. }) => *id as i64,
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_timestamp(snap: *const Snapshot, index: c_int) -> c_longlong {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |item| item.timestamp() as c_longlong)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_label(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(item) => to_ffi_cstring(&item.label()),
        None => std::ptr::null_mut(),
    }
}

/// Get text content (text items only). Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_text(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Text { text, .. }) => to_ffi_cstring(text.as_str()),
        _ => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_name(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(item) => to_ffi_cstring(item.source_name()),
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_bundle_id(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(item) => to_ffi_cstring(item.source_bundle_id()),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_db_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Image { db_id, .. }) => *db_id,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_width(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Image { width, .. }) => *width as c_int,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_height(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Image { height, .. }) => *height as c_int,
        _ => 0,
    }
}

/// Safe to call with null pointer (no-op).
#[no_mangle]
pub extern "C" fn clipboard_snapshot_release(snap: *mut Snapshot) {
    if snap.is_null() { return; }
    unsafe { drop(Box::from_raw(snap)); }
}

// ═══════════════════════════════════════════
// Init / Cleanup
// ═══════════════════════════════════════════

/// Set only after Swift has cryptographically verified a device-bound lease.
/// Invalid values are rejected instead of being treated as licensed.
#[no_mangle]
pub extern "C" fn clipboard_set_runtime_entitlement(state: c_int) -> c_int {
    if !(0..=2).contains(&state) { return 0; }
    crate::backend::RUNTIME_ENTITLEMENT.store(state as usize, Ordering::SeqCst);
    if state == 0 {
        if let Some(b) = crate::backend::try_backend() {
            b.running.store(false, Ordering::SeqCst);
        }
    }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_init() -> c_int {
    if crate::backend::RUNTIME_ENTITLEMENT.load(Ordering::SeqCst) == 0 {
        eprintln!("CopyAttach: clipboard_init rejected: runtime entitlement is denied");
        return 0;
    }
    // OnceLock intentionally retains the backend for process lifetime. A
    // license transition may stop and later re-enable monitoring, so resume
    // the existing backend instead of attempting to replace the singleton.
    if let Some(b) = crate::backend::try_backend() {
        if b.running.swap(true, Ordering::SeqCst) {
            return 1;
        }
        let handle = thread::spawn({
            let history = Arc::clone(&b.history);
            let running = Arc::clone(&b.running);
            let source_app = Arc::clone(&b.source_app);
            let db = Arc::clone(&b.db);
            let last_seen_text = Arc::clone(&b.last_seen_text);
            let last_seen_image_hash = Arc::clone(&b.last_seen_image_hash);
            let pasteboard_event_lock = Arc::clone(&b.pasteboard_event_lock);
            let pending_self_write = Arc::clone(&b.pending_self_write);
            let cleanup_threshold = Arc::clone(&b.cleanup_threshold);
            let ignore_rules = Arc::clone(&b.ignore_rules);
            move || clipboard_monitor(history, running, source_app, db, last_seen_text,
                last_seen_image_hash, pasteboard_event_lock, pending_self_write,
                cleanup_threshold, ignore_rules)
        });
        *b.monitor_handle.lock().unwrap() = Some(handle);
        return 1;
    }

    let mut conn = if let Some(c) = open_db() { c } else {
        eprintln!("CopyAttach: failed to open database, init failed");
        return 0;
    };

    if let Err(e) = ensure_history_table(&conn) {
        eprintln!("CopyAttach: failed to create table: {e}");
        return 0;
    }

    migrate_from_json_to_db(&mut conn);

    // First determine the load limit; then load, THEN trim — otherwise the
    // trim below the load limit discards entries before we can read them.
    #[cfg(feature = "stress-test")]
    const INIT_LOAD: usize = 10000;
    #[cfg(not(feature = "stress-test"))]
    const INIT_LOAD: usize = DEFAULT_CLEANUP_THRESHOLD;

    let saved = load_history_from_db(&conn, INIT_LOAD);
    let saved: Vec<ClipboardEntry> = saved.into_iter().take(INIT_LOAD).collect();
    trim_db_history(&conn, INIT_LOAD);

    // Prime the entry-id counter above the highest loaded ID so new entries
    // never collide with restored ones. This is safe even when loaded IDs are
    // a sparse set from the backfill (SQLite rowids can have gaps from
    // deletion): the AtomicU64 is monotonic and always moves forward.
    {
        let max_id = saved.iter().map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        }).max().unwrap_or(0);
        crate::backend::prime_entry_id(max_id + 1);
    }

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(crate::types::SourceApp::default()));
    let last_seen_text: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_seen_image_hash: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
    let pasteboard_event_lock = Arc::new(Mutex::new(()));
    let pending_self_write = Arc::new(Mutex::new(None));
    let db = Arc::new(Mutex::new(conn));
    let cleanup_threshold = Arc::new(AtomicUsize::new(DEFAULT_CLEANUP_THRESHOLD));
    let ignore_rules = Arc::new(Mutex::new(IgnoreRules::default()));
    let deleted_stack: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(Vec::new()));
    let last_restored_id = Arc::new(AtomicU64::new(0));
    let image_paste_use_ctrl_v = Arc::new(AtomicBool::new(false));

    let backend = Backend {
        history: Arc::clone(&history),
        running: Arc::clone(&running),
        monitor_handle: Mutex::new(None),
        source_app: Arc::clone(&source_app),
        last_seen_text: Arc::clone(&last_seen_text),
        last_seen_image_hash: Arc::clone(&last_seen_image_hash),
        pasteboard_event_lock: Arc::clone(&pasteboard_event_lock),
        pending_self_write: Arc::clone(&pending_self_write),
        db: Arc::clone(&db),
        cleanup_threshold: Arc::clone(&cleanup_threshold),
        ignore_rules: Arc::clone(&ignore_rules),
        deleted_stack: Arc::clone(&deleted_stack),
        last_restored_id: Arc::clone(&last_restored_id),
        image_paste_use_ctrl_v: Arc::clone(&image_paste_use_ctrl_v),
    };

    if set_backend(backend).is_err() {
        return 0; // Already initialized
    }

    // Establish clipboard baseline: read current system clipboard content and
    // initialize last_seen_* accordingly.
    if let Ok(mut tmp_cb) = Clipboard::new() {
        if let Ok(img) = tmp_cb.get_image() {
            let hash = image_hash(&img.bytes, img.width as u32, img.height as u32);
            *last_seen_image_hash.lock().unwrap() = Some(hash);
            *last_seen_text.lock().unwrap() = None;
        } else if let Ok(text) = tmp_cb.get_text() {
            if !text.is_empty() {
                *last_seen_text.lock().unwrap() = Some(text);
                *last_seen_image_hash.lock().unwrap() = None;
            }
        } else {
            eprintln!("CopyAttach: clipboard baseline read failed (empty pasteboard or unsupported content)");
        }
    } else {
        eprintln!("CopyAttach: failed to open clipboard for baseline read");
    }

    let handle = thread::spawn(|| clipboard_monitor(
        history, running, source_app, db,
        last_seen_text, last_seen_image_hash, pasteboard_event_lock, pending_self_write,
        cleanup_threshold, ignore_rules,
    ));

    if let Some(b) = crate::backend::try_backend() {
        if let Ok(mut h) = b.monitor_handle.lock() {
            *h = Some(handle);
        }
    }

    1
}

#[no_mangle]
pub extern "C" fn clipboard_cleanup() {
    if let Some(b) = crate::backend::try_backend() {
        b.running.store(false, Ordering::SeqCst);
        if let Ok(mut handle) = b.monitor_handle.lock() {
            if let Some(h) = handle.take() {
                let _ = h.join();
            }
        }
    }
}

// ═══════════════════════════════════════════
// Source App
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_set_source_app(name: *const c_char, bundle_id: *const c_char, pid: i32) {
    let name = if name.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned()
    };
    let bundle_id = if bundle_id.is_null() { String::new() } else {
        unsafe { CStr::from_ptr(bundle_id) }.to_string_lossy().into_owned()
    };
    if let Some(b) = crate::backend::try_backend() {
        let mut src = b.source_app.lock().unwrap();
        src.name = name;
        src.bundle_id = bundle_id;
        src.pid = pid;
    }
}

// ═══════════════════════════════════════════
// Capture Ignore Rules
// ═══════════════════════════════════════════

/// Replaces the configured rules atomically with respect to capture. Strings
/// are copied only when the user commits a settings change, never per poll.
#[no_mangle]
pub extern "C" fn clipboard_set_ignore_rules(
    app_bundle_ids: *const c_char,
    ignore_text: c_int,
    ignore_images: c_int,
    min_text_characters: c_int,
) -> c_int {
    if app_bundle_ids.is_null() || min_text_characters < 0 {
        return 0;
    }
    let encoded = match unsafe { CStr::from_ptr(app_bundle_ids) }.to_str() {
        Ok(value) => value,
        Err(_) => return 0,
    };
    let rules = IgnoreRules::from_encoded(
        encoded,
        ignore_text != 0,
        ignore_images != 0,
        match min_text_characters {
            0 => None,
            value => Some(value as usize),
        },
    );
    match crate::backend::try_backend() {
        Some(backend) => {
            *backend.ignore_rules.lock().unwrap() = rules;
            1
        }
        None => 0,
    }
}

// ═══════════════════════════════════════════
// Legacy Index-Based Accessors
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_count() -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.len() as c_int
}

/// Returns a monotonically increasing counter that increments each time a
/// Phase 2 image encoding finishes and updates `db_id` in memory. Swift uses
/// this to detect thumbnail-ready items without a change in entry count.
#[no_mangle]
pub extern "C" fn clipboard_get_image_encoding_counter() -> u64 {
    crate::backend::IMAGE_ENCODING_COUNTER.load(Ordering::Relaxed)
}

/// Monotonic revision of in-memory history ordering and metadata.
#[no_mangle]
pub extern "C" fn clipboard_get_history_revision() -> u64 {
    crate::backend::HISTORY_REVISION.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_type(index: c_int) -> c_int {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(-1, super::types::ClipboardEntry::content_type)
}

#[no_mangle]
pub extern "C" fn clipboard_get_item_timestamp(index: c_int) -> c_longlong {
    let hist = backend().history.lock().unwrap();
    hist.get(index as usize).map_or(0, |item| item.timestamp() as c_longlong)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_name(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let name = match hist.get(index as usize) {
        Some(item) => item.source_name(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(name)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_bundle_id(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let bid = match hist.get(index as usize) {
        Some(item) => item.source_bundle_id(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(bid)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_label(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let label = match hist.get(index as usize) {
        Some(item) => item.label(),
        None => return std::ptr::null_mut(),
    };
    to_ffi_cstring(&label)
}

/// Get text content. Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_text(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    match hist.get(index as usize) {
        Some(ClipboardEntry::Text { text, .. }) => {
            to_ffi_cstring(text.as_str())
        }
        _ => std::ptr::null_mut(),
    }
}

// ═══════════════════════════════════════════
// Image Loading (Index-Based)
// ═══════════════════════════════════════════

fn vec_to_raw(v: Vec<u8>) -> *mut u8 {
    let mut v = v;
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    ptr
}

/// Convert a Rust string to a `CString` for FFI return. If the string contains
/// an interior null byte, truncate at the first null and log a warning instead
/// of silently returning an empty string.
fn to_ffi_cstring(s: &str) -> *mut c_char {
    if let Ok(cs) = CString::new(s) { cs.into_raw() } else {
        let null_pos = s.find('\0').unwrap_or(s.len());
        eprintln!("CopyAttach: FFI string contains interior null byte at offset {} (len={}), truncating",
                  null_pos, s.len());
        let truncated: String = s.chars().take_while(|&c| c != '\0').collect();
        CString::new(truncated).unwrap_or_default().into_raw()
    }
}

/// Load thumbnail by array index. Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_thumb(index: c_int, out_len: *mut c_int) -> *mut u8 {
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
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = thumb_data.len() as c_int;
    if out_len.is_null() { return std::ptr::null_mut(); }
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

/// Load full image by array index. Checks in-memory cache first, then `SQLite`.
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_full(index: c_int, out_len: *mut c_int) -> *mut u8 {
    if out_len.is_null() { return std::ptr::null_mut(); }

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
        match backend().db.lock() {
            Ok(conn) => {
                match conn.query_row(
                    "SELECT png_data FROM clipboard_history WHERE id = ?",
                    rusqlite::params![db_id],
                    |row| row.get(0),
                ) {
                    Ok(data) => data,
                    Err(e) => {
                        eprintln!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                        return std::ptr::null_mut();
                    }
                }
            }
            Err(e) => {
                eprintln!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
                return std::ptr::null_mut();
            }
        }
    } else {
        return std::ptr::null_mut();
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

/// Load full image directly by database row id.
/// Checks in-memory cache first (history entry with matching `db_id`),
/// falls back to `SQLite` load. Does NOT hold the history lock except
/// for the brief cache check.
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_full_by_db_id(db_id: i64, out_len: *mut c_int) -> *mut u8 {
    if db_id == 0 || out_len.is_null() {
        return std::ptr::null_mut();
    }

    let cached = {
        let hist = backend().history.lock().unwrap();
        hist.iter().find_map(|entry| {
            match entry {
                ClipboardEntry::Image { db_id: id, png_data, .. } if *id == db_id && !png_data.is_empty() => {
                    Some(png_data.clone())
                }
                _ => None,
            }
        })
    };

    let data = match cached {
        Some(d) => d,
        None => {
            match backend().db.lock() {
                Ok(conn) => {
                    match conn.query_row(
                        "SELECT png_data FROM clipboard_history WHERE id = ?",
                        rusqlite::params![db_id],
                        |row| row.get(0),
                    ) {
                        Ok(data) => data,
                        Err(e) => {
                            eprintln!("CopyAttach: failed to load full image for db_id={db_id}: {e}");
                            return std::ptr::null_mut();
                        }
                    }
                }
                Err(e) => {
                    eprintln!("CopyAttach: DB mutex poisoned loading full image for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
    };

    let len = data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(data)
}

/// Load thumbnail directly by database row id. Does NOT touch the history lock.
/// Caller must free with `clipboard_free_bytes()`.
#[no_mangle]
pub extern "C" fn clipboard_get_image_thumb_by_db_id(db_id: i64, out_len: *mut c_int) -> *mut u8 {
    if db_id == 0 || out_len.is_null() {
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
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={db_id}: {e}");
                    return std::ptr::null_mut();
                }
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned loading thumbnail for db_id={db_id}: {e}");
            return std::ptr::null_mut();
        }
    };

    let len = thumb_data.len() as c_int;
    unsafe { *out_len = len; }
    vec_to_raw(thumb_data)
}

// ═══════════════════════════════════════════
// Image Size
// ═══════════════════════════════════════════

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

// ═══════════════════════════════════════════
// Memory Management Helpers
// ═══════════════════════════════════════════

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

// ═══════════════════════════════════════════
// Select & Paste
// ═══════════════════════════════════════════

/// Known terminal emulator bundle IDs. When the user enables Ctrl+V for image
/// paste, it only activates when the frontmost app matches one of these.
const TERMINAL_BUNDLE_IDS: &[&str] = &[
    "com.mitchellh.ghostty",      // Ghostty
    "com.googlecode.iterm2",      // iTerm2
    "net.kovidgoyal.kitty",       // Kitty
    "com.apple.Terminal",         // Terminal.app
    "dev.warp.Warp-Stable",       // Warp
    "org.alacritty",              // Alacritty
    "co.zeit.hyper",              // Hyper
    "com.github.wez.wezterm",     // WezTerm
];

fn is_terminal_app(bundle_id: &str) -> bool {
    if bundle_id.is_empty() {
        return false;
    }
    TERMINAL_BUNDLE_IDS.contains(&bundle_id)
}

/// Shared implementation for select-and-paste.
/// Loads full image data from DB if needed, writes to system clipboard,
/// write-through DB, moves item to top of history, then simulates paste.
fn select_and_paste_impl(mut item: ClipboardEntry) -> c_int {
    // The entry is moved to the top of history below. Stamp it with the current
    // time so the list order (most-recently-used) stays consistent with the
    // entry's timestamp — the day separator groups rely on this invariant.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    match &mut item {
        ClipboardEntry::Text { ref mut timestamp, .. }
        | ClipboardEntry::Image { ref mut timestamp, .. } => {
            *timestamp = now;
        }
    }

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

    let mut cb = match Clipboard::new() { Ok(c) => c, Err(_) => return 0 };

    // The monitor consumes pasteboard events under this same lock. Register
    // the resulting changeCount before it can observe our write.
    let b = backend();
    let _event_guard = b.pasteboard_event_lock.lock().unwrap();
    match &db_item {
        ClipboardEntry::Text { text, .. } => {
            if cb.set_text(text).is_err() { return 0; }
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
                *b.last_seen_text.lock().unwrap() = None;
                *b.last_seen_image_hash.lock().unwrap() = Some(*hash);
            } else { return 0; }
        }
    }
    let change_count = macos::pasteboard_change_count()
        .expect("CopyAttach: cannot identify self-written pasteboard change");
    *b.pending_self_write.lock().unwrap() = Some(
        crate::backend::PendingSelfWrite { change_count },
    );
    drop(_event_guard);

    if let Some(b) = crate::backend::try_backend() {
        match b.db.lock() {
            Ok(conn) => {
                let png_for_db = match &db_item {
                    ClipboardEntry::Image { png_data, .. } if !png_data.is_empty() => {
                        Some(png_data.as_slice())
                    }
                    _ => None,
                };
                let thumb_for_db = match &db_item {
                    ClipboardEntry::Image { thumb_data, thumb_width, thumb_height, .. } if !thumb_data.is_empty() => {
                        Some((thumb_data.as_slice(), *thumb_width, *thumb_height))
                    }
                    _ => None,
                };

                if insert_entry_to_db(&conn, &db_item, png_for_db, thumb_for_db).is_ok() {
                    delete_matching_entry(&conn, &db_item);
                    let new_row_id = conn.last_insert_rowid();
                    trim_db_history(&conn, b.cleanup_threshold.load(Ordering::Relaxed));

                    match &mut item {
                        ClipboardEntry::Image { ref mut db_id, .. } |
                        ClipboardEntry::Text { ref mut db_id, .. } => {
                            *db_id = new_row_id;
                        }
                    }
                } else {
                    eprintln!("CopyAttach: select_and_paste DB insert failed — entry stays with db_id=0");
                }
            }
            Err(e) => {
                eprintln!("CopyAttach: DB mutex poisoned in select_and_paste persist: {e} — entry stays with db_id=0");
            }
        }
    }

    {
        let b = backend();
        let mut hist = b.history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), item);
        while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
            hist.pop();
        }
        crate::backend::mark_history_changed();
    }

    let front_pid = crate::backend::try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .map_or(0, |src| src.pid);

    let is_image = matches!(db_item, ClipboardEntry::Image { .. });
    let is_terminal = crate::backend::try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .is_some_and(|src| is_terminal_app(&src.bundle_id));
    let use_ctrl = is_image
        && is_terminal
        && b.image_paste_use_ctrl_v.load(Ordering::Relaxed);

    thread::sleep(Duration::from_millis(50));
    #[cfg(target_os = "macos")]
    {
        if macos::check_permission() {
            if !macos::simulate_paste_v(front_pid, use_ctrl) {
                eprintln!("CopyAttach: simulate_paste_v failed");
                return 0;
            }
        } else {
            eprintln!("CopyAttach: accessibility permission not granted — clipboard copied but paste skipped");
        }
    }
    1
}

/// Legacy: select and paste by array index. Prefer `clipboard_select_and_paste_by_id`.
#[no_mangle]
pub extern "C" fn clipboard_select_and_paste(index: c_int) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        match hist.get(index as usize).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    select_and_paste_impl(item)
}

/// Select and paste by stable entry ID (not array index).
#[no_mangle]
pub extern "C" fn clipboard_select_and_paste_by_id(entry_id: u64) -> c_int {
    let item = {
        let hist = backend().history.lock().unwrap();
        match hist.iter().find(|e| match e {
            ClipboardEntry::Text { id, .. } => *id == entry_id,
            ClipboardEntry::Image { id, .. } => *id == entry_id,
        }).cloned() {
            Some(i) => i,
            None => return 0,
        }
    };
    select_and_paste_impl(item)
}

/// Load full text by entry ID (for on-demand preview loading).
/// Returns null if `entry_id` is not found or is not a text entry.
/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_text_by_id(entry_id: u64) -> *mut c_char {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return std::ptr::null_mut(),
    };
    let hist = b.history.lock().unwrap();
    for entry in hist.iter() {
        match entry {
            ClipboardEntry::Text { id, text, .. } if *id == entry_id => {
                return to_ffi_cstring(text.as_str());
            }
            _ => {}
        }
    }
    std::ptr::null_mut()
}

// ═══════════════════════════════════════════
// History Management
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_clear_history() {
    if let Some(b) = crate::backend::try_backend() {
        {
            let mut hist = b.history.lock().unwrap();
            hist.clear();
        }
        if let Ok(conn) = b.db.lock() {
            if let Err(e) = conn.execute("DELETE FROM clipboard_history", []) {
                eprintln!("CopyAttach: failed to clear DB history: {e}");
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_delete_by_id(entry_id: u64) -> c_int {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };

    // Step 1: Find the entry in history and clone it WITHOUT removing yet.
    // If undo data capture fails later, entry stays intact in history.
    let entry = {
        let hist = b.history.lock().unwrap();
        hist.iter().find(|e| match e {
            ClipboardEntry::Text { id, .. } => *id == entry_id,
            ClipboardEntry::Image { id, .. } => *id == entry_id,
        }).cloned()
    };
    let mut entry = match entry {
        Some(e) => e,
        None => return 0,
    };

    // Step 2: For image entries, load full data from DB before removal.
    // If loading fails (Phase 2 not done, DB error), reject deletion entirely.
    if let ClipboardEntry::Image { db_id, png_data, thumb_data, thumb_width, thumb_height, .. } = &mut entry {
        if png_data.is_empty() && *db_id != 0 {
            let conn = b.db.lock().unwrap_or_else(|e| {
                panic!("CopyAttach: DB lock poisoned loading image for undo: {e}");
            });
            let loaded = conn.query_row(
                "SELECT png_data, thumb_data, thumb_width, thumb_height FROM clipboard_history WHERE id = ?",
                rusqlite::params![*db_id],
                |row| Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                )),
            );
            match loaded {
                Ok((png, thumb, tw, th)) => {
                    *png_data = png;
                    *thumb_data = thumb;
                    *thumb_width = tw as u32;
                    *thumb_height = th as u32;
                }
                Err(e) => {
                    eprintln!("CopyAttach: failed to load image data from DB for undo: {e}");
                    return 0;
                }
            }
        } else if png_data.is_empty() && *db_id == 0 {
            // Phase 2 async persist has not completed — no image data exists in DB.
            // Reject deletion: the entry stays in history, user can retry later.
            eprintln!("CopyAttach: cannot delete image entry {entry_id}: Phase 2 not yet complete (db_id=0)");
            return 0;
        }
    }

    // Step 3: Delete from DB first. If this fails, history entry stays intact.
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("CopyAttach: DB lock poisoned deleting entry {entry_id}: {e}");
                return 0;
            }
        };
        if let Err(e) = match &entry {
            ClipboardEntry::Text { db_id, text, .. } => {
                if *db_id != 0 {
                    conn.execute(
                        "DELETE FROM clipboard_history WHERE id = ?1",
                        rusqlite::params![*db_id],
                    )
                } else {
                    // db_id not yet set (e.g. monitor DB write still in
                    // progress). Fall back to content-based deletion so the
                    // row doesn't survive a restart.
                    conn.execute(
                        "DELETE FROM clipboard_history WHERE entry_type = 0 AND text = ?1",
                        rusqlite::params![text],
                    )
                }
            }
            ClipboardEntry::Image { db_id, hash, .. } => {
                if *db_id != 0 {
                    conn.execute(
                        "DELETE FROM clipboard_history WHERE id = ?1",
                        rusqlite::params![*db_id],
                    )
                } else {
                    // db_id not yet set (Phase 2 async persist still in
                    // progress). Fall back to hash-based deletion.
                    conn.execute(
                        "DELETE FROM clipboard_history WHERE entry_type = 1 AND hash = ?1",
                        rusqlite::params![*hash as i64],
                    )
                }
            }
        } {
            eprintln!("CopyAttach: failed to delete entry {entry_id} from DB: {e}");
            return 0;
        }
    }

    // Step 4: DB delete succeeded. Now remove from history.
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| match e {
            ClipboardEntry::Text { id, .. } => *id != entry_id,
            ClipboardEntry::Image { id, .. } => *id != entry_id,
        });
    }

    // Step 5: Push to undo stack with fully captured data.
    {
        let mut stack = b.deleted_stack.lock().unwrap();
        stack.push(entry.clone());
        if stack.len() > 10 {
            stack.remove(0);
        }
    }

    1
}

/// Undo the most recent deletion: restore the entry back into history
/// at the front of the list and re-insert into DB.
/// Returns 1 on success, 0 if there's nothing to undo.
#[no_mangle]
pub extern "C" fn clipboard_undo_delete() -> c_int {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let entry = {
        let mut stack = b.deleted_stack.lock().unwrap();
        match stack.pop() {
            Some(e) => e,
            None => return 0,
        }
    };

    // The restored entry goes to the top of history. Stamp it with the current
    // time before the DB write so the stored row and the in-memory entry agree —
    // the day separator groups rely on list order matching the timestamp.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut entry = entry;
    match &mut entry {
        ClipboardEntry::Text { ref mut timestamp, .. }
        | ClipboardEntry::Image { ref mut timestamp, .. } => {
            *timestamp = now;
        }
    }

    // DB lock failure is fatal — entry has already been popped from the stack.
    // Panic so the crash report reveals the poisoning rather than silently losing data.
    let conn = b.db.lock().unwrap_or_else(|e| {
        panic!("CopyAttach: DB lock poisoned during undo: {e}");
    });
    let png_for_db = match &entry {
        ClipboardEntry::Image { png_data, .. } if !png_data.is_empty() => {
            Some(png_data.as_slice())
        }
        _ => None,
    };
    let thumb_for_db = match &entry {
        ClipboardEntry::Image { thumb_data, thumb_width, thumb_height, .. }
            if !thumb_data.is_empty() =>
        {
            Some((thumb_data.as_slice(), *thumb_width, *thumb_height))
        }
        _ => None,
    };

    // Must succeed: without DB write, image entries can't store their data
    // and text entries would lack db_id. Re-push to stack so user can retry.
    if insert_entry_to_db(&conn, &entry, png_for_db, thumb_for_db).is_err() {
        let mut stack = b.deleted_stack.lock().unwrap();
        stack.push(entry);
        return 0;
    }
    let new_row_id = conn.last_insert_rowid();

    match &mut entry {
        ClipboardEntry::Text { ref mut db_id, .. }
        | ClipboardEntry::Image { ref mut db_id, .. } => {
            *db_id = new_row_id;
        }
    }

    let mut hist = b.history.lock().unwrap();
    // Use add_to_history for dedup: if the same content was re-captured
    // by the monitor between deletion and undo, remove the existing copy
    // before inserting the restored one at head.
    let restored_id = entry.entry_id();
    *hist = add_to_history(std::mem::take(&mut *hist), entry);
    while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
        hist.pop();
    }
    drop(hist);

    // Record the restored entry ID so Swift can find it in the snapshot
    // even if the monitor thread inserted new content at position 0.
    b.last_restored_id.store(restored_id, Ordering::SeqCst);

    1
}

/// Returns 1 if there's at least one entry in the undo stack, 0 otherwise.
#[no_mangle]
pub extern "C" fn clipboard_can_undo() -> c_int {
    match crate::backend::try_backend() {
        Some(b) => c_int::from(!b.deleted_stack.lock().unwrap().is_empty()),
        None => 0,
    }
}

/// Returns the `entry_id` of the most recently undo-restored entry, or 0 if none.
/// Used by Swift to locate the restored entry in a snapshot despite monitor
/// thread races inserting new content at position 0.
#[no_mangle]
pub extern "C" fn clipboard_last_restored_id() -> u64 {
    match crate::backend::try_backend() {
        Some(b) => b.last_restored_id.load(Ordering::SeqCst),
        None => 0,
    }
}

/// Trim the oldest N percent of entries from both in-memory history and DB.
/// Returns the number of entries removed.
/// Deletes from DB first, then memory — so a DB failure leaves memory intact.
#[no_mangle]
pub extern "C" fn clipboard_trim_oldest_percent(percent: i32) -> c_int {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let count = {
        let hist = b.history.lock().unwrap();
        let total = hist.len();
        if total == 0 {
            return 0;
        }
        let count = ((total as f64 * f64::from(percent) / 100.0).ceil()) as usize;
        count.min(total)
    };

    // Step 1: Delete oldest entries from DB first.
    // If this fails, we don't touch memory — no consistency gap.
    match b.db.lock() {
        Ok(conn) => {
            if let Err(e) = conn.execute(
                "DELETE FROM clipboard_history WHERE id IN (
                    SELECT id FROM clipboard_history ORDER BY id ASC LIMIT ?)",
                rusqlite::params![count as i64],
            ) {
                eprintln!("CopyAttach: failed to trim DB by {count} entries: {e}");
            }
        }
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned in trim_oldest_percent: {e}");
        }
    }

    // Step 2: Remove from in-memory history.
    let mut hist = b.history.lock().unwrap();
    let actual = count.min(hist.len());
    let split_at = hist.len() - actual;
    let _removed = hist.split_off(split_at);
    // Now also trim to threshold in case percent-trim left us over the cap.
    // (This shouldn't normally happen since percent-based trim is user-initiated,
    //  but keep the invariant that len <= threshold.)
    while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
        hist.pop();
    }

    actual as c_int
}

// ═══════════════════════════════════════════
// Cleanup Threshold
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_cleanup_threshold() -> i32 {
    crate::backend::try_backend()
        .map_or(DEFAULT_CLEANUP_THRESHOLD as i32, |b| b.cleanup_threshold.load(Ordering::Relaxed) as i32)
}

/// Clamped to [100, 10000]. Immediately trims both DB and in-memory history.
#[no_mangle]
pub extern "C" fn clipboard_set_cleanup_threshold(threshold: i32) {
    if let Some(b) = crate::backend::try_backend() {
        let t = threshold.clamp(100, 10000) as usize;
        b.cleanup_threshold.store(t, Ordering::Relaxed);
        {
            let mut hist = b.history.lock().unwrap();
            while hist.len() > t {
                hist.pop();
            }
        }
        if let Ok(conn) = b.db.lock() {
            trim_db_history(&conn, t);
        }
    }
}

// ═══════════════════════════════════════════
// Paste Modifier for Images
// ═══════════════════════════════════════════

/// When `use_ctrl` is non-zero, pasting images uses Ctrl+V instead of Cmd+V.
/// Useful for terminal applications (e.g. Ghostty) where images require Ctrl+V.
#[no_mangle]
pub extern "C" fn clipboard_set_paste_image_with_ctrl_v(use_ctrl: c_int) {
    if let Some(b) = crate::backend::try_backend() {
        b.image_paste_use_ctrl_v.store(use_ctrl != 0, Ordering::Relaxed);
    }
}

// ═══════════════════════════════════════════
// Storage & Permissions
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_storage_size() -> i64 {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("CopyAttach: DB mutex poisoned in get_storage_size: {e}");
            return 0;
        }
    };
    match conn.query_row(
        "SELECT COALESCE(SUM(LENGTH(text)), 0) + COALESCE(SUM(LENGTH(png_data)), 0) + COALESCE(SUM(LENGTH(thumb_data)), 0) FROM clipboard_history",
        [],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(size) => size,
        Err(e) => {
            eprintln!("CopyAttach: failed to query storage size: {e}");
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_check_permission() -> c_int {
    #[cfg(target_os = "macos")]
    { c_int::from(macos::check_permission()) }
    #[cfg(not(target_os = "macos"))]
    { 1 }
}

#[no_mangle]
pub extern "C" fn clipboard_open_preferences() {
    #[cfg(target_os = "macos")]
    macos::open_preferences();
}

/// Reload the in-memory history from the database using the current cleanup
/// threshold.  Useful after changing the threshold or injecting test data.
/// Returns the number of entries loaded.
#[no_mangle]
pub extern "C" fn clipboard_reload_history() -> c_int {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };
    // Verify DB lock is healthy before calling the shared helper.
    if b.db.lock().is_err() {
        return 0;
    }
    crate::backend::reload_history_from_db(b) as c_int
}

// ═══════════════════════════════════════════
// Stress-Test FFI (cfg-gated)
// ═══════════════════════════════════════════

/// Returns 1 if the stress-test feature is compiled in, 0 otherwise.
/// Swift should gate stress-panel access on this to avoid misleading results.
#[no_mangle]
pub extern "C" fn clipboard_stress_available() -> c_int {
    #[cfg(feature = "stress-test")] { 1 }
    #[cfg(not(feature = "stress-test"))] { 0 }
}

/// Inject test data into the running backend.
/// Returns the number of entries actually inserted.
#[cfg(feature = "stress-test")]
#[no_mangle]
pub extern "C" fn clipboard_stress_inject(count: c_int, text_ratio: f64, seed: i64) -> c_int {
    crate::stress::ffi_inject(count, text_ratio, seed)
}

/// Provide a stub when stress-test is not enabled so the Swift bridge
/// doesn't fail to link.  The Swift side should only call these when
/// the debug panel is active.
#[cfg(not(feature = "stress-test"))]
#[no_mangle]
pub extern "C" fn clipboard_stress_inject(_count: c_int, _text_ratio: f64, _seed: i64) -> c_int { 0 }

/// Reset stress-injected data by reloading from DB.
#[cfg(feature = "stress-test")]
#[no_mangle]
pub extern "C" fn clipboard_stress_reset() {
    crate::stress::ffi_reset();
}

#[cfg(not(feature = "stress-test"))]
#[no_mangle]
pub extern "C" fn clipboard_stress_reset() {}

/// Run internal Rust-side benchmarks and return a JSON string.
/// Caller must free with clipboard_free_string().
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
