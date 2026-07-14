//! In-memory clipboard history — dedup, ordering, and threshold-based eviction.

use crate::types::ClipboardEntry;

/// Insert `item` at the head of the history Vec and remove any duplicate
/// entries of the same type (matching text for text entries, hash for images).
/// Returns the updated Vec (the caller must assign it back to the history slot).
pub(crate) fn add_to_history(
    mut history: Vec<ClipboardEntry>,
    item: ClipboardEntry,
) -> Vec<ClipboardEntry> {
    match &item {
        ClipboardEntry::Text { text, .. } => {
            history.retain(|e| match e {
                ClipboardEntry::Text { text: t, .. } => t != text,
                _ => true,
            });
        }
        ClipboardEntry::Image { hash, .. } => {
            history.retain(|e| match e {
                ClipboardEntry::Image { hash: h, .. } => h != hash,
                _ => true,
            });
        }
    }
    history.insert(0, item);
    history
}
