// History ordering and dedup tests — `add_to_history` semantics.

use crate::history::{add_to_history, assign_db_id_by_text_hash, remove_deleted_entry};
use crate::types::ClipboardEntry;
use super::{make_image, make_test_image_rgba, make_text};

#[test]
fn test_add_text_item() {
    let history = vec![];
    let item = make_text("hello world", 100);
    let result = add_to_history(history, item);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].label(), "hello world");
}

#[test]
fn test_text_deduplication() {
    let history = vec![make_text("duplicate", 100)];
    let item = make_text("duplicate", 200);
    let result = add_to_history(history, item);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Text { timestamp, .. } = &result[0] {
        assert_eq!(*timestamp, 200);
    }
}

#[test]
fn test_text_and_image_mixed() {
    let history = vec![];
    let t1 = make_text("text1", 100);
    let img_data = make_test_image_rgba(10, 10, 128);
    let i1 = make_image(&img_data, 10, 10, 200);
    let history = add_to_history(history, t1);
    let history = add_to_history(history, i1);
    assert_eq!(history.len(), 2);
    assert!(matches!(history[0], ClipboardEntry::Image { .. }));
    assert!(matches!(history[1], ClipboardEntry::Text { .. }));
}

#[test]
fn test_image_deduplication() {
    let img_data = make_test_image_rgba(8, 8, 200);
    let img1 = make_image(&img_data, 8, 8, 100);
    let img2 = make_image(&img_data, 8, 8, 200);
    let history = vec![img1];
    let result = add_to_history(history, img2);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Image { timestamp, .. } = &result[0] {
        assert_eq!(*timestamp, 200);
    }
}

#[test]
fn test_add_multiple_items_order() {
    let history = vec![];
    let items = ["c", "b", "a"];
    let mut history = history;
    for (i, &s) in items.iter().enumerate() {
        history = add_to_history(history, make_text(s, i as u64));
    }
    assert_eq!(history.len(), 3);
    assert_eq!(history[0].label(), "a");
}

#[test]
fn test_in_memory_order_newest_first() {
    let mut hist = Vec::new();
    for i in 0..5 {
        hist = add_to_history(hist, make_text(&format!("item-{}", i), i as u64));
    }
    assert_eq!(hist.len(), 5);
    assert_eq!(hist[0].label(), "item-4");
    assert_eq!(hist[4].label(), "item-0");
}

/// Regression test for the ghost-entry bug: the monitor's text capture
/// assigns the freshly inserted SQLite rowid by content hash, NEVER by head
/// position. A concurrent select-and-paste may have moved another entry to
/// position 0 between the in-memory insert and the DB write-through; writing
/// the rowid into that head entry would orphan the captured one (db_id=0 —
/// unpasteable, undeletable, still listed) and point the head entry at a
/// row that a later delete would remove from under it.
#[test]
fn test_assign_db_id_by_text_hash_ignores_head_position() {
    // Simulate: captured entry "功能验证文本" sits at index 1 (db_id=0, its
    // DB write is in flight) while a concurrent paste moved "other" to the
    // head. The DB insert completed with rowid 42.
    let mut hist = Vec::new();
    let pasted = make_text("other-content", 300);
    let captured = make_text("功能验证文本", 200);
    hist = add_to_history(hist, pasted);
    hist = add_to_history(hist, captured);

    let captured_hash = match &hist[1] {
        ClipboardEntry::Text { text_hash, .. } => *text_hash,
        _ => unreachable!(),
    };

    assign_db_id_by_text_hash(&mut hist, captured_hash, 42);

    // The captured entry (index 1) gets the rowid; the head entry is untouched.
    match &hist[0] {
        ClipboardEntry::Text { db_id, .. } => assert_eq!(*db_id, 0, "head entry must not receive the rowid"),
        _ => unreachable!(),
    }
    match &hist[1] {
        ClipboardEntry::Text { db_id, .. } => assert_eq!(*db_id, 42, "captured entry must receive its rowid"),
        _ => unreachable!(),
    }
}

/// Same as above but the captured entry sits at the head (the common no-race
/// case) — assignment must still work.
#[test]
fn test_assign_db_id_by_text_hash_at_head() {
    let mut hist = Vec::new();
    let captured = make_text("capture-race", 100);
    hist = add_to_history(hist, captured);

    let captured_hash = match &hist[0] {
        ClipboardEntry::Text { text_hash, .. } => *text_hash,
        _ => unreachable!(),
    };

    assign_db_id_by_text_hash(&mut hist, captured_hash, 7);
    match &hist[0] {
        ClipboardEntry::Text { db_id, .. } => assert_eq!(*db_id, 7),
        _ => unreachable!(),
    }
}

/// A stale rowid must not be assigned to an unrelated entry (defensive: hash
/// never matches ⇒ nothing changes).
#[test]
fn test_assign_db_id_by_text_hash_no_match_is_noop() {
    let mut hist = Vec::new();
    hist = add_to_history(hist, make_text("unrelated", 100));
    assign_db_id_by_text_hash(&mut hist, 0xDEADBEEF, 99);
    match &hist[0] {
        ClipboardEntry::Text { db_id, .. } => assert_eq!(*db_id, 0),
        _ => unreachable!(),
    }
}

/// Locks the persisted hash algorithm: FNV-1a 64-bit, fixed constants. The
/// text_hash value is stored in SQLite (the `hash` column) — changing the
/// algorithm would orphan every persisted hash in user DBs, so these are the
/// published FNV-1a test vectors as a tripwire, not incidental assertions.
#[test]
fn test_text_hash_is_stable_fnv1a() {
    assert_eq!(crate::types::text_hash(""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(crate::types::text_hash("a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(crate::types::text_hash("foobar"), 0x8594_4171_f739_67e8);
}

#[test]
fn test_add_to_history_preserves_custom_label_on_recapture() {
    let mut hist = Vec::new();
    let mut entry1 = make_text("api-key-secret-12345", 100);
    let original_id = entry1.entry_id();
    if let ClipboardEntry::Text { ref mut custom_label, .. } = entry1 {
        *custom_label = "Production API Key".to_string();
    }
    hist = add_to_history(hist, entry1);
    assert_eq!(hist[0].custom_label(), "Production API Key");
    assert_eq!(hist[0].entry_id(), original_id);

    // Re-capturing the identical text later (fresh entry, no custom_label initially)
    let entry2 = make_text("api-key-secret-12345", 200);
    let new_id = entry2.entry_id();
    assert_ne!(original_id, new_id);

    hist = add_to_history(hist, entry2);
    assert_eq!(hist.len(), 1, "deduplicated to 1 entry");
    assert_eq!(hist[0].entry_id(), original_id, "preserved original stable ID");
    assert_eq!(hist[0].custom_label(), "Production API Key", "preserved custom label across re-capture");
}

/// Regression for the delete/recapture collision: a capture landing between
/// the DB delete and the in-memory removal adopts the deleted entry's stable
/// id (add_to_history preserves it). Removing by entry_id alone would delete
/// that fresh capture too — it vanishes from the list while its row stays
/// behind as an orphan. Identity is (entry_id, db_id): the deleted row pins
/// the entry that was actually deleted, the re-capture points at a new row.
#[test]
fn test_remove_deleted_entry_keeps_concurrent_recapture() {
    let mut hist = Vec::new();
    let mut deleted = make_text("delete-me", 100);
    if let ClipboardEntry::Text { db_id, .. } = &mut deleted {
        *db_id = 7;
    }
    let deleted_id = deleted.entry_id();
    hist = add_to_history(hist, deleted);

    // The delete already removed row 7; the concurrent re-capture preserved
    // the id but was assigned row 42.
    let mut recaptured = make_text("delete-me", 200);
    if let ClipboardEntry::Text { id, db_id, .. } = &mut recaptured {
        *id = deleted_id;
        *db_id = 42;
    }
    hist = add_to_history(hist, recaptured);
    assert_eq!(hist.len(), 1);

    remove_deleted_entry(&mut hist, deleted_id, 7);

    assert_eq!(hist.len(), 1, "the fresh capture must survive the delete");
    assert_eq!(hist[0].db_id(), 42);
}

/// The plain case: the entry still points at the deleted row, so it is removed.
#[test]
fn test_remove_deleted_entry_removes_the_deleted_row() {
    let mut hist = Vec::new();
    let mut entry = make_text("delete-me", 100);
    if let ClipboardEntry::Text { db_id, .. } = &mut entry {
        *db_id = 7;
    }
    let id = entry.entry_id();
    hist = add_to_history(hist, entry);

    remove_deleted_entry(&mut hist, id, 7);

    assert!(hist.is_empty(), "the entry pointing at the deleted row goes");
}

/// A stale call must never touch a neighbouring entry.
#[test]
fn test_remove_deleted_entry_no_match_is_noop() {
    let mut hist = Vec::new();
    let mut entry = make_text("keep-me", 100);
    if let ClipboardEntry::Text { db_id, .. } = &mut entry {
        *db_id = 7;
    }
    hist = add_to_history(hist, entry);
    let id = hist[0].entry_id();

    remove_deleted_entry(&mut hist, id, 999);

    assert_eq!(hist.len(), 1);
    assert_eq!(hist[0].db_id(), 7);
}

#[test]
fn test_text_capture_predicate_allows_single_char_and_rejects_pure_whitespace() {
    let rules = crate::ignore::IgnoreRules::default();

    // Helper mirroring monitor.rs capture guard:
    // !trimmed.is_empty() && !rules.ignores_text(text)
    let should_capture = |text: &str| -> bool {
        let trimmed = text.trim();
        !trimmed.is_empty() && !rules.ignores_text(text)
    };

    assert!(should_capture("a"), "single ASCII char must be captured by default");
    assert!(should_capture("1"), "single digit must be captured by default");
    assert!(should_capture("中"), "single CJK char must be captured by default");
    assert!(should_capture(" a "), "padded single char must be captured");

    assert!(!should_capture(""), "empty text must not be captured");
    assert!(!should_capture("   "), "whitespace-only text must not be captured");
    assert!(!should_capture("\n\t  \r\n"), "mixed whitespace must not be captured");
}

