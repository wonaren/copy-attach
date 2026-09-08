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
                    // back: these blobs sit in the undo stack (long-lived).
                    crate::backend::claim_pages(png.as_ptr(), png.capacity());
                    crate::backend::claim_pages(thumb.as_ptr(), thumb.capacity());
                    *thumb_width = tw as u32;
                    *thumb_height = th as u32;
                    undo_image = Some(crate::backend::MarkImageBlobsReusableOnDrop { png, thumb });
                }
                Err(e) => {
                    crate::error_log!("CopyAttach: failed to load image data from DB for undo: {e}");
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
            crate::error_log!("CopyAttach: failed to delete entry {entry_id} from DB: {e}");
            remove_undo_payload_file(&crate::backend::DeletedStackEntry {
                entry: entry.clone(),
                payload_path,
                payload_bytes,
            });
            return 0;
        }
    }

    // Step 5: DB delete succeeded. Now remove from history.
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| match e {
            ClipboardEntry::Text { id, .. } => *id != entry_id,
            ClipboardEntry::Image { id, .. } => *id != entry_id,
        });
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
                crate::error_log!("CopyAttach: failed to trim DB by {count} entries: {e}");
            }
        }
        Err(e) => {
            crate::error_log!("CopyAttach: DB mutex poisoned in trim_oldest_percent: {e}");
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
