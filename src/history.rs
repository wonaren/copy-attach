use crate::types::ClipboardEntry;

pub(crate) fn preserve_history_identity(history: &[ClipboardEntry], item: &mut ClipboardEntry) {
    let Some(previous) = history.iter().find(|entry| same_content(entry, item)) else { return };
    match item {
        ClipboardEntry::Text { id, custom_label, .. } |
        ClipboardEntry::Image { id, custom_label, .. } => {
            *id = previous.entry_id();
            if !previous.custom_label().is_empty() {
                *custom_label = previous.custom_label().to_owned();
            }
        }
    }
}

fn same_content(left: &ClipboardEntry, right: &ClipboardEntry) -> bool {
    match (left, right) {
        (ClipboardEntry::Text { text_hash: a, .. }, ClipboardEntry::Text { text_hash: b, .. }) |
        (ClipboardEntry::Image { hash: a, .. }, ClipboardEntry::Image { hash: b, .. }) => a == b,
        _ => false,
    }
}

#[cfg(test)]
pub(crate) fn add_to_history(mut history: Vec<ClipboardEntry>, mut item: ClipboardEntry) -> Vec<ClipboardEntry> {
    preserve_history_identity(&history, &mut item);
    history.retain(|entry| !same_content(entry, &item));
    history.insert(0, item);
    history
}

pub(crate) fn is_pending_image(entry: &ClipboardEntry) -> bool {
    matches!(entry, ClipboardEntry::Image { db_id: 0, .. })
}

pub(crate) fn visible_history(history: &[ClipboardEntry]) -> &[ClipboardEntry] {
    let end = history.iter().rposition(|entry| !is_pending_image(entry)).map_or(0, |index| index + 1);
    &history[..end]
}

pub(crate) fn publish_persisted_entry(
    history: &mut Vec<ClipboardEntry>,
    mut item: ClipboardEntry,
    row_id: i64,
    removed: &std::collections::HashSet<i64>,
) {
    history.retain(|entry| !removed.contains(&entry.db_id()));
    if removed.contains(&row_id) {
        return;
    }
    match &mut item {
        ClipboardEntry::Text { db_id, .. } | ClipboardEntry::Image { db_id, .. } => *db_id = row_id,
    }
    let key = (item.timestamp(), row_id);
    let index = visible_history(history).partition_point(|entry| (entry.timestamp(), entry.db_id()) > key);
    history.insert(index, item);
}

pub(crate) fn remove_deleted_entry(history: &mut Vec<ClipboardEntry>, db_id: i64) {
    history.retain(|e| e.db_id() != db_id);
}
