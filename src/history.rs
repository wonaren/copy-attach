//! In-memory clipboard history — dedup, ordering, and threshold-based eviction.

use crate::types::ClipboardEntry;

/// Insert `item` at the head of the history Vec and remove any duplicate
/// entries of the same type (matching text for text entries, hash for images).
/// Preserves the old entry's stable ID on dedup so Swift-side favorites
/// (stored by entry_id) survive background re-capture.
/// Returns the updated Vec (the caller must assign it back to the history slot).
pub(crate) fn add_to_history(
    mut history: Vec<ClipboardEntry>,
    mut item: ClipboardEntry,
) -> Vec<ClipboardEntry> {
    let preserved_id = match &item {
        ClipboardEntry::Text { text, .. } => {
            let old_id = history.iter().find_map(|e| match e {
                ClipboardEntry::Text { text: t, id, .. } if t == text => Some(*id),
                _ => None,
            });
            history.retain(|e| match e {
                ClipboardEntry::Text { text: t, .. } => t != text,
                _ => true,
            });
            old_id
        }
        ClipboardEntry::Image { hash, .. } => {
            let old_id = history.iter().find_map(|e| match e {
                ClipboardEntry::Image { hash: h, id, .. } if h == hash => Some(*id),
                _ => None,
            });
            history.retain(|e| match e {
                ClipboardEntry::Image { hash: h, .. } => h != hash,
                _ => true,
            });
            old_id
        }
    };
    if let Some(old_id) = preserved_id {
        match &mut item {
            ClipboardEntry::Text { id, .. } => *id = old_id,
            ClipboardEntry::Image { id, .. } => *id = old_id,
        }
    }
    history.insert(0, item);
    history
}
