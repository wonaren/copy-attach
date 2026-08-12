// History ordering and dedup tests — `add_to_history` semantics.

use crate::history::{add_to_history, assign_db_id_by_text_hash};
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
