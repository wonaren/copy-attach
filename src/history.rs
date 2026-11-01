use crate::types::ClipboardEntry;

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

pub(crate) fn remove_deleted_entry(
    history: &mut Vec<ClipboardEntry>,
    entry_id: u64,
    db_id: i64,
) {
    history.retain(|e| !(e.entry_id() == entry_id && e.db_id() == db_id));
}
