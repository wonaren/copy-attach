use std::collections::HashSet;
use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::Ordering;

use crate::backend::try_backend;
use crate::history::add_to_history;
use crate::types::ClipboardEntry;

#[no_mangle]
pub extern "C" fn clipboard_clear_history() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    // DB delete first: if it fails, the in-memory history stays untouched so
    // memory and DB remain consistent and the caller sees the failure (0).
    // History and favorites go together: a favorite whose row is gone is a
    // dangling id, so a clear must remove both.
    //
    // This is a HARD delete of every row, soft-deleted ones included: "清空历史"
    // is an explicit, confirmed, destructive action, and leaving a retention
    // window of deleted payloads behind it would contradict the confirmation
    // alert it comes from ("无法撤销").
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned clearing history: {e}");
            return 0;
        }
    };
    let cleared: Result<(), rusqlite::Error> = (|| {
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM clipboard_history", [])?;
        tx.execute("DELETE FROM clipboard_favorites", [])?;
        // The undo stack lives in this table; a side row whose payload row is
        // gone would be pruned on the next read anyway, but leaving it behind
        // makes "clear history" mean two different things to two tables.
        tx.execute("DELETE FROM clipboard_deleted", [])?;
        tx.commit()
    })();
    if let Err(e) = cleared {
        crate::error_log!("CopyAttach: failed to clear DB history: {e}");
        return 0;
    }
    drop(conn);

    // DB clear succeeded: clear the in-memory mirror. The undo stack lives in
    // the database, and every deleted row went with the DELETE above.
    if let Ok(mut favorites) = b.favorites.lock() {
        favorites.clear();
    }
    let mut hist = b.history.lock().unwrap();
    hist.clear();
    // Publish under the history lock so the emptied list is observed atomically.
    crate::backend::mark_history_changed();
    1
}

/// Would deleting this entry evict already-undoable deletions, and how many?
///
/// The caller asks BEFORE deleting so the user can be warned while it is still
/// reversible. Once the delete runs, the sweep has already dropped the evicted
/// rows — there is nothing left to report afterwards.
///
/// Returns the number of deletions that would be evicted, or -1 when the
/// question could not be answered (unknown entry, DB error). -1 is distinct
/// from 0 so the caller never shows "no eviction" on a failed probe.
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
        // Never persisted, so it can never be deleted either — nothing to warn
        // about. (The delete itself refuses this entry.)
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
    match crate::db::pending_undo_evictions(&conn, bytes, crate::backend::undo_budget_bytes()) {
        Ok(n) => n as c_int,
        Err(()) => -1,
    }
}

/// Soft-delete one entry: stamp its row, drop its favorite, and remove it from
/// the in-memory list. Returns 1 on success, 0 on failure.
///
/// The payload is NOT copied anywhere. The row keeps its text/png/thumb blobs,
/// which makes a delete a couple of index writes — no blob read, no temp file,
/// no resident memory. (The previous design materialized the payload to disk
/// precisely because a deleted row had to leave the table.) Undo depth is
/// therefore bounded by retention (`UNDO_RETENTION_SECS`) and a byte budget
/// (`undo_budget_bytes`), not by a step count.
#[no_mangle]
pub extern "C" fn clipboard_delete_by_id(entry_id: u64) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    // Resolve the entry in memory first: the history owns the entry set, so an
    // id it does not know is rejected before any write. The `db_id` it reports
    // is the row's full identity — a re-capture keeps the entry_id but points at
    // a different row — and it is what the stamp targets.
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

    // An entry with db_id=0 was never persisted (Phase 2 pending, or its DB
    // write failed). There is no row to stamp, so deletion is refused explicitly
    // — the entry stays listed and the user can retry once it lands.
    if db_id == 0 {
        crate::error_log!(
            "CopyAttach: cannot delete entry {entry_id}: db_id=0 (entry not persisted)"
        );
        return 0;
    }

    // Stamp the row and drop its favorite in one transaction. A deleted row must
    // not stay starred (the favorites table only references live rows), and the
    // flag it carries is what undo uses to restore the star.
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned deleting entry {entry_id}: {e}");
                return 0;
            }
        };
        let result: Result<(), ()> = (|| {
            let tx = conn.unchecked_transaction().map_err(|e| {
                crate::error_log!("CopyAttach: failed to begin delete transaction: {e}");
            })?;
            crate::db::soft_delete_row(&tx, db_id)?;
            tx.execute(
                "DELETE FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![entry_id as i64],
            )
            .map_err(|e| {
                crate::error_log!("CopyAttach: failed to drop favorite for deleted entry {entry_id}: {e}");
            })?;
            tx.commit().map_err(|e| {
                crate::error_log!("CopyAttach: failed to commit delete of entry {entry_id}: {e}");
            })?;
            Ok(())
        })();
        // The stamp (or the favorite drop) rolled back: the row is still live,
        // so memory must stay untouched.
        if result.is_err() {
            return 0;
        }
        // Self-limit the retained deleted set now instead of at the next launch:
        // a burst of large deletions sheds its oldest immediately.
        if crate::db::purge_expired_deleted_rows(&conn, crate::backend::undo_budget_bytes()).is_err() {
            crate::error_log!("CopyAttach: deleted-row sweep failed after delete; retried at next launch");
        }
    }

    // DB write succeeded: drop the favorite mirror and remove exactly the entry
    // whose row was stamped — by (entry_id, db_id), never by entry_id alone
    // (see `history::remove_deleted_entry`: a concurrent re-capture keeps the
    // entry_id but points at a different row).
    if let Ok(mut favorites) = b.favorites.lock() {
        favorites.remove(&entry_id);
    }
    {
        let mut hist = b.history.lock().unwrap();
        crate::history::remove_deleted_entry(&mut hist, entry_id, db_id);
        // Publish under the history lock: delete mutates and notifies atomically.
        crate::backend::mark_history_changed();
    }

    crate::debug_log!("CopyAttach: soft-deleted entry {entry_id} (db_id={db_id})");
    1
}

/// Payload read back from a soft-deleted row. Its `Drop` marks the pages
/// reusable, so every exit path (success, failure, early return) releases them
/// symmetrically with the `claim_pages` in `load_deleted_payload`.
enum DeletedBody {
    Text(String),
    Image { png: Vec<u8>, thumb: Vec<u8> },
}

impl DeletedBody {
    /// The body as text, for the dedup predicate. Images have no text body.
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

/// What the undo needs from a deleted row: the payload, the metadata entry it
/// will re-insert, and the star it carried.
struct UndoSource {
    entry: ClipboardEntry,
    body: DeletedBody,
    was_favorite: bool,
}

/// Why `load_deleted_payload` came back empty.
///
/// The two cases are NOT interchangeable: an unrestorable row can never be
/// restored and may have its undo entry dropped, while a read failure says
/// nothing about the row — dropping the entry there would turn a transient IO
/// error into a permanently lost undo (the payload row survives as a ghost and
/// reappears as live history on the next launch).
enum UndoLoadError {
    /// Absent, structurally incomplete (no text/blob, unknown `entry_type`) or
    /// unclaimable: nothing here can be restored.
    Unrestorable,
    /// The read itself failed. The row is untouched; a later undo may work.
    Read,
}

/// Read a soft-deleted row's payload and rebuild its metadata entry.
///
/// The entry's `timestamp` is restamped to now so the restored row sorts to the
/// top like any other "just used" entry, and `db_id` is cleared (the caller
/// assigns the new row id after the insert). `entry_id` is PRESERVED: Swift's
/// favorites and the undo's own bookkeeping key on it.
fn load_deleted_payload(
    conn: &rusqlite::Connection,
    row_id: i64,
) -> Result<UndoSource, UndoLoadError> {
    type Row = (
        i32,            // entry_type
        Option<String>, // text
        Option<Vec<u8>>,// png_data
        Option<Vec<u8>>,// thumb_data
        Option<i64>,    // thumb_width
        Option<i64>,    // thumb_height
        Option<i64>,    // width
        Option<i64>,    // height
        i64,            // entry_id
        i64,            // hash
        Option<String>, // preview
        String,         // label
        String,         // custom_label
        String,         // source_name
        String,         // source_bundle_id
        i64,            // deleted_favorite
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
            // `QueryReturnedNoRows` means the payload row is gone; anything else
            // is a real read failure and must not be reported as "gone".
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
            // The body arrives through rusqlite, which may have grown it over
            // reusable-marked pages; claim before anything reads it. A rejected
            // claim means the kernel may zero it mid-use, so refuse.
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
            // Same rule as the text body: an unclaimable blob is one the kernel
            // may zero while it is live, so refuse rather than restore an image
            // that would render as garbage.
            let png_ok = crate::backend::claim_pages(png.as_ptr(), png.capacity());
            let thumb_ok = crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity());
            if !png_ok || !thumb_ok {
                // Release-side symmetry for whichever one DID claim before
                // handing the pair off to `DeletedBody` (whose Drop would do it
                // otherwise).
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

/// Read a live row back into a metadata-only entry.
///
/// The undo's in-memory publish step uses this instead of the pre-delete clone:
/// the row it just wrote is the authority, and re-reading keeps the list in
/// lockstep with the table (new rowid, restamped timestamp, any dedup rewrite).
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

/// Undo the most recent deletion: restore the entry to the head of history.
/// Returns 1 on success, 0 when nothing is undoable or the restore failed.
///
/// The restored row is re-inserted as a NEW row (fresh rowid, current timestamp)
/// and the old deleted row is then removed, rather than un-stamping the old row.
/// Two reasons: the list is ordered by timestamp, so a restored entry must sort
/// to the top like any other "just used" entry; and the insert path already owns
/// dedup + trim, so content re-captured while it was deleted collapses to one
/// row instead of resurrecting a duplicate (the previous code inserted without
/// dedup, so undo followed by a restart left two identical rows — reachable even
/// with a one-slot stack).
#[no_mangle]
pub extern "C" fn clipboard_undo_delete() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    // Load the most recently deleted row's payload and restore it inside one
    // transaction. Everything below runs under the DB lock, so the row cannot be
    // swept (or otherwise change) between the read and the re-insert.
    let restored: Option<(u64, i64, bool)> = {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned during undo: {e}");
                return 0;
            }
        };
        let (old_row_id, entry_id, _stamp, was_favorite_raw) =
            match crate::db::newest_deleted_row(&conn) {
                Ok(Some(t)) => t,
                Ok(None) => {
                    crate::debug_log!("CopyAttach: undo requested with nothing deleted");
                    return 0;
                }
                // `newest_deleted_row` already logged the concrete SQLite error.
                // Reported as a failed undo (0), never as "nothing to undo": the
                // caller shows a distinct message for a genuine failure.
                Err(()) => return 0,
            };
        let was_favorite = was_favorite_raw != 0;

        // Read the payload back out of the deleted row. This is the only place a
        // delete's payload is ever touched again; `DeletedBody`'s Drop releases
        // its pages on every exit path.
        let source = match load_deleted_payload(&conn, old_row_id) {
            Ok(s) => s,
            Err(UndoLoadError::Unrestorable) => {
                // Nothing here can ever be restored, so the entry would block
                // the undo stack forever. Drop it — and say so, because the
                // payload row stays behind as history the user did not ask for.
                crate::error_log!("CopyAttach: undo could not load payload for deleted row {old_row_id} — dropping the undo entry");
                let _ = conn.execute(
                    "DELETE FROM clipboard_deleted WHERE row_id = ?1",
                    rusqlite::params![old_row_id],
                );
                return 0;
            }
            Err(UndoLoadError::Read) => {
                // The row is still there and may be perfectly restorable: keep
                // the undo entry (and the payload) instead of trading a
                // transient read error for a lost undo.
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
        // Locate the restored row by rowid range, NOT by `last_insert_rowid()`:
        // `insert_entry_to_db` raises the entry-id watermark with an upsert into
        // `clipboard_meta`, and an upsert moves `last_insert_rowid()` away from
        // the history row (measured: it reported row 1, a meta row). The history
        // table's max id before the insert is the reliable boundary.
        let before_max: i64 = match tx.query_row(
            "SELECT COALESCE(MAX(id), 0) FROM clipboard_history",
            [],
            |r| r.get(0),
        ) {
            Ok(v) => v,
            Err(e) => {
                crate::error_log!("CopyAttach: undo could not read the history id bound: {e}");
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
            Ok(v) if v > before_max => v,
            Ok(v) => {
                crate::error_log!("CopyAttach: undo insert produced no new history row (max id {v}, was {before_max})");
                return 0;
            }
            Err(e) => {
                crate::error_log!("CopyAttach: undo could not locate the restored row: {e}");
                return 0;
            }
        };
        // Collapse with any live copy of the same content: the re-capture made
        // while the entry was deleted is the older duplicate and goes away, so
        // exactly one row survives. The row just inserted has the highest id,
        // which is the row the dedup keeps.
        crate::db::delete_matching_entry(&tx, &source.entry, source.body.as_text());
        // The old (soft-deleted) row has served its purpose: remove both the
        // side-table entry and the payload row it describes.
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
        // Restore the star the entry carried when it was deleted.
        if was_favorite {
            if let Err(e) = tx.execute(
                "INSERT OR IGNORE INTO clipboard_favorites (entry_id) VALUES (?1)",
                rusqlite::params![entry_id as i64],
            ) {
                crate::error_log!("CopyAttach: undo could not restore favorite for entry {entry_id}: {e}");
                return 0;
            }
        }
        if let Err(e) = tx.commit() {
            crate::error_log!("CopyAttach: failed to commit undo of entry {entry_id}: {e}");
            return 0;
        }
        // The payload now belongs to the new row; release the read-back copy.
        drop(source);
        Some((entry_id, new_row_id, was_favorite))
    };

    let (entry_id, new_row_id, was_favorite) = match restored {
        Some(v) => v,
        None => return 0,
    };

    // Publish the in-memory side. A full reload would rebuild the whole snapshot
    // for one row, so re-read the new row's metadata and prepend it — exactly
    // what the capture path does. `add_to_history` dedups, so a live copy of the
    // same content collapses with the restored entry.
    let entry = {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned publishing undo of entry {entry_id}: {e}");
                return 0;
            }
        };
        match load_live_entry_by_row(&conn, new_row_id) {
            Some(e) => e,
            None => {
                crate::error_log!("CopyAttach: undo restored row {new_row_id} but could not read it back");
                return 0;
            }
        }
    };

    let restored_id = {
        let mut hist = b.history.lock().unwrap();
        *hist = add_to_history(std::mem::take(&mut *hist), entry);
        {
            let favorites = b.favorites.lock().unwrap();
            crate::backend::trim_history_memory(
                &mut hist,
                b.cleanup_threshold.load(Ordering::Relaxed),
                &favorites,
            );
        }
        // `add_to_history` may have rewritten the restored entry's id when it
        // deduplicated against a live copy; read the final id off the head so
        // Swift's last_restored_id points at the entry actually restored.
        let id = hist.first().map_or(0, ClipboardEntry::entry_id);
        crate::backend::mark_history_changed();
        id
    };

    if was_favorite {
        if let Ok(mut favorites) = b.favorites.lock() {
            favorites.insert(entry_id);
        }
    }

    // Record the restored entry ID so Swift can find it in the snapshot even if
    // the monitor thread inserted new content at position 0 meanwhile.
    b.last_restored_id.store(restored_id, Ordering::SeqCst);
    crate::debug_log!(
        "CopyAttach: undo restored entry {entry_id} as row {new_row_id} (favorite={was_favorite})"
    );
    1
}

/// Returns 1 if at least one deleted row is still undoable, 0 otherwise.
///
/// A read failure also returns 0, but logs it: 0 is the only value the FFI
/// contract has for "cannot undo", so the distinction lives in the log rather
/// than being silently swallowed.
#[no_mangle]
pub extern "C" fn clipboard_can_undo() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in can_undo: {e}");
            return 0;
        }
    };
    match crate::db::undo_depth(&conn) {
        Ok(depth) => c_int::from(depth > 0),
        // `undo_depth` already logged the concrete SQLite error.
        Err(()) => 0,
    }
}

/// How many deletions are currently undoable. Lets the UI say "还可撤销 N 步"
/// instead of implying a fixed step count.
///
/// 0 on a read failure as well, but the failure is logged: the FFI cannot
/// express "unknown" and a negative sentinel would be misread as a count.
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
        // `undo_depth` already logged the concrete SQLite error.
        Err(()) => 0,
    }
}

/// Current undo byte budget in bytes (0 = unlimited).
#[no_mangle]
pub extern "C" fn clipboard_get_undo_budget_bytes() -> i64 {
    crate::backend::undo_budget_bytes()
}

/// Persist a new undo byte budget (0 = unlimited) and apply it immediately.
///
/// Lowering the budget sweeps the retained deletions right away, so the
/// setting's effect is visible at once rather than at the next delete.
/// Returns 1 on success, 0 when the value was rejected or the write failed.
#[no_mangle]
pub extern "C" fn clipboard_set_undo_budget_bytes(bytes: i64) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };
    let max_bytes = crate::backend::MAX_UNDO_BUDGET_MB * 1024 * 1024;
    let clamped = if bytes <= crate::backend::UNDO_BUDGET_UNLIMITED {
        crate::backend::UNDO_BUDGET_UNLIMITED
    } else {
        bytes.min(max_bytes)
    };
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB mutex poisoned setting the undo budget: {e}");
                return 0;
            }
        };
        // DB first: on failure the in-memory budget must not diverge from what
        // the next launch would read back.
        if crate::db::store_undo_budget_bytes(&conn, clamped).is_err() {
            return 0;
        }
    }
    b.undo_budget_bytes.store(clamped, Ordering::Relaxed);
    // Apply the new cap now, so shrinking it frees the excess immediately.
    if let Ok(conn) = b.db.lock() {
        if crate::db::purge_expired_deleted_rows(&conn, clamped).is_err() {
            crate::error_log!("CopyAttach: sweep after undo-budget change failed; retried after the next delete");
        }
    }
    1
}

/// Returns the `entry_id` of the most recently undo-restored entry, or 0 if none.
/// Used by Swift to locate the restored entry in a snapshot despite monitor
/// thread races inserting new content at position 0.
#[no_mangle]
pub extern "C" fn clipboard_last_restored_id() -> u64 {
    match try_backend() {
        Some(b) => b.last_restored_id.load(Ordering::SeqCst),
        None => 0,
    }
}

/// Update the custom label / remark for an entry by its stable `entry_id`.
/// Pass an empty string to clear the custom label.
/// Rejects labels longer than `MAX_CUSTOM_LABEL_SCALARS` (caller contract).
/// Returns 1 on success, 0 on failure (entry not found, over-long label, DB error).
///
/// Order matters: the DB row is written first, so a DB failure leaves the
/// in-memory entry untouched — the same ordering `clipboard_trim_oldest_percent`
/// documents. A failure is never reported as success: memory and DB must agree.
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

    // The history owns the entry set: an id the in-memory history doesn't know
    // is rejected before any write, so a stale/unknown id can never touch a row.
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

    // DB first: on failure nothing in memory has changed.
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(_) => return 0,
        };
        if crate::db::update_entry_custom_label(&conn, entry_id, &label_str).is_err() {
            return 0;
        }
    }

    // Memory write-through.
    {
        let mut hist = match b.history.lock() {
            Ok(h) => h,
            Err(_) => return 0,
        };
        match hist.iter_mut().find(|e| e.entry_id() == entry_id) {
            Some(ClipboardEntry::Text { custom_label, .. })
            | Some(ClipboardEntry::Image { custom_label, .. }) => *custom_label = label_str,
            None => {
                // The entry was deleted between the DB write and this lock. The
                // delete removed the row too, so there is nothing to diverge.
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

/// Mark/unmark one entry as a favorite.
///
/// DB first: a row that no longer exists is an explicit failure (0), never a
/// dangling favorite id. On success both the durable table and the in-memory
/// mirror used by the snapshot/trim are updated, and the list is republished so
/// every open view re-reads the flag from the single source of truth.
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

/// Trim the oldest N percent of **cleanable** entries from both DB and
/// in-memory history. Favorites are never removed and do not count toward N.
/// Returns the number of entries actually removed.
///
/// DB first, and a DB failure aborts the whole operation (returns 0) with
/// memory untouched: the DB row is what makes a removal durable, so trimming
/// memory after a failed DELETE would let every "removed" entry reappear on
/// the next launch while the caller still reported success. Mirrors the
/// contract of `clipboard_delete_by_id` / `clipboard_clear_history`.
///
/// The removal is by identity (db_id), not by tail position: an in-memory entry
/// whose row the DELETE did not touch must survive, and synchronously-inserted
/// captures during the window are never in the deleted id set.
#[no_mangle]
pub extern "C" fn clipboard_trim_oldest_percent(percent: i32) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    if percent <= 0 {
        return 0;
    }

    let favorites = match b.favorites.lock() {
        Ok(f) => f.clone(),
        Err(e) => {
            crate::error_log!("CopyAttach: favorites mutex poisoned in trim_oldest_percent: {e}");
            return 0;
        }
    };

    let count = {
        let hist = b.history.lock().unwrap();
        let cleanable_total = hist
            .iter()
            .filter(|e| !favorites.contains(&e.entry_id()))
            .count();
        if cleanable_total == 0 {
            return 0;
        }
        let count = ((cleanable_total as f64 * f64::from(percent) / 100.0).ceil()) as usize;
        count.min(cleanable_total)
    };

    if count == 0 {
        return 0;
    }

    // Step 1: delete the oldest cleanable rows from the DB. The favorite table
    // is the authority here, so this matches the automatic trim exactly.
    // A failure leaves memory — and the durable state — untouched. "Oldest" is
    // by `(timestamp, id)`, the same order the list uses: trimming by rowid
    // instead would evict the user's own newer rows first whenever the table
    // holds rows inserted out of chronological order (a merge).
    let deleted_ids: HashSet<i64> = match b.db.lock() {
        Ok(conn) => {
            let mut stmt = match conn.prepare(
                "SELECT id, entry_id FROM clipboard_history
                 WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                   AND entry_id NOT IN (SELECT entry_id FROM clipboard_favorites)
                 ORDER BY timestamp ASC, id ASC",
            ) {
                Ok(s) => s,
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to prepare trim query: {e} — history left intact");
                    return 0;
                }
            };
            let mut rows = match stmt.query([]) {
                Ok(r) => r,
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to query rows to trim: {e} — history left intact");
                    return 0;
                }
            };
            let mut ids = Vec::with_capacity(count);
            while let Ok(Some(row)) = rows.next() {
                let db_id: i64 = match row.get(0) {
                    Ok(id) => id,
                    Err(_) => continue,
                };
                ids.push(db_id);
                if ids.len() >= count {
                    break;
                }
            }
            drop(rows);
            drop(stmt);

            if ids.is_empty() {
                return 0;
            }

            let tx = match conn.unchecked_transaction() {
                Ok(t) => t,
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to begin trim transaction: {e} — history left intact");
                    return 0;
                }
            };
            let mut deleted_count = 0;
            for chunk in ids.chunks(500) {
                let placeholders = vec!["?"; chunk.len()].join(",");
                let sql = format!(
                    "DELETE FROM clipboard_history
                      WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
                        AND id IN ({placeholders})"
                );
                match tx.execute(&sql, rusqlite::params_from_iter(chunk.iter())) {
                    Ok(c) => deleted_count += c,
                    Err(e) => {
                        crate::error_log!("CopyAttach: failed to trim DB by {} entries: {e} — history left intact", ids.len());
                        return 0;
                    }
                }
            }
            if let Err(e) = tx.commit() {
                crate::error_log!("CopyAttach: failed to commit trim transaction: {e} — history left intact");
                return 0;
            }
            ids.into_iter().take(deleted_count).collect()
        }
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in trim_oldest_percent: {e}");
            return 0;
        }
    };

    if deleted_ids.is_empty() {
        return 0;
    }

    // Step 2: drop exactly those rows from memory, by identity. The entries
    // the DELETE did not remove keep their rows and must stay listed; favorites
    // were excluded by the query and remain untouched.
    let actual = {
        let mut hist = b.history.lock().unwrap();
        let before = hist.len();
        hist.retain(|e| !deleted_ids.contains(&e.db_id()));
        let removed = before - hist.len();
        // Publish under the history lock (entries were removed).
        crate::backend::mark_history_changed();
        removed
    };

    actual as c_int
}
