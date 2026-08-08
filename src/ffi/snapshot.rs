use std::ffi::{c_char, c_int, c_longlong};

use crate::backend::try_backend;
use crate::types::ClipboardEntry;
use super::to_ffi_cstring;

/// Lightweight snapshot row: exactly the fields the frontend list consumes.
/// The full text is deliberately NOT carried — a refresh snapshot must stay
/// small even when history holds many multi-KB pasted documents.
pub(crate) struct SnapshotRow {
    pub(crate) entry_type: i32,
    pub(crate) id: i64,
    pub(crate) timestamp: i64,
    pub(crate) label: String,
    pub(crate) source_name: String,
    pub(crate) source_bundle_id: String,
    pub(crate) preview: String, // text entries only; empty for images
    pub(crate) db_id: i64,      // image entries only; 0 otherwise
    pub(crate) width: i32,
    pub(crate) height: i32,
}

impl SnapshotRow {
    pub(crate) fn from_entry(entry: &ClipboardEntry) -> SnapshotRow {
        let (preview, db_id, width, height) = match entry {
            ClipboardEntry::Text { .. } => (entry.preview(), 0, 0, 0),
            ClipboardEntry::Image { db_id, width, height, .. } => {
                (String::new(), *db_id, *width as i32, *height as i32)
            }
        };
        SnapshotRow {
            entry_type: entry.content_type(),
            id: entry.entry_id() as i64,
            timestamp: entry.timestamp() as i64,
            label: entry.label(),
            source_name: entry.source_name().to_string(),
            source_bundle_id: entry.source_bundle_id().to_string(),
            preview,
            db_id,
            width,
            height,
        }
    }
}

/// Opaque handle to a lightweight snapshot of clipboard history, taken under a
/// single history lock. Holds compact metadata + bounded previews — never full
/// text — so acquiring it does not deep-clone potentially many MB of pasted
/// content. All reads from this snapshot are race-free: the background monitor
/// thread cannot modify it.
pub struct Snapshot(Vec<SnapshotRow>);

/// Acquire a consistent snapshot of all history entries under one lock.
/// Returns an opaque handle (or null if the backend is uninitialized).
/// Caller must release with `clipboard_snapshot_release()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_acquire() -> *mut Snapshot {
    let hist = match try_backend() {
        Some(b) => b.history.lock().unwrap(),
        None => return std::ptr::null_mut(),
    };
    let rows: Vec<SnapshotRow> = hist.iter().map(SnapshotRow::from_entry).collect();
    Box::into_raw(Box::new(Snapshot(rows)))
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
    snap.0.get(index as usize).map_or(-1, |row| row.entry_type)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.id)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_timestamp(snap: *const Snapshot, index: c_int) -> c_longlong {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.timestamp)
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_label(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.label),
        None => std::ptr::null_mut(),
    }
}

/// Bounded preview text for a text item (≤ 256 Unicode scalars; long entries
/// elided to head……tail so the row shows the real ending). The list row only
/// renders ~50 visual chars, so the snapshot carries this bounded preview
/// instead of cloning the full text into the frontend. Caller must free
/// with `clipboard_free_string()`. Image items return null.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_preview(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => {
            if row.preview.is_empty() {
                std::ptr::null_mut()
            } else {
                to_ffi_cstring(&row.preview)
            }
        }
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_name(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.source_name),
        None => std::ptr::null_mut(),
    }
}

/// Caller must free with `clipboard_free_string()`.
#[no_mangle]
pub extern "C" fn clipboard_snapshot_item_source_bundle_id(snap: *const Snapshot, index: c_int) -> *mut c_char {
    if snap.is_null() { return std::ptr::null_mut(); }
    let snap = unsafe { &*snap };
    match snap.0.get(index as usize) {
        Some(row) => to_ffi_cstring(&row.source_bundle_id),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_db_id(snap: *const Snapshot, index: c_int) -> i64 {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.db_id)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_width(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.width)
}

#[no_mangle]
pub extern "C" fn clipboard_snapshot_get_image_height(snap: *const Snapshot, index: c_int) -> c_int {
    if snap.is_null() { return 0; }
    let snap = unsafe { &*snap };
    snap.0.get(index as usize).map_or(0, |row| row.height)
}

/// Safe to call with null pointer (no-op).
#[no_mangle]
pub extern "C" fn clipboard_snapshot_release(snap: *mut Snapshot) {
    if snap.is_null() { return; }
    unsafe { drop(Box::from_raw(snap)); }
}
