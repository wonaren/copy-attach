//! C FFI exports — the interface between the Rust backend and the Swift frontend.
//!
//! All `#[no_mangle] pub extern "C"` functions live here. They are thin wrappers
//! that lock the backend, perform the requested operation, and return results
//! to the caller. Memory ownership follows the `*_free_string` / `*_free_bytes`
//! contract documented on each group of functions.

use std::ffi::{c_char, c_int, c_longlong, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use arboard::Clipboard;

use crate::backend::{backend, set_backend, Backend, DEFAULT_CLEANUP_THRESHOLD};
use crate::types::ClipboardEntry;
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
    snap.0.get(index as usize).map_or(-1, |item| item.content_type())
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
        Some(item) => CString::new(item.label()).unwrap_or_default().into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Get text content (text items only). Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_text(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(ClipboardEntry::Text { text, .. }) => CString::new(text.as_str()).unwrap_or_default().into_raw(),
        _ => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_name(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(item) => CString::new(item.source_name()).unwrap_or_default().into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_bundle_id(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(item) => CString::new(item.source_bundle_id()).unwrap_or_default().into_raw(),
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

#[no_mangle]
pub extern "C" fn clipboard_init() -> c_int {
    let mut conn = match open_db() {
        Some(c) => c,
        None => {
            eprintln!("CopyAttach: failed to open database, init failed");
            return 0;
        }
    };

    if let Err(e) = ensure_history_table(&conn) {
        eprintln!("CopyAttach: failed to create table: {}", e);
        return 0;
    }

    migrate_from_json_to_db(&mut conn);

    trim_db_history(&conn, DEFAULT_CLEANUP_THRESHOLD);

    let saved = load_history_from_db(&conn);
    let saved: Vec<ClipboardEntry> = saved.into_iter().take(DEFAULT_CLEANUP_THRESHOLD).collect();

    let history: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(saved));
    let running = Arc::new(AtomicBool::new(true));
    let source_app = Arc::new(Mutex::new(crate::types::SourceApp::default()));
    let last_seen_text: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_seen_image_hash: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
    let db = Arc::new(Mutex::new(conn));
    let cleanup_threshold = Arc::new(AtomicUsize::new(DEFAULT_CLEANUP_THRESHOLD));
    let deleted_stack: Arc<Mutex<Vec<ClipboardEntry>>> = Arc::new(Mutex::new(Vec::new()));

    let backend = Backend {
        history: Arc::clone(&history),
        running: Arc::clone(&running),
        monitor_handle: Mutex::new(None),
        source_app: Arc::clone(&source_app),
        last_seen_text: Arc::clone(&last_seen_text),
        last_seen_image_hash: Arc::clone(&last_seen_image_hash),
        db: Arc::clone(&db),
        cleanup_threshold: Arc::clone(&cleanup_threshold),
        deleted_stack: Arc::clone(&deleted_stack),
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
        last_seen_text, last_seen_image_hash,
        cleanup_threshold,
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
// Legacy Index-Based Accessors
// ═══════════════════════════════════════════

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

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_name(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let name = match hist.get(index as usize) {
        Some(item) => item.source_name(),
        None => return std::ptr::null_mut(),
    };
    CString::new(name).unwrap_or_default().into_raw()
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_source_bundle_id(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let bid = match hist.get(index as usize) {
        Some(item) => item.source_bundle_id(),
        None => return std::ptr::null_mut(),
    };
    CString::new(bid).unwrap_or_default().into_raw()
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_get_item_label(index: c_int) -> *mut c_char {
    let hist = backend().history.lock().unwrap();
    let label = match hist.get(index as usize) {
        Some(item) => item.label(),
        None => return std::ptr::null_mut(),
    };
    CString::new(label).unwrap_or_default().into_raw()
}

/// Get text content. Caller must free with `clipboard_free_string()`.
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

// ═══════════════════════════════════════════
// Image Loading (Index-Based)
// ═══════════════════════════════════════════

fn vec_to_raw(v: Vec<u8>) -> *mut u8 {
    let mut v = v;
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    ptr
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

/// Load full image by array index. Checks in-memory cache first, then SQLite.
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

/// Load full image directly by database row id.
/// Checks in-memory cache first (history entry with matching db_id),
/// falls back to SQLite load. Does NOT hold the history lock except
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
                            eprintln!("CopyAttach: failed to load full image for db_id={}: {}", db_id, e);
                            return std::ptr::null_mut();
                        }
                    }
                }
                Err(_) => return std::ptr::null_mut(),
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
                    eprintln!("CopyAttach: failed to load thumbnail for db_id={}: {}", db_id, e);
                    return std::ptr::null_mut();
                }
            }
        }
        Err(_) => return std::ptr::null_mut(),
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

/// Shared implementation for select-and-paste.
/// Loads full image data from DB if needed, writes to system clipboard,
/// write-through DB, moves item to top of history, then simulates paste.
fn select_and_paste_impl(mut item: ClipboardEntry) -> c_int {
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

    if let Some(b) = crate::backend::try_backend() {
        if let Ok(conn) = b.db.lock() {
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

            insert_entry_to_db(&conn, &db_item, png_for_db, thumb_for_db).ok();
            delete_matching_entry(&conn, &db_item);
            let new_row_id = conn.last_insert_rowid();
            trim_db_history(&conn, b.cleanup_threshold.load(Ordering::Relaxed));

            match &mut item {
                ClipboardEntry::Image { ref mut db_id, .. } |
                ClipboardEntry::Text { ref mut db_id, .. } => {
                    *db_id = new_row_id;
                }
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
    }

    let front_pid = crate::backend::try_backend()
        .and_then(|b| b.source_app.lock().ok())
        .map(|src| src.pid)
        .unwrap_or(0);

    thread::sleep(Duration::from_millis(50));
    #[cfg(target_os = "macos")]
    {
        if macos::check_permission() {
            if !macos::simulate_cmd_v(front_pid) {
                eprintln!("CopyAttach: simulate_cmd_v failed");
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
/// Returns null if entry_id is not found or is not a text entry.
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
                return CString::new(text.as_str()).unwrap_or_default().into_raw();
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
                eprintln!("CopyAttach: failed to clear DB history: {}", e);
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
                panic!("CopyAttach: DB lock poisoned loading image for undo: {}", e);
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
                    eprintln!("CopyAttach: failed to load image data from DB for undo: {}", e);
                    return 0;
                }
            }
        } else if png_data.is_empty() && *db_id == 0 {
            // Phase 2 async persist has not completed — no image data exists in DB.
            // Reject deletion: the entry stays in history, user can retry later.
            eprintln!("CopyAttach: cannot delete image entry {}: Phase 2 not yet complete (db_id=0)", entry_id);
            return 0;
        }
    }

    // Step 3: All undo data captured. Now remove from history.
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| match e {
            ClipboardEntry::Text { id, .. } => *id != entry_id,
            ClipboardEntry::Image { id, .. } => *id != entry_id,
        });
    }

    // Step 4: Delete from DB while entry is still in memory history.
    // If this fails, history entry stays intact; caller can retry.
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("CopyAttach: DB lock poisoned deleting entry {}: {}", entry_id, e);
            return 0;
        }
    };
    if let Err(e) = match &entry {
        ClipboardEntry::Text { db_id, .. } if *db_id != 0 => {
            conn.execute(
                "DELETE FROM clipboard_history WHERE id = ?1",
                rusqlite::params![*db_id],
            )
        }
        ClipboardEntry::Image { db_id, .. } if *db_id != 0 => {
            conn.execute(
                "DELETE FROM clipboard_history WHERE id = ?1",
                rusqlite::params![*db_id],
            )
        }
        _ => Ok(0),
    } {
        eprintln!("CopyAttach: failed to delete entry {} from DB: {}", entry_id, e);
        return 0;
    }

    // Step 5: All data captured and DB cleaned up. Now remove from history.
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| match e {
            ClipboardEntry::Text { id, .. } => *id != entry_id,
            ClipboardEntry::Image { id, .. } => *id != entry_id,
        });
    }

    // Step 6: Push to undo stack with fully captured data.
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

    // DB lock failure is fatal — entry has already been popped from the stack.
    // Panic so the crash report reveals the poisoning rather than silently losing data.
    let conn = b.db.lock().unwrap_or_else(|e| {
        panic!("CopyAttach: DB lock poisoned during undo: {}", e);
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

    let mut entry = entry;
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
    *hist = add_to_history(std::mem::take(&mut *hist), entry);
    while hist.len() > b.cleanup_threshold.load(Ordering::Relaxed) {
        hist.pop();
    }

    1
}

/// Returns 1 if there's at least one entry in the undo stack, 0 otherwise.
#[no_mangle]
pub extern "C" fn clipboard_can_undo() -> c_int {
    match crate::backend::try_backend() {
        Some(b) => !b.deleted_stack.lock().unwrap().is_empty() as c_int,
        None => 0,
    }
}

/// Trim the oldest N percent of entries from both in-memory history and DB.
/// Returns the number of entries removed.
#[no_mangle]
pub extern "C" fn clipboard_trim_oldest_percent(percent: i32) -> c_int {
    let b = match crate::backend::try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let removed = {
        let mut hist = b.history.lock().unwrap();
        let total = hist.len();
        if total == 0 {
            return 0;
        }
        let count = ((total as f64 * percent as f64 / 100.0).ceil()) as usize;
        let count = count.min(total);
        let split_at = total - count;
        hist.split_off(split_at)
    };

    if let Ok(conn) = b.db.lock() {
        for entry in &removed {
            match entry {
                ClipboardEntry::Text { db_id, .. } if *db_id != 0 => {
                    if let Err(e) = conn.execute(
                        "DELETE FROM clipboard_history WHERE id = ?1",
                        rusqlite::params![*db_id],
                    ) {
                        eprintln!("CopyAttach: failed to delete text from DB: {}", e);
                    }
                }
                ClipboardEntry::Image { db_id, .. } if *db_id != 0 => {
                    if let Err(e) = conn.execute(
                        "DELETE FROM clipboard_history WHERE id = ?1",
                        rusqlite::params![*db_id],
                    ) {
                        eprintln!("CopyAttach: failed to delete image from DB: {}", e);
                    }
                }
                _ => {
                    eprintln!("CopyAttach: skipping DB deletion for entry with db_id=0 (type: {})",
                              entry.content_type());
                }
            }
        }
    }

    removed.len() as c_int
}

// ═══════════════════════════════════════════
// Cleanup Threshold
// ═══════════════════════════════════════════

#[no_mangle]
pub extern "C" fn clipboard_get_cleanup_threshold() -> i32 {
    crate::backend::try_backend()
        .map(|b| b.cleanup_threshold.load(Ordering::Relaxed) as i32)
        .unwrap_or(DEFAULT_CLEANUP_THRESHOLD as i32)
}

/// Clamped to [100, 10000]. Immediately trims both DB and in-memory history.
#[no_mangle]
pub extern "C" fn clipboard_set_cleanup_threshold(threshold: i32) {
    if let Some(b) = crate::backend::try_backend() {
        let t = threshold.max(100).min(10000) as usize;
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
        Err(_) => return 0,
    };
    match conn.query_row(
        "SELECT COALESCE(SUM(LENGTH(text)), 0) + COALESCE(SUM(LENGTH(png_data)), 0) + COALESCE(SUM(LENGTH(thumb_data)), 0) FROM clipboard_history",
        [],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(size) => size,
        Err(e) => {
            eprintln!("CopyAttach: failed to query storage size: {}", e);
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn clipboard_check_permission() -> c_int {
    #[cfg(target_os = "macos")]
    { macos::check_permission() as c_int }
    #[cfg(not(target_os = "macos"))]
    { 1 }
}

#[no_mangle]
pub extern "C" fn clipboard_open_preferences() {
    #[cfg(target_os = "macos")]
    macos::open_preferences();
}
