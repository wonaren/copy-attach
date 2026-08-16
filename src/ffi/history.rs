use std::ffi::c_int;
use std::sync::atomic::Ordering;

use crate::backend::{push_deleted, try_backend};
use crate::db::{insert_entry_to_db, load_text_by_db_id};
use crate::history::add_to_history;
use crate::types::ClipboardEntry;

#[no_mangle]
pub extern "C" fn clipboard_clear_history() {
    if let Some(b) = try_backend() {
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
    let b = match try_backend() {
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

    // Step 2: Load full content for undo BEFORE the DB delete removes it.
    // Text bodies live only in SQLite (the in-memory entry carries just a
    // preview), so they are loaded here and stashed for the undo stack. A text
    // entry with db_id=0 was never persisted and has no restorable body —
    // reject deletion explicitly, matching the image Phase 2 guard below.
    let mut undo_text: Option<String> = None;
    if let ClipboardEntry::Text { db_id, .. } = &entry {
        if *db_id == 0 {
            eprintln!("CopyAttach: cannot delete text entry {entry_id}: db_id=0 (entry not persisted)");
            return 0;
        }
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("CopyAttach: DB lock poisoned loading text for undo of entry {entry_id}: {e}");
                return 0;
            }
        };
        match load_text_by_db_id(&conn, *db_id) {
            Some(t) => undo_text = Some(t),
            None => {
                eprintln!("CopyAttach: failed to load text for undo of entry {entry_id} — delete aborted");
                return 0;
            }
        }
    }

    // For image entries, load full data from DB before removal.
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
                    // Claim any reusable-marked pages the allocator handed
                    // back: these blobs sit in the undo stack (long-lived).
                    crate::backend::claim_pages(png.as_ptr(), png.capacity());
                    crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity());
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
            ClipboardEntry::Text { db_id, .. } => {
                // Step 2 rejected unpersisted text (db_id=0) up front, so this
                // is always the rowid delete.
                conn.execute(
                    "DELETE FROM clipboard_history WHERE id = ?1",
                    rusqlite::params![*db_id],
                )
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

    // Step 5: Push to undo stack with fully captured data, under the entry
    // count and total-bytes caps (see `backend::push_deleted`). The entry is
    // moved, not cloned: a clone would double the transient full-PNG memory
    // (multi-MB memcpy) and the original is never used again after this point.
    {
        let mut stack = b.deleted_stack.lock().unwrap();
        let payload_bytes = match &entry {
            ClipboardEntry::Text { .. } => undo_text.as_deref().map(|t| t.len()).unwrap_or(0),
            ClipboardEntry::Image { png_data, thumb_data, .. } => {
                png_data.len() + thumb_data.len()
            }
        };
        eprintln!("CopyAttach: delete push entry_id={entry_id} payload_bytes={payload_bytes}");
        push_deleted(&mut stack, entry, undo_text);
    }

    1
}

/// Undo the most recent deletion: restore the entry back into history
/// at the front of the list and re-insert into DB.
/// Returns 1 on success, 0 if there's nothing to undo.
#[no_mangle]
pub extern "C" fn clipboard_undo_delete() -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    let (mut entry, undo_text) = {
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
    if insert_entry_to_db(&conn, &entry, undo_text.as_deref(), png_for_db, thumb_for_db).is_err() {
        let mut stack = b.deleted_stack.lock().unwrap();
        stack.push((entry, undo_text));
        return 0;
    }
    let new_row_id = conn.last_insert_rowid();

    // The restored image's blobs now live in the new DB row. Clear them from
    // the in-memory entry to honor the "memory entries hold metadata only"
    // invariant (load_history_from_db/monitor create Image entries with empty
    // png_data). Without this, undoing a large image delete pins the full PNG
    // in the history Vec, and the next clipboard_get_image_full_by_db_id cache
    // hit clones it under the history lock — stalling the monitor thread and
    // defeating MAX_UNDO_BYTES' purpose. Consumers (preview/paste/delete/drag)
    // all load by db_id, so the blob is redundant here.
    //
    // `mem::take`, not `clear()`: `clear()` drops the bytes but keeps the
    // Vec's capacity, so an entry restored from a multi-MB deletion would
    // silently pin its full PNG+thumb allocation inside the in-memory history
    // Vec for the entry's entire lifetime — the exact "metadata only" memory
    // invariant this block exists to preserve. `mem::take` hands the old
    // buffer to a temporary that is dropped here, releasing the allocation.
    match &mut entry {
        ClipboardEntry::Text { ref mut db_id, .. } => *db_id = new_row_id,
        ClipboardEntry::Image { ref mut db_id, ref mut png_data, ref mut thumb_data, .. } => {
            *db_id = new_row_id;
            let _ = std::mem::take(png_data);
            let _ = std::mem::take(thumb_data);
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
    // add_to_history may have rewritten the restored entry's id on dedup
    // (preserving the re-captured duplicate's id); read the final id from the
    // head so Swift's last_restored_id points at the entry actually restored.
    let restored_id = hist.first().map_or(0, ClipboardEntry::entry_id);
    drop(hist);

    // Record the restored entry ID so Swift can find it in the snapshot
    // even if the monitor thread inserted new content at position 0.
    b.last_restored_id.store(restored_id, Ordering::SeqCst);

    1
}

/// Returns 1 if there's at least one entry in the undo stack, 0 otherwise.
#[no_mangle]
pub extern "C" fn clipboard_can_undo() -> c_int {
    match try_backend() {
        Some(b) => c_int::from(!b.deleted_stack.lock().unwrap().is_empty()),
        None => 0,
    }
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

/// Trim the oldest N percent of entries from both in-memory history and DB.
/// Returns the number of entries removed.
/// Deletes from DB first, then memory — so a DB failure leaves memory intact.
#[no_mangle]
pub extern "C" fn clipboard_trim_oldest_percent(percent: i32) -> c_int {
    let b = match try_backend() {
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
