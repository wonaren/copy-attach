// Entry-ID persistence tests — stable IDs across restarts and deletion.

use crate::backend::{new_entry_id, prime_entry_id};
use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db};
use crate::types::ClipboardEntry;
use rusqlite::Connection;
use super::{insert_text, test_db};

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

    assert_eq!(loaded[0].label(), "gamma", "newest first");
    assert_eq!(loaded[1].label(), "beta");
    assert_eq!(loaded[2].label(), "alpha");

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
    assert_eq!(after[0].label(), "c", "newest preserved");
    assert_eq!(after[1].label(), "a", "oldest preserved");
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

    let entry_new = ClipboardEntry::text_entry(
        new_id,
        "post-restart",
        999,
        String::new(),
        String::new(),
        0,
    );
    insert_entry_to_db(&conn, &entry_new, Some("post-restart"), None, None).unwrap();

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
