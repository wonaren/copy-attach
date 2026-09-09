//! In-memory clipboard history — dedup, ordering, and threshold-based eviction.

use crate::types::ClipboardEntry;

/// Insert `item` at the head of the history Vec and remove any duplicate
/// entries of the same type (matching text hash for text entries, hash for
/// images). Preserves the old entry's stable ID and custom label on dedup so
/// Swift-side favorites and user-defined remarks survive background re-capture.
/// Returns the updated Vec (the caller must assign it back to the history slot).
pub(crate) fn add_to_history(
    mut history: Vec<ClipboardEntry>,
    mut item: ClipboardEntry,
) -> Vec<ClipboardEntry> {
    let (preserved_id, preserved_label) = match &item {
        ClipboardEntry::Text { text_hash, .. } => {
            let old = history.iter().find_map(|e| match e {
                ClipboardEntry::Text { text_hash: h, id, custom_label, .. } if h == text_hash => {
                    Some((*id, custom_label.clone()))
                }
                _ => None,
            });
            history.retain(|e| match e {
                ClipboardEntry::Text { text_hash: h, .. } => h != text_hash,
                _ => true,
            });
            (old.as_ref().map(|(id, _)| *id), old.map(|(_, l)| l))
        }
        ClipboardEntry::Image { hash, .. } => {
            let old = history.iter().find_map(|e| match e {
                ClipboardEntry::Image { hash: h, id, custom_label, .. } if h == hash => {
                    Some((*id, custom_label.clone()))
                }
                _ => None,
            });
            history.retain(|e| match e {
                ClipboardEntry::Image { hash: h, .. } => h != hash,
                _ => true,
            });
            (old.as_ref().map(|(id, _)| *id), old.map(|(_, l)| l))
        }
    };
    if let Some(old_id) = preserved_id {
        match &mut item {
            ClipboardEntry::Text { id, .. } => *id = old_id,
            ClipboardEntry::Image { id, .. } => *id = old_id,
        }
    }
    if let Some(old_label) = preserved_label {
        if !old_label.is_empty() {
            match &mut item {
                ClipboardEntry::Text { custom_label, .. } => *custom_label = old_label,
                ClipboardEntry::Image { custom_label, .. } => *custom_label = old_label,
            }
        }
    }
    history.insert(0, item);
    history
}

/// Assign a freshly inserted SQLite rowid to the text entry whose content
/// hash matches, wherever it sits in the list. Never assigns by head
/// position: a concurrent select-and-paste (or undo) may have moved another
/// entry to the front between the in-memory insert and the DB write-through.
/// Writing our rowid into that head entry would orphan the captured one
/// (db_id=0 forever — unpasteable, undeletable) while pointing the other at
/// a row that a later delete would remove from under it.
///
/// Mirrors the image Phase 2 assignment in the monitor, which matches by
/// content hash; this is its text twin.
pub(crate) fn assign_db_id_by_text_hash(
    history: &mut [ClipboardEntry],
    text_hash: u64,
    row_id: i64,
) {
    for entry in history.iter_mut() {
        if let ClipboardEntry::Text { text_hash: h, db_id, .. } = entry {
            if *h == text_hash {
                *db_id = row_id;
                break;
            }
        }
    }
}

/// Remove exactly the entry whose DB row a delete just removed, identified by
/// entry_id AND db_id.
///
/// entry_id alone is not identity: add_to_history preserves a re-captured
/// entry's stable id, so a capture landing between the DB delete and this
/// removal adopts the deleted entry's id. Removing by id alone would delete
/// that fresh capture too — it disappears from the list while its row stays
/// behind as an orphan (until a later same-content dedup or a restart).
/// The deleted row's id pins the entry that was actually deleted; the
/// re-capture already points at a different (newer) row.
pub(crate) fn remove_deleted_entry(
    history: &mut Vec<ClipboardEntry>,
    entry_id: u64,
    db_id: i64,
) {
    history.retain(|e| !(e.entry_id() == entry_id && e.db_id() == db_id));
}
