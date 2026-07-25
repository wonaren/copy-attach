//! Unit tests for clipboard history management and image processing.
//!
//! ⚠️  Benchmarks are in bench_tests.rs, run with `cargo test --features stress-test`.

use crate::types::ClipboardEntry;
use crate::image::{encode_png, decode_png, create_thumbnail, image_hash};
use crate::history::add_to_history;
use crate::backend::new_entry_id;
use crate::ffi::clipboard_free_string;
use rusqlite::Connection;

fn make_text(text: &str, ts: u64) -> ClipboardEntry {
    ClipboardEntry::Text {
        id: new_entry_id(),
        text: text.to_string(),
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    }
}

fn make_image(data: &[u8], w: u32, h: u32, ts: u64) -> ClipboardEntry {
    let hash = image_hash(data, w, h);
    let png = encode_png(w, h, data).unwrap();
    let thumb = create_thumbnail(w, h, data, 100).unwrap();
    ClipboardEntry::Image {
        id: new_entry_id(),
        png_data: png,
        width: w,
        height: h,
        thumb_data: thumb.0,
        thumb_width: thumb.1,
        thumb_height: thumb.2,
        hash,
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    }
}

fn make_test_image_rgba(w: u32, h: u32, fill_byte: u8) -> Vec<u8> {
    vec![fill_byte; (w * h * 4) as usize]
}

// ═══════════════════════════════════════════
// Basic History Tests
// ═══════════════════════════════════════════

#[test]
fn test_add_text_item() {
    let history = vec![];
    let item = make_text("hello world", 100);
    let result = add_to_history(history, item);
    assert_eq!(result.len(), 1);
    if let ClipboardEntry::Text { text, .. } = &result[0] {
        assert_eq!(text, "hello world");
    } else { panic!("Expected Text entry"); }
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
    let items = vec!["c", "b", "a"];
    let mut history = history;
    for (i, &s) in items.iter().enumerate() {
        history = add_to_history(history, make_text(s, i as u64));
    }
    assert_eq!(history.len(), 3);
    if let ClipboardEntry::Text { text, .. } = &history[0] {
        assert_eq!(text, "a");
    }
}

// ═══════════════════════════════════════════
// Image Processing Tests
// ═══════════════════════════════════════════

#[test]
fn test_encode_decode_png() {
    let rgba = make_test_image_rgba(16, 16, 100);
    let png = encode_png(16, 16, &rgba).expect("encode should succeed");
    assert!(!png.is_empty());
    let (decoded, w, h) = decode_png(&png).expect("decode should succeed");
    assert_eq!(w, 16);
    assert_eq!(h, 16);
    assert_eq!(decoded.len(), 16 * 16 * 4);
}

#[test]
fn test_create_thumbnail() {
    let rgba = make_test_image_rgba(200, 100, 150);
    let thumb = create_thumbnail(200, 100, &rgba, 50);
    assert!(thumb.is_some());
    let (_, tw, th) = thumb.unwrap();
    assert!(tw <= 50 && th <= 50);
}

#[test]
fn test_image_hash_consistency() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 200);
    assert_eq!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

#[test]
fn test_image_hash_different() {
    let data1 = make_test_image_rgba(10, 10, 200);
    let data2 = make_test_image_rgba(10, 10, 100);
    assert_ne!(image_hash(&data1, 10, 10), image_hash(&data2, 10, 10));
}

// ═══════════════════════════════════════════
// Metadata Tests
// ═══════════════════════════════════════════

#[test]
fn test_source_app_fields() {
    let mut t = make_text("hello", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let mut i = make_image(&img_data, 5, 5, 2);
    if let ClipboardEntry::Text { ref mut source_name, ref mut source_bundle_id, .. } = t {
        *source_name = "Safari".into();
        *source_bundle_id = "com.apple.Safari".into();
    }
    if let ClipboardEntry::Image { ref mut source_name, ref mut source_bundle_id, .. } = i {
        *source_name = "Photos".into();
        *source_bundle_id = "com.apple.Photos".into();
    }
    assert_eq!(t.source_name(), "Safari");
    assert_eq!(t.source_bundle_id(), "com.apple.Safari");
    assert_eq!(i.source_name(), "Photos");
    assert_eq!(i.source_bundle_id(), "com.apple.Photos");
}

#[test]
fn test_item_types() {
    let t = make_text("test", 1);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2);
    assert_eq!(t.content_type(), 0);
    assert_eq!(i.content_type(), 1);
}

#[test]
fn test_item_timestamps() {
    let t = make_text("a", 1000);
    let img_data = make_test_image_rgba(5, 5, 50);
    let i = make_image(&img_data, 5, 5, 2000);
    assert_eq!(t.timestamp(), 1000);
    assert_eq!(i.timestamp(), 2000);
}

// ═══════════════════════════════════════════
// Label Tests
// ═══════════════════════════════════════════

#[test]
fn test_label_text() {
    let t = make_text("Hello World", 100);
    assert_eq!(t.label(), "Hello World");
}

#[test]
fn test_label_image() {
    let img_data = make_test_image_rgba(1920, 1080, 128);
    let i = make_image(&img_data, 1920, 1080, 100);
    assert_eq!(i.label(), "Image (1920×1080)");
}

#[test]
fn test_label_multibyte() {
    let cn = "这是一个测试中文文本用于验证标签截断功能是否正常工作";
    let t = make_text(cn, 100);
    let label = t.label();
    assert!(label.chars().count() <= 61);
    assert!(label.contains("这是一个"));
}

#[test]
fn test_free_string_null_safe() {
    clipboard_free_string(std::ptr::null_mut());
}

// ═══════════════════════════════════════════
// Auto-Cleanup Threshold Tests
// ═══════════════════════════════════════════

fn fill_and_trim_to(threshold: usize, count: usize) -> Vec<ClipboardEntry> {
    let mut hist = Vec::with_capacity(count);
    for i in 0..count {
        let item = make_text(&format!("item-{:04}", i), i as u64);
        hist = add_to_history(std::mem::take(&mut hist), item);
        while hist.len() > threshold {
            hist.pop();
        }
    }
    hist
}

#[test]
fn test_auto_cleanup_at_threshold_100() {
    let hist = fill_and_trim_to(100, 150);
    assert_eq!(hist.len(), 100);
}

#[test]
fn test_auto_cleanup_at_threshold_500() {
    let hist = fill_and_trim_to(500, 750);
    assert_eq!(hist.len(), 500);
}

#[test]
fn test_auto_cleanup_at_threshold_1000() {
    let hist = fill_and_trim_to(1000, 1500);
    assert_eq!(hist.len(), 1000);
}

#[test]
fn test_auto_cleanup_at_threshold_2000() {
    let hist = fill_and_trim_to(2000, 3000);
    assert_eq!(hist.len(), 2000);
}

#[test]
fn test_auto_cleanup_at_threshold_3000() {
    let hist = fill_and_trim_to(3000, 4500);
    assert_eq!(hist.len(), 3000);
}

#[test]
fn test_auto_cleanup_at_threshold_5000() {
    let hist = fill_and_trim_to(5000, 7500);
    assert_eq!(hist.len(), 5000);
}

#[test]
fn test_auto_cleanup_keeps_newest() {
    let hist = fill_and_trim_to(10, 50);
    assert_eq!(hist.len(), 10);
    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "item-0049");
    } else {
        panic!("Expected Text entry at head");
    }
}

#[test]
fn test_auto_cleanup_removes_oldest() {
    let hist = fill_and_trim_to(10, 50);
    if let ClipboardEntry::Text { text, .. } = &hist[9] {
        assert_eq!(text, "item-0040");
    } else {
        panic!("Expected Text entry at tail");
    }
}

#[test]
fn test_auto_cleanup_no_trim_below_threshold() {
    let hist = fill_and_trim_to(100, 50);
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_auto_cleanup_empty_history() {
    let hist = fill_and_trim_to(100, 0);
    assert!(hist.is_empty());
}

#[test]
fn test_auto_cleanup_exactly_at_threshold() {
    let hist = fill_and_trim_to(100, 100);
    assert_eq!(hist.len(), 100);
}

// ═══════════════════════════════════════════
// Trim-Oldest-Percent Tests
// ═══════════════════════════════════════════

fn simulate_trim_oldest_percent(
    mut hist: Vec<ClipboardEntry>, percent: usize,
) -> (Vec<ClipboardEntry>, Vec<ClipboardEntry>) {
    let total = hist.len();
    if total == 0 {
        return (hist, vec![]);
    }
    let count = ((total as f64 * percent as f64 / 100.0).ceil()) as usize;
    let count = count.min(total);
    let split_at = total - count;
    let removed = hist.split_off(split_at);
    (hist, removed)
}

#[test]
fn test_trim_percent_0() {
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 0);
    assert_eq!(kept.len(), 100);
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_100() {
    let hist: Vec<_> = (0..100).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 100);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 100);
}

#[test]
fn test_trim_percent_40() {
    let mut hist = Vec::new();
    for i in 0..100 {
        hist = add_to_history(hist, make_text(&format!("t-{:03}", i), i as u64));
    }
    assert_eq!(hist.len(), 100);
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 60);
    assert_eq!(removed.len(), 40);
    if let ClipboardEntry::Text { text, .. } = &kept[0] {
        assert_eq!(text, "t-099");
    }
    if let ClipboardEntry::Text { text, .. } = &removed[0] {
        assert_eq!(text, "t-039");
    }
}

#[test]
fn test_trim_percent_50_even() {
    let hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 50);
    assert_eq!(kept.len(), 25);
    assert_eq!(removed.len(), 25);
}

#[test]
fn test_trim_percent_ceil_small_count() {
    let hist: Vec<_> = (0..3).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    let (kept, removed) = simulate_trim_oldest_percent(hist, 40);
    assert_eq!(kept.len(), 1);
    assert_eq!(removed.len(), 2);
}

#[test]
fn test_trim_percent_empty() {
    let (kept, removed) = simulate_trim_oldest_percent(vec![], 40);
    assert!(kept.is_empty());
    assert!(removed.is_empty());
}

#[test]
fn test_trim_percent_ceil_single_entry() {
    let hist = vec![make_text("only", 0)];
    let (kept, removed) = simulate_trim_oldest_percent(hist, 1);
    assert!(kept.is_empty());
    assert_eq!(removed.len(), 1);
}

#[test]
fn test_trim_percent_all_thresholds_consistency() {
    for &threshold in &[100, 500, 1000, 2000, 3000, 5000] {
        let over = (threshold as f64 * 1.1) as usize;
        let mut hist = fill_and_trim_to(threshold, over);
        assert_eq!(hist.len(), threshold, "failed fill at threshold {}", threshold);
        let kept_count = threshold - ((threshold as f64 * 0.4).ceil()) as usize;
        let (kept, _) = simulate_trim_oldest_percent(hist, 40);
        assert_eq!(kept.len(), kept_count, "failed trim at threshold {}", threshold);
        hist = kept;
    }
}

// ═══════════════════════════════════════════
// Dynamic Threshold Change Tests
// ═══════════════════════════════════════════

#[test]
fn test_threshold_reduction_trims_history() {
    let mut hist: Vec<_> = (0..200).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    assert_eq!(hist.len(), 200);

    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 100);

    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "t-199");
    }
    if let ClipboardEntry::Text { text, .. } = &hist[99] {
        assert_eq!(text, "t-100");
    }
}

#[test]
fn test_threshold_increase_preserves_all() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 100usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert_eq!(hist.len(), 50);
}

#[test]
fn test_threshold_reduction_to_minimum() {
    let mut hist: Vec<_> = (0..50).map(|i| make_text(&format!("t-{}", i), i as u64)).collect();
    hist.reverse();
    let new_threshold = 0usize;
    while hist.len() > new_threshold {
        hist.pop();
    }
    assert!(hist.is_empty());
}

// ═══════════════════════════════════════════
// In-Memory History Layout Tests
// ═══════════════════════════════════════════

#[test]
fn test_in_memory_order_newest_first() {
    let mut hist = Vec::new();
    for i in 0..5 {
        hist = add_to_history(hist, make_text(&format!("item-{}", i), i as u64));
    }
    assert_eq!(hist.len(), 5);
    if let ClipboardEntry::Text { text, .. } = &hist[0] {
        assert_eq!(text, "item-4");
    }
    if let ClipboardEntry::Text { text, .. } = &hist[4] {
        assert_eq!(text, "item-0");
    }
}



// ═══════════════════════════════════════════
// Entry ID Persistence Tests
// ═══════════════════════════════════════════

use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db};
use crate::backend::prime_entry_id;

/// Helper: open an in-memory SQLite DB for testing.
fn test_db() -> Connection {
    let conn = Connection::open_in_memory().expect("failed to create in-memory DB");
    ensure_history_table(&conn).expect("failed to create table");
    conn
}

/// Helper: insert a text entry with known content and return its db_id.
fn insert_text(conn: &Connection, text: &str, ts: u64) -> i64 {
    let entry = ClipboardEntry::Text {
        id: new_entry_id(),
        text: text.to_string(),
        timestamp: ts,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    };
    insert_entry_to_db(conn, &entry, None, None).expect("insert failed");
    conn.last_insert_rowid()
}

#[test]
fn test_entry_id_persistence_and_restore() {
    // Use a file-backed DB to test cross-session ID stability.
    let db_path = std::env::temp_dir().join(format!(
        "copyattach_test_eid_{}.db", std::process::id()
    ));
    let _ = std::fs::remove_file(&db_path);

    // Simulate first launch: open DB, insert entries, reload and verify IDs.
    let conn = Connection::open(&db_path).expect("failed to open temp DB");
    ensure_history_table(&conn).expect("failed to create table");
    let _a = insert_text(&conn, "alpha", 100);
    let _b = insert_text(&conn, "beta", 200);
    let _c = insert_text(&conn, "gamma", 300);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 3, "should load all 3 entries");

    assert_eq!(loaded[0].text(), "gamma", "newest first");
    assert_eq!(loaded[1].text(), "beta");
    assert_eq!(loaded[2].text(), "alpha");

    let ids: Vec<u64> = loaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();
    assert!(ids[0] != 0, "entry_id must not be zero");
    assert_ne!(ids[0], ids[1], "entry IDs must be unique");
    assert_ne!(ids[1], ids[2], "entry IDs must be unique");

    // Simulate restart: close conn, open fresh, reload → IDs must match.
    drop(conn);

    // Reopen same DB file (simulates app restart).
    let conn = Connection::open(&db_path).expect("failed to reopen temp DB");
    ensure_history_table(&conn).expect("migration idempotent");
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 3, "same count after reload");

    let reloaded_ids: Vec<u64> = reloaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();
    assert_eq!(reloaded_ids, ids,
        "entry_ids must survive restart (reload must read from DB, not assign fresh)");

    let _ = std::fs::remove_file(&db_path);
}

#[test]
fn test_entry_id_stable_after_delete() {
    let conn = test_db();
    let _id_a = insert_text(&conn, "a", 100);
    let _id_b = insert_text(&conn, "b", 200);
    let _id_c = insert_text(&conn, "c", 300);

    let before = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let ids_before: Vec<u64> = before.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // Delete the middle entry ("b") via its db_id.
    // (Find db_id by matching text "b".)
    let db_id_b: i64 = {
        let mut stmt = conn.prepare(
            "SELECT id FROM clipboard_history WHERE entry_type = 0 AND text = 'b'"
        ).unwrap();
        stmt.query_row([], |row| row.get(0)).unwrap()
    };
    conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![db_id_b])
        .unwrap();

    let after = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(after.len(), 2, "one entry deleted");

    let ids_after: Vec<u64> = after.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // "c" (index 0) and "a" (index 1) must retain their original IDs.
    assert_eq!(ids_after[0], ids_before[0], "newest entry ID stable after delete");
    assert_eq!(ids_after[1], ids_before[2], "oldest entry ID stable after delete");
    assert_eq!(after[0].text(), "c", "newest preserved");
    assert_eq!(after[1].text(), "a", "oldest preserved");
}

#[test]
fn test_entry_id_monotonic_after_reload() {
    // Simulate full lifecycle: first session inserts, reloads, then inserts
    // more. New IDs must not collide with restored IDs.
    let conn = test_db();

    // First batch: 3 entries.
    let _a = insert_text(&conn, "first-batch-a", 100);
    let _b = insert_text(&conn, "first-batch-b", 200);
    let _c = insert_text(&conn, "first-batch-c", 300);

    // Simulate restart: reload, then prime the counter.
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let max_loaded = loaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).max().unwrap();
    prime_entry_id(max_loaded + 1);

    // Insert a new entry after restart — must get a fresh ID above all loaded.
    let new_id = new_entry_id();
    assert!(new_id > max_loaded,
        "new entry_id {} must be > max loaded ID {}", new_id, max_loaded);

    let entry_new = ClipboardEntry::Text {
        id: new_id,
        text: "post-restart".to_string(),
        timestamp: 999,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: 0,
    };
    insert_entry_to_db(&conn, &entry_new, None, None).unwrap();

    // Reload again — all 4 entries must have stable IDs.
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 4, "4 entries total after post-restart insert");

    let all_ids: Vec<u64> = reloaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    // The three original entries must retain their original IDs.
    for orig in &loaded {
        let orig_id = match orig {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(all_ids.contains(&orig_id),
            "original entry_id {} must survive restart", orig_id);
    }
    // The new entry must have its assigned ID.
    assert!(all_ids.contains(&new_id),
        "post-restart entry_id {} must be present", new_id);
}

#[test]
fn test_entry_id_backfill_old_rows() {
    // Simulate an old DB that was created before the entry_id column existed.
    // After ALTER TABLE + backfill, entry_id is set to the SQLite rowid.
    let conn = Connection::open_in_memory().expect("in-memory DB");
    conn.execute_batch(
        "CREATE TABLE clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_type      INTEGER NOT NULL,
            text            TEXT,
            png_data        BLOB,
            width           INTEGER,
            height          INTEGER,
            thumb_data      BLOB,
            thumb_width     INTEGER,
            thumb_height    INTEGER,
            hash            INTEGER,
            timestamp       INTEGER NOT NULL DEFAULT 0,
            source_name     TEXT NOT NULL DEFAULT '',
            source_bundle_id TEXT NOT NULL DEFAULT ''
        );"
    ).unwrap();
    // Insert rows WITHOUT entry_id column (old schema).
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp)
         VALUES (0, 'legacy-a', 100)",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp)
         VALUES (0, 'legacy-b', 200)",
        [],
    ).unwrap();

    // Now run the migration (add entry_id column + backfill).
    ensure_history_table(&conn).unwrap();

    // Load — both rows must have non-zero entry_ids.
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 2);
    for e in &loaded {
        let eid = match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(eid > 0, "backfilled entry_id must be non-zero, got {}", eid);
    }

    // Reload (simulate second restart) — IDs must be identical.
    let loaded2 = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    for (orig, reload) in loaded.iter().zip(loaded2.iter()) {
        let oid = match orig {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        let rid = match reload {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert_eq!(oid, rid, "legacy entry_id stable across restarts");
    }
}

#[test]
fn test_clipboard_delete_by_id_returns_zero_on_failure() {
    // Verify that clipboard_delete_by_id returns 0 (failure) when the entry
    // doesn't exist — proving the failure path that Finding 1 relies on.
    //
    // This path triggers in the Swift deleteItem(at:) flow when:
    //   1. deleteKeyNotification handler -> deleteItem(at: itemIndex)
    //   2. backend.deleteEntry(at:) calls clipboard_delete_by_id in Rust
    //   3. If this returns 0, deleteEntry returns false
    //   4. But searchResults.removeAll { $0.id == item.id } has already run

    use std::sync::{Arc, Mutex, atomic::{AtomicBool, AtomicU64, AtomicUsize}};
    use crate::backend::{Backend, set_backend};
    use crate::ffi::clipboard_delete_by_id;
    use crate::ignore::IgnoreRules;
    use crate::types::SourceApp;

    // Initialize the Backend singleton exactly once for all tests that need it.
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let conn = Connection::open_in_memory()
            .expect("in-memory DB for test");
        crate::db::ensure_history_table(&conn)
            .expect("schema creation");
        let backend = Backend {
            history: Arc::new(Mutex::new(Vec::new())),       // empty history
            running: Arc::new(AtomicBool::new(true)),
            monitor_handle: Mutex::new(None),
            source_app: Arc::new(Mutex::new(SourceApp::default())),
            last_seen_text: Arc::new(Mutex::new(None)),
            last_seen_image_hash: Arc::new(Mutex::new(None)),
            pasteboard_event_lock: Arc::new(Mutex::new(())),
            pending_self_write: Arc::new(Mutex::new(None)),
            db: Arc::new(Mutex::new(conn)),
            cleanup_threshold: Arc::new(AtomicUsize::new(3000)),
            ignore_rules: Arc::new(Mutex::new(IgnoreRules::default())),
            deleted_stack: Arc::new(Mutex::new(Vec::new())),
            last_restored_id: Arc::new(AtomicU64::new(0)),
            image_paste_use_ctrl_v: Arc::new(AtomicBool::new(false)),
        };
        set_backend(backend)
            .expect("Backend singleton must not be set before this test");
    });

    // Test 1: non-existent entry ID → returns 0
    assert_eq!(
        clipboard_delete_by_id(99999),
        0,
        "deleting a non-existent entry ID must return 0 (failure)"
    );

    // Test 2: entry ID 0 (never valid) → returns 0
    assert_eq!(
        clipboard_delete_by_id(0),
        0,
        "deleting entry ID 0 must return 0 (failure)"
    );

    // Test 3: empty history → any ID returns 0
    assert_eq!(
        clipboard_delete_by_id(1),
        0,
        "deleting from empty history must return 0 (failure)"
    );
}
