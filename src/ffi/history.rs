use std::collections::HashSet;
use std::ffi::{c_char, c_int, CStr};
use std::sync::atomic::Ordering;

use crate::backend::{push_deleted, remove_undo_payload_file, try_backend, UndoPayload};
use crate::db::{insert_entry_to_db, load_text_by_db_id};
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
    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned clearing history: {e}");
            return 0;
        }
    };
    if let Err(e) = conn.execute("DELETE FROM clipboard_history", []) {
        crate::error_log!("CopyAttach: failed to clear DB history: {e}");
        return 0;
    }
    drop(conn);

    // DB clear succeeded: now clear the in-memory history and release the
    // undo stack (materialized payload files removed with their slots).
    let mut hist = b.history.lock().unwrap();
    hist.clear();
    // Publish under the history lock so the emptied list is observed atomically.
    crate::backend::mark_history_changed();
    let mut stack = b.deleted_stack.lock().unwrap();
    for slot in stack.iter() {
        remove_undo_payload_file(slot);
    }
    stack.clear();
    1
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
    // The entry's full identity: a concurrent re-capture preserves entry_id but
    // gets a different row, so the removal below must match both (Step 5).
    let target_db_id = entry.db_id();

    // Step 2: Load full content for undo BEFORE the DB delete removes it.
    // Text bodies live only in SQLite (the in-memory entry carries just a
    // preview), so they are loaded here and stashed for the undo stack. A text
    // entry with db_id=0 was never persisted and has no restorable body —
    // reject deletion explicitly, matching the image Phase 2 guard below.
    let mut undo_text: Option<String> = None;
    if let ClipboardEntry::Text { db_id, .. } = &entry {
        if *db_id == 0 {
            crate::error_log!("CopyAttach: cannot delete text entry {entry_id}: db_id=0 (entry not persisted)");
            return 0;
        }
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB lock poisoned loading text for undo of entry {entry_id}: {e}");
                return 0;
            }
        };
        match load_text_by_db_id(&conn, *db_id) {
            Some(t) => undo_text = Some(t),
            None => {
                crate::error_log!("CopyAttach: failed to load text for undo of entry {entry_id} — delete aborted");
                return 0;
            }
        }
    }

    // For image entries, load full data from DB before removal.
    // If loading fails (Phase 2 not done, DB error), reject deletion entirely.
    let mut undo_image: Option<crate::backend::MarkImageBlobsReusableOnDrop> = None;
    if let ClipboardEntry::Image { db_id, thumb_width, thumb_height, .. } = &mut entry {
        if *db_id != 0 {
            let conn = match b.db.lock() {
                Ok(c) => c,
                Err(e) => {
                    crate::error_log!("CopyAttach: DB lock poisoned loading image for undo: {e}");
                    return 0;
                }
            };
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
                    // back: these blobs are written into the undo payload file.
                    // An unclaimable blob could be zeroed mid-write, so the
                    // delete is refused (the entry stays listed and retryable).
                    if !crate::backend::claim_pages(png.as_ptr(), png.capacity())
                        || !crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity())
                    {
                        crate::error_log!("CopyAttach: image blobs for entry {entry_id} could not be claimed — delete aborted");
                        return 0;
                    }
                    *thumb_width = tw as u32;
                    *thumb_height = th as u32;
                    undo_image = Some(crate::backend::MarkImageBlobsReusableOnDrop { png, thumb });
                }
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to load image data from DB for undo (entry {entry_id}, db_id={db_id}): {e}");
                    return 0;
                }
            }
        } else {
            // Phase 2 async persist has not completed — no image data exists in DB.
            // Reject deletion: the entry stays in history, user can retry later.
            crate::error_log!("CopyAttach: cannot delete image entry {entry_id}: Phase 2 not yet complete (db_id=0)");
            return 0;
        }
    }

    // Step 3: Materialize the payload to disk before the DB delete removes it.
    // On success the in-memory blobs/body are released immediately; the undo
    // stack keeps only metadata + the file path.
    let image_slices = undo_image.as_ref().map(|b| (b.png.as_slice(), b.thumb.as_slice()));
    let (payload_path, payload_bytes) =
        match crate::backend::write_undo_payload(&entry, undo_text.as_deref(), image_slices) {
            Ok(v) => v,
            Err(()) => {
                crate::error_log!("CopyAttach: failed to materialize undo payload for entry {entry_id} — delete aborted");
                return 0;
            }
        };
    crate::debug_log!("CopyAttach: delete payload_path={} payload_bytes={payload_bytes}", payload_path.display());

    // Release the in-memory payload now that it is safely on disk. Both the
    // text body and the image blobs were claimed when loaded, so mark their
    // pages reusable before they drop.
    if let Some(t) = undo_text.take() {
        crate::backend::mark_pages_reusable(t.as_ptr(), t.capacity());
    }
    drop(undo_image);

    // Step 4: Delete from DB. If this fails, remove the materialized payload
    // and leave the history entry intact.
    {
        let conn = match b.db.lock() {
            Ok(c) => c,
            Err(e) => {
                crate::error_log!("CopyAttach: DB lock poisoned deleting entry {entry_id}: {e}");
                remove_undo_payload_file(&crate::backend::DeletedStackEntry {
                    entry: entry.clone(),
                    payload_path,
                    payload_bytes,
                });
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
            ClipboardEntry::Image { db_id, .. } => {
                // Step 2 rejected unpersisted images (db_id=0) up front, so this
                // is always the rowid delete.
                conn.execute(
                    "DELETE FROM clipboard_history WHERE id = ?1",
                    rusqlite::params![*db_id],
                )
            }
        } {
            crate::error_log!("CopyAttach: failed to delete entry {entry_id} from DB: {e}");
            remove_undo_payload_file(&crate::backend::DeletedStackEntry {
                entry: entry.clone(),
                payload_path,
                payload_bytes,
            });
            return 0;
        }
    }

    // Step 5: DB delete succeeded. Remove exactly the entry whose row was
    // deleted — by identity, never by entry_id alone (see
    // history::remove_deleted_entry).
    {
        let mut hist = b.history.lock().unwrap();
        crate::history::remove_deleted_entry(&mut hist, entry_id, target_db_id);
        // Publish under the history lock: delete mutates and notifies atomically.
        crate::backend::mark_history_changed();
    }

    // Step 6: Push the metadata-only slot (with its on-disk payload) onto the
    // undo stack, under the entry count and total-bytes caps. The entry is
    // moved, not cloned.
    {
        let mut stack = b.deleted_stack.lock().unwrap();
        push_deleted(&mut stack, crate::backend::DeletedStackEntry {
            entry,
            payload_path,
            payload_bytes,
        });
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

    let slot = {
        let mut stack = b.deleted_stack.lock().unwrap();
        match stack.pop() {
            Some(e) => e,
            None => return 0,
        }
    };

    // Read the materialized payload back from disk. On failure the slot (with
    // its file still in place) is re-pushed so the user can retry.
    let payload = match crate::backend::read_undo_payload(&slot.payload_path) {
        Ok(p) => p,
        Err(()) => {
            crate::error_log!("CopyAttach: failed to read undo payload for entry {} — keeping undo slot", slot.entry.entry_id());
            let mut stack = b.deleted_stack.lock().unwrap();
            stack.push(slot);
            return 0;
        }
    };

    // Clone the metadata (small) so `slot` stays intact for the retry path.
    let mut entry = slot.entry.clone();

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

    let conn = match b.db.lock() {
        Ok(c) => c,
        Err(e) => {
            crate::error_log!("CopyAttach: DB lock poisoned during undo: {e}");
            let mut stack = b.deleted_stack.lock().unwrap();
            stack.push(slot);
            return 0;
        }
    };

    let insert_result = match &payload {
        UndoPayload::Text(body) => {
            insert_entry_to_db(&conn, &entry, Some(body), None, None)
        }
        UndoPayload::Image { png, thumb } => {
            let (tw, th) = match &entry {
                ClipboardEntry::Image { thumb_width, thumb_height, .. } => (*thumb_width, *thumb_height),
                _ => (0, 0),
            };
            insert_entry_to_db(&conn, &entry, None, Some(png), Some((thumb, tw, th)))
        }
    };

    // Must succeed: without DB write, image entries can't store their data
    // and text entries would lack db_id. Re-push the slot (the payload file is
    // still on disk) so the user can retry.
    if insert_result.is_err() {
        let mut stack = b.deleted_stack.lock().unwrap();
        stack.push(slot);
        // The read-back payload is transient and claimed; release its pages.
        match &payload {
            UndoPayload::Text(body) => {
                crate::backend::mark_pages_reusable(body.as_ptr(), body.capacity());
            }
            UndoPayload::Image { png, thumb } => {
                crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
                crate::backend::mark_pages_reusable(thumb.as_ptr(), thumb.capacity());
            }
        }
        return 0;
    }
    let new_row_id = conn.last_insert_rowid();

    // The payload now lives in the new DB row. Remove the materialized file
    // (a failure here only leaks a temp file; startup purges stale files) and
    // update the in-memory entry to metadata-only before it lands in history.
    remove_undo_payload_file(&slot);
    match &mut entry {
        ClipboardEntry::Text { ref mut db_id, .. } => *db_id = new_row_id,
        ClipboardEntry::Image { ref mut db_id, .. } => {
            *db_id = new_row_id;
        }
    }

    // Release the read-back payload: it was claimed by `read_undo_payload` and
    // is no longer needed after the DB insert above.
    match &payload {
        UndoPayload::Text(body) => {
            crate::backend::mark_pages_reusable(body.as_ptr(), body.capacity());
        }
        UndoPayload::Image { png, thumb } => {
            crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
            crate::backend::mark_pages_reusable(thumb.as_ptr(), thumb.capacity());
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
    // Publish under the history lock (undo replaced the head / deduped).
    crate::backend::mark_history_changed();
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

/// Trim the oldest N percent of entries from both DB and in-memory history.
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
/// Trim the oldest N percent of entries from history and DB, preserving any
/// entries referenced by `favorite_ids_str`.
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
pub extern "C" fn clipboard_trim_oldest_percent(
    percent: i32,
    favorite_ids_str: *const c_char,
) -> c_int {
    let b = match try_backend() {
        Some(b) => b,
        None => return 0,
    };

    if percent <= 0 {
        return 0;
    }

    let fav_set: HashSet<u64> = super::parse_ids_set(favorite_ids_str);

    let count = {
        let hist = b.history.lock().unwrap();
        let cleanable_total = hist
            .iter()
            .filter(|e| !fav_set.contains(&e.entry_id()))
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

    // Step 1: delete the oldest rows from DB, excluding any rows in fav_set.
    // Resolving exactly which row ids go away. A failure leaves memory — and the durable
    // state — untouched. "Oldest" is by `(timestamp, id)`, the same order the list uses:
    // trimming by rowid instead would evict the user's own newer rows first whenever the
    // table holds rows inserted out of chronological order (a merge).
    let deleted_ids: HashSet<i64> = match b.db.lock() {
        Ok(conn) => {
            let mut stmt = match conn.prepare(
                "SELECT id, entry_id FROM clipboard_history ORDER BY timestamp ASC, id ASC",
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
                let entry_id: i64 = match row.get(1) {
                    Ok(id) => id,
                    Err(_) => continue,
                };
                if !fav_set.contains(&(entry_id as u64)) {
                    ids.push(db_id);
                    if ids.len() >= count {
                        break;
                    }
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
                let sql = format!("DELETE FROM clipboard_history WHERE id IN ({placeholders})");
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
    // the DELETE did not remove keep their rows and must stay listed.
    // Favorites are preserved both in DB and memory.
    let actual = {
        let mut hist = b.history.lock().unwrap();
        let before = hist.len();
        hist.retain(|e| !deleted_ids.contains(&e.db_id()) || fav_set.contains(&e.entry_id()));
        let removed = before - hist.len();
        // Publish under the history lock (entries were removed).
        crate::backend::mark_history_changed();
        removed
    };

    actual as c_int
}
