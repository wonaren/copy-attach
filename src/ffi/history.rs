use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::Ordering;

use crate::backend::try_backend;
use crate::types::ClipboardEntry;

#[no_mangle]
pub extern "C" fn clipboard_clear_history() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned clearing history: {e}");
            return 0;
        }
    };
    let Ok(mut hist) = b.history.lock() else { return 0 };
    let cleared: Result<(), rusqlite::Error> = (|| {
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM clipboard_history", [])?;
        tx.execute("DELETE FROM clipboard_favorites", [])?;
        tx.execute("DELETE FROM clipboard_quick_slots", [])?;
        tx.execute("DELETE FROM clipboard_deleted", [])?;
        tx.commit()
    })();
    if let Err(e) = cleared {
        crate::error_log!("CopyAttach: failed to clear DB history: {e}");
        return 0;
    }
    if let Ok(mut favorites) = b.favorites.lock() {
        favorites.clear();
    }
    if let Ok(mut slots) = b.quick_slots.lock() {
        *slots = [0u64; crate::db::QUICK_SLOT_COUNT];
    }
    hist.clear();
    crate::backend::mark_history_changed();
    1
}

#[no_mangle]
pub extern "C" fn clipboard_undo_eviction_preview(entry_id: u64) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return -1,
    };
    let db_id = {
        let hist = b.history.lock().unwrap();
        match hist.iter().find(|e| e.entry_id() == entry_id) {
            Some(e) => e.db_id(),
            None => {
                crate::error_log!("CopyAttach: eviction preview for unknown entry {entry_id}");
                return -1;
            }
        }
    };
    if db_id == 0 {
        return 0;
    }
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in eviction preview: {e}");
            return -1;
        }
    };
    let bytes = match crate::db::history_row_payload_bytes(&conn, db_id) {
        Ok(v) => v,
        Err(()) => return -1,
    };
    match crate::db::pending_undo_evictions(&conn, bytes, crate::backend::undo_limit()) {
        Ok(n) => n as c_int,
        Err(()) => -1,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_delete_by_id(entry_id: u64) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let db_id = {
        let hist = b.history.lock().unwrap();
        match hist.iter().find(|e| e.entry_id() == entry_id) {
            Some(e) => e.db_id(),
            None => {
                crate::error_log!("CopyAttach: cannot delete entry {entry_id}: not in history");
                return 0;
            }
        }
    };

    if db_id == 0 {
        crate::error_log!(
            "CopyAttach: cannot delete entry {entry_id}: db_id=0 (entry not persisted)"
        );
        return 0;
    }

    let row_entry_id: u64;
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned deleting entry {entry_id}: {e}");
                return 0;
            }
        };
        row_entry_id = match (|| -> Result<u64, ()> {
            let tx = conn.unchecked_transaction().map_err(|e| {
                crate::error_log!("CopyAttach: failed to begin delete transaction: {e}");
            })?;
            let row_entry_id = crate::db::soft_delete_row(&tx, db_id)?;
            tx.execute(
                "DELETE FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![row_entry_id as i64],
            )
            .map_err(|e| {
                crate::error_log!("CopyAttach: failed to drop favorite for deleted entry {entry_id}: {e}");
            })?;
            tx.commit().map_err(|e| {
                crate::error_log!("CopyAttach: failed to commit delete of entry {entry_id}: {e}");
            })?;
            Ok(row_entry_id)
        })() {
            Ok(id) => id,
            Err(()) => return 0,
        };
        if crate::db::purge_expired_deleted_rows(&conn, crate::backend::undo_limit()).is_err() {
            crate::error_log!("CopyAttach: deleted-row sweep failed after delete; retried at next launch");
        }
    }

    if let Ok(mut favorites) = b.favorites.lock() {
        favorites.remove(&row_entry_id);
    }
    if let Ok(mut slots) = b.quick_slots.lock() {
        for slot in slots.iter_mut() {
            if *slot == row_entry_id {
                *slot = 0;
            }
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        crate::history::remove_deleted_entry(&mut hist, db_id);
        crate::backend::mark_history_changed();
    }

    crate::debug_log!("CopyAttach: soft-deleted entry {entry_id} (db_id={db_id})");
    1
}

enum DeletedBody {
    Text(String),
    Image { png: Vec<u8>, thumb: Vec<u8> },
}

impl DeletedBody {
    fn as_text(&self) -> Option<&str> {
        match self {
            DeletedBody::Text(t) => Some(t),
            DeletedBody::Image { .. } => None,
        }
    }
}

impl Drop for DeletedBody {
    fn drop(&mut self) {
        match self {
            DeletedBody::Text(t) => {
                crate::backend::mark_pages_reusable(t.as_ptr(), t.capacity());
            }
            DeletedBody::Image { png, thumb } => {
                crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
                crate::backend::mark_pages_reusable(thumb.as_ptr(), thumb.capacity());
            }
        }
    }
}

struct UndoSource {
    entry: ClipboardEntry,
    body: DeletedBody,
    was_favorite: bool,
}

enum UndoLoadError {
    Unrestorable,
    Read,
}

fn load_deleted_payload(
    conn: &rusqlite::Connection,
    row_id: i64,
) -> Result<UndoSource, UndoLoadError> {
    type Row = (
        i32,
        Option<String>,
        Option<Vec<u8>>,
        Option<Vec<u8>>,
        Option<i64>,
        Option<i64>,
        Option<i64>,
        Option<i64>,
        i64,
        i64,
        Option<String>,
        String,
        String,
        String,
        String,
        i64,
    );
    let row: Row = conn
        .query_row(
            "SELECT entry_type, text, png_data, thumb_data, thumb_width, thumb_height,
                    width, height, h.entry_id, hash, preview, label, custom_label,
                    source_name, source_bundle_id, d.was_favorite
             FROM clipboard_history h
             JOIN clipboard_deleted d ON d.row_id = h.id
             WHERE h.id = ?1",
            rusqlite::params![row_id],
            |row| {
                Ok((
                    row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?,
                    row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?, row.get(10)?, row.get(11)?,
                    row.get(12)?, row.get(13)?, row.get(14)?, row.get(15)?,
                ))
            },
        )
        .map_err(|e| {
            match e {
                rusqlite::Error::QueryReturnedNoRows => UndoLoadError::Unrestorable,
                e => {
                    crate::error_log!("CopyAttach: undo could not read deleted row {row_id}: {e}");
                    UndoLoadError::Read
                }
            }
        })?;
    let (
        entry_type, text, png, thumb, tw, th, width, height, entry_id, hash, preview, label,
        custom_label, source_name, source_bundle_id, deleted_favorite,
    ) = row;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    let (entry, body) = match entry_type {
        0 => {
            let body = match text {
                Some(t) => t,
                None => {
                    crate::error_log!("CopyAttach: deleted text row {row_id} carries no text — unrestorable");
                    return Err(UndoLoadError::Unrestorable);
                }
            };
            if !crate::backend::claim_pages(body.as_ptr(), body.capacity()) {
                crate::error_log!("CopyAttach: undo text body for row {row_id} could not be claimed — unreadable");
                return Err(UndoLoadError::Unrestorable);
            }
            let entry = ClipboardEntry::Text {
                id: entry_id as u64,
                preview: preview.unwrap_or_default(),
                label,
                custom_label,
                text_hash: hash as u64,
                timestamp: now,
                source_name,
                source_bundle_id,
                db_id: 0,
            };
            (entry, DeletedBody::Text(body))
        }
        1 => {
            let (png, thumb) = match (png, thumb) {
                (Some(p), Some(t)) => (p, t),
                _ => {
                    crate::error_log!("CopyAttach: deleted image row {row_id} is missing its blobs — unrestorable");
                    return Err(UndoLoadError::Unrestorable);
                }
            };
            let png_ok = crate::backend::claim_pages(png.as_ptr(), png.capacity());
            let thumb_ok = crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity());
            if !png_ok || !thumb_ok {
                crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
                crate::backend::mark_pages_reusable(thumb.as_ptr(), thumb.capacity());
                crate::error_log!("CopyAttach: undo image payload for row {row_id} could not be claimed — unreadable");
                return Err(UndoLoadError::Unrestorable);
            }
            let entry = ClipboardEntry::Image {
                id: entry_id as u64,
                width: width.unwrap_or(0) as u32,
                height: height.unwrap_or(0) as u32,
                thumb_width: tw.unwrap_or(0) as u32,
                thumb_height: th.unwrap_or(0) as u32,
                hash: hash as u64,
                custom_label,
                timestamp: now,
                source_name,
                source_bundle_id,
                db_id: 0,
            };
            (entry, DeletedBody::Image { png, thumb })
        }
        other => {
            crate::error_log!("CopyAttach: deleted row {row_id} has unknown entry_type {other}");
            return Err(UndoLoadError::Unrestorable);
        }
    };

    Ok(UndoSource {
        entry,
        body,
        was_favorite: deleted_favorite != 0,
    })
}

fn load_live_entry_by_row(conn: &rusqlite::Connection, row_id: i64) -> Option<ClipboardEntry> {
    type LiveRow = (i32, i64, Option<String>, String, String, i64, Option<i64>, Option<i64>,
                    Option<i64>, Option<i64>, i64, String, String);
    let row: LiveRow = conn
        .query_row(
            "SELECT entry_type, entry_id, preview, label, custom_label, hash,
                    width, height, thumb_width, thumb_height, timestamp,
                    source_name, source_bundle_id
             FROM clipboard_history WHERE id = ?1",
            rusqlite::params![row_id],
            |row| {
                Ok((
                    row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?,
                    row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?, row.get(10)?,
                    row.get(11)?, row.get(12)?,
                ))
            },
        )
        .map_err(|e| {
            crate::error_log!("CopyAttach: undo could not read back row {row_id}: {e}");
        })
        .ok()?;
    let (entry_type, entry_id, preview, label, custom_label, hash, width, height, tw, th,
         timestamp, source_name, source_bundle_id) = row;

    Some(match entry_type {
        0 => ClipboardEntry::Text {
            id: entry_id as u64,
            preview: preview.unwrap_or_default(),
            label,
            custom_label,
            text_hash: hash as u64,
            timestamp: timestamp as u64,
            source_name,
            source_bundle_id,
            db_id: row_id,
        },
        1 => ClipboardEntry::Image {
            id: entry_id as u64,
            width: width.unwrap_or(0) as u32,
            height: height.unwrap_or(0) as u32,
            thumb_width: tw.unwrap_or(0) as u32,
            thumb_height: th.unwrap_or(0) as u32,
            hash: hash as u64,
            custom_label,
            timestamp: timestamp as u64,
            source_name,
            source_bundle_id,
            db_id: row_id,
        },
        other => {
            crate::error_log!("CopyAttach: row {row_id} has unknown entry_type {other}");
            return None;
        }
    })
}

#[no_mangle]
pub extern "C" fn clipboard_undo_delete() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned during undo: {e}");
            return 0;
        }
    };
    let (old_row_id, entry_id, was_favorite, was_slot) =
        match crate::db::newest_deleted_row(&conn) {
            Ok(Some(t)) => t,
            Ok(None) => {
                crate::debug_log!("CopyAttach: undo requested with nothing deleted");
                return 0;
            }
            Err(()) => return 0,
        };

    let source = match load_deleted_payload(&conn, old_row_id) {
        Ok(s) => s,
        Err(UndoLoadError::Unrestorable) => {
            crate::error_log!("CopyAttach: undo could not load payload for deleted row {old_row_id} — discarding it");
            if crate::db::delete_payload_rows(&conn, &[old_row_id]).is_err() {
                crate::error_log!("CopyAttach: failed to discard unrestorable undo row {old_row_id}");
            }
            return 0;
        }
        Err(UndoLoadError::Read) => {
            crate::error_log!("CopyAttach: undo read of deleted row {old_row_id} failed — undo entry kept");
            return 0;
        }
    };

    let tx = match conn.unchecked_transaction() {
        Ok(t) => t,
        Err(e) => {
            crate::error_log!("CopyAttach: failed to begin undo transaction: {e}");
            return 0;
        }
    };
    let insert = match &source.body {
        DeletedBody::Text(body) => {
            crate::db::insert_entry_to_db(&tx, &source.entry, Some(body), None, None)
        }
        DeletedBody::Image { png, thumb } => {
            let (tw, th) = match &source.entry {
                ClipboardEntry::Image { thumb_width, thumb_height, .. } => {
                    (*thumb_width, *thumb_height)
                }
                _ => (0, 0),
            };
            crate::db::insert_entry_to_db(&tx, &source.entry, None, Some(png), Some((thumb, tw, th)))
        }
    };
    if insert.is_err() {
        crate::error_log!("CopyAttach: undo failed to re-insert entry {entry_id}; the deleted row is kept for retry");
        return 0;
    }
    let new_row_id = match tx.query_row(
        "SELECT COALESCE(MAX(id), 0) FROM clipboard_history",
        [],
        |r| r.get::<_, i64>(0),
    ) {
        Ok(v) => v,
        Err(e) => {
            crate::error_log!("CopyAttach: undo could not locate the restored row: {e}");
            return 0;
        }
    };
    let duplicates = match crate::db::delete_matching_entry(&tx, &source.entry, source.body.as_text()) {
        Ok(rows) => rows,
        Err(()) => return 0,
    };
    if let Err(e) = tx.execute(
        "DELETE FROM clipboard_deleted WHERE row_id = ?1",
        rusqlite::params![old_row_id],
    ) {
        crate::error_log!("CopyAttach: undo could not remove the undo entry {old_row_id}: {e}");
        return 0;
    }
    if let Err(e) = tx.execute(
        "DELETE FROM clipboard_history WHERE id = ?1",
        rusqlite::params![old_row_id],
    ) {
        crate::error_log!("CopyAttach: undo could not remove the deleted row {old_row_id}: {e}");
        return 0;
    }
    if was_favorite {
        if let Err(e) = tx.execute(
            "INSERT OR IGNORE INTO clipboard_favorites (entry_id) VALUES (?1)",
            rusqlite::params![entry_id as i64],
        ) {
            crate::error_log!("CopyAttach: undo could not restore favorite for entry {entry_id}: {e}");
            return 0;
        }
    }
    if was_slot != 0 {
        if let Err(e) = tx.execute(
            "INSERT OR IGNORE INTO clipboard_quick_slots (slot, entry_id) VALUES (?1, ?2)",
            rusqlite::params![was_slot as i64, entry_id as i64],
        ) {
            crate::error_log!("CopyAttach: undo could not restore quick slot for entry {entry_id}: {e}");
            return 0;
        }
    }
    let Ok(mut removed) = crate::db::trim_db_history_keeping(
        &tx,
        b.cleanup_threshold.load(Ordering::Relaxed),
        Some(new_row_id),
    ) else {
        return 0;
    };
    removed.extend(duplicates);
    let favorites_after = match crate::db::load_favorites(&tx) {
        Ok(set) => set,
        Err(()) => {
            crate::error_log!("CopyAttach: undo could not read back favorites for entry {entry_id}; rolling back");
            return 0;
        }
    };
    let slots_after = match crate::db::load_quick_slots(&tx) {
        Ok(set) => set,
        Err(()) => {
            crate::error_log!("CopyAttach: undo could not read back quick slots for entry {entry_id}; rolling back");
            return 0;
        }
    };
    let restored_entry = match load_live_entry_by_row(&tx, new_row_id) {
        Some(e) => e,
        None => {
            crate::error_log!("CopyAttach: undo could not read back restored row {new_row_id}; rolling back");
            return 0;
        }
    };
    let Ok(mut hist) = b.history.lock() else { return 0 };
    let Ok(mut favorites) = b.favorites.lock() else { return 0 };
    let Ok(mut slots) = b.quick_slots.lock() else { return 0 };
    if let Err(e) = tx.commit() {
        crate::error_log!("CopyAttach: failed to commit undo of entry {entry_id}: {e}");
        return 0;
    }
    let restored_favorite = favorites_after.contains(&entry_id);
    *favorites = favorites_after;
    *slots = slots_after;
    crate::history::publish_persisted_entry(&mut hist, restored_entry, new_row_id, &removed);
    b.last_restored_id.store(entry_id, Ordering::SeqCst);
    crate::backend::mark_history_changed();
    crate::debug_log!(
        "CopyAttach: undo restored entry {entry_id} as row {new_row_id} (favorite={restored_favorite})"
    );
    1
}

#[no_mangle]
pub extern "C" fn clipboard_undo_depth() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in undo_depth: {e}");
            return 0;
        }
    };
    match crate::db::undo_depth(&conn) {
        Ok(depth) => depth as c_int,
        Err(()) => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_get_undo_limit() -> i64 {
    crate::backend::undo_limit()
}

#[no_mangle]
pub extern "C" fn clipboard_set_undo_limit(limit: i64) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let clamped = if limit < 0 {
        limit
    } else {
        limit.min(crate::backend::MAX_UNDO_BUDGET_MB * 1024 * 1024)
    };
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned setting the undo limit: {e}");
                return 0;
            }
        };
        if crate::db::store_undo_limit(&conn, clamped).is_err() {
            return 0;
        }
    }
    b.undo_limit.store(clamped, Ordering::Relaxed);
    if let Ok(conn) = b.db.lock() {
        if crate::db::purge_expired_deleted_rows(&conn, clamped).is_err() {
            crate::error_log!("CopyAttach: sweep after undo-limit change failed; retried after the next delete");
        }
    }
    1
}

#[no_mangle]
pub extern "C" fn clipboard_last_restored_id() -> u64 {
    match try_backend() {
        Some(b) => b.last_restored_id.load(Ordering::SeqCst),
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn clipboard_set_custom_label(entry_id: u64, label: *const c_char) -> c_int {
    if label.is_null() {
        return 0;
    }
    let label_str = unsafe { CStr::from_ptr(label) }.to_string_lossy().into_owned();
    if label_str.chars().count() > crate::types::MAX_CUSTOM_LABEL_SCALARS {
        crate::error_log!(
            "CopyAttach: set_custom_label: label for entry {entry_id} exceeds {} scalars — rejected",
            crate::types::MAX_CUSTOM_LABEL_SCALARS
        );
        return 0;
    }
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    {
        let hist = match b.history.lock() {
            Ok(h) => h,
            Err(_) => return 0,
        };
        if !hist.iter().any(|e| e.entry_id() == entry_id) {
            crate::error_log!("CopyAttach: set_custom_label: entry {entry_id} not found");
            return 0;
        }
    }

    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(_) => return 0,
        };
        if crate::db::update_entry_custom_label(&conn, entry_id, &label_str).is_err() {
            return 0;
        }
    }

    {
        let mut hist = match b.history.lock() {
            Ok(h) => h,
            Err(_) => return 0,
        };
        match hist.iter_mut().find(|e| e.entry_id() == entry_id) {
            Some(ClipboardEntry::Text { custom_label, .. })
            | Some(ClipboardEntry::Image { custom_label, .. }) => *custom_label = label_str,
            None => {
                crate::error_log!(
                    "CopyAttach: set_custom_label: entry {entry_id} vanished after DB write"
                );
                return 0;
            }
        }
    }

    crate::backend::mark_history_changed();
    1
}

#[no_mangle]
pub extern "C" fn clipboard_set_favorite(entry_id: u64, favorite: c_int) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let want = favorite != 0;

    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned toggling favorite for {entry_id}: {e}");
                return 0;
            }
        };
        if crate::db::set_favorite(&conn, entry_id, want).is_err() {
            return 0;
        }
    }

    {
        let mut favorites = match b.favorites.lock() {
            Ok(f) => f,
            Err(e) => {
                crate::error_log!("CopyAttach: favorites mutex poisoned toggling {entry_id}: {e}");
                return 0;
            }
        };
        if want {
            favorites.insert(entry_id);
        } else {
            favorites.remove(&entry_id);
        }
    }

    crate::backend::mark_history_changed();
    1
}

#[no_mangle]
pub extern "C" fn clipboard_toggle_quick_slot(entry_id: u64, slot: c_int) -> c_int {
    if slot < 1 || slot as usize > crate::db::QUICK_SLOT_COUNT {
        crate::error_log!("CopyAttach: toggle_quick_slot: slot {slot} out of range");
        return 0;
    }
    update_quick_slots(|conn, slots| {
        crate::db::toggle_quick_slot(conn, entry_id, slot as u8)?;
        *slots = crate::db::load_quick_slots(conn)?;
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn clipboard_remove_quick_slot(entry_id: u64, slot: c_int) -> c_int {
    if entry_id == 0 || entry_id > i64::MAX as u64 || slot < 1 || slot as usize > crate::db::QUICK_SLOT_COUNT {
        crate::error_log!("CopyAttach: remove_quick_slot: invalid entry {entry_id} or slot {slot}");
        return 0;
    }
    update_quick_slots(|conn, slots| {
        crate::db::remove_quick_slot(conn, entry_id, slot as u8)?;
        let owner = &mut slots[(slot - 1) as usize];
        if *owner == entry_id {
            *owner = 0;
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn clipboard_clear_quick_slots() -> c_int {
    update_quick_slots(|conn, slots| {
        crate::db::clear_quick_slots(conn)?;
        slots.fill(0);
        Ok(())
    })
}

fn update_quick_slots(
    update: impl FnOnce(&rusqlite::Connection, &mut [u64; crate::db::QUICK_SLOT_COUNT]) -> Result<(), ()>,
) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(conn) => conn,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned updating quick slots: {e}");
            return 0;
        }
    };
    let mut slots = match b.quick_slots.lock() {
        Ok(slots) => slots,
        Err(e) => {
            crate::error_log!("CopyAttach: quick-slots mutex poisoned: {e}");
            return 0;
        }
    };
    if update(&conn, &mut slots).is_err() {
        return 0;
    }
    crate::backend::mark_history_changed();
    1
}

#[no_mangle]
pub extern "C" fn clipboard_trim_oldest_percent(percent: i32) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    if percent <= 0 {
        return 0;
    }

    let conn = match b.db.lock() {
        Ok(conn) => conn,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in trim_oldest_percent: {e}");
            return 0;
        }
    };
    let Ok(mut hist) = b.history.lock() else { return 0 };
    let Ok(removed) = crate::db::trim_db_history_by_percent(&conn, percent.min(100)) else { return 0 };
    if !removed.is_empty() {
        hist.retain(|entry| !removed.contains(&entry.db_id()));
        crate::backend::mark_history_changed();
    }
    removed.len() as c_int
}
