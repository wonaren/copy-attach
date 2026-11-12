use crate::backend::{new_entry_id, prime_entry_id};
use crate::db::{ensure_history_table, import_favorites, insert_entry_to_db, load_favorites, load_history_from_db, persist_entry_to_db, seed_first_launch_tips, set_favorite};
use crate::types::ClipboardEntry;
use rusqlite::Connection;
use super::{insert_text, make_image, make_test_image_rgba, test_db};

#[test]
fn test_startup_bound_honours_user_threshold_above_default() {
    use crate::backend::{DEFAULT_CLEANUP_THRESHOLD, MAX_CLEANUP_THRESHOLD};

    const { assert!(MAX_CLEANUP_THRESHOLD > DEFAULT_CLEANUP_THRESHOLD) };

    let conn = test_db();
    let user_threshold = 400;
    let rows_over_default = DEFAULT_CLEANUP_THRESHOLD + 50;
    for i in 0..rows_over_default {
        insert_text(&conn, &format!("startup-bound-{i}"), i as u64);
    }
    let total: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .expect("count");
    assert_eq!(total as usize, rows_over_default);

    let loaded = load_history_from_db(&conn, user_threshold.max(rows_over_default));
    assert_eq!(
        loaded.len(),
        rows_over_default,
        "startup load must be bounded by the caller's threshold, not by the compile-time default"
    );

    crate::db::trim_db_history(&conn, user_threshold).expect("trim");
    let after: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .expect("count");
    assert_eq!(after as usize, user_threshold, "trim must enforce the user's threshold");

    let loaded = load_history_from_db(&conn, user_threshold);
    assert_eq!(loaded.len(), user_threshold);
    let newest = format!("startup-bound-{}", rows_over_default - 1);
    assert_eq!(loaded[0].label(), newest, "newest row must survive the trim");
}

#[test]
fn test_first_launch_tips_seed_into_empty_db() {
    let conn = test_db();
    seed_first_launch_tips(&conn);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert!(!loaded.is_empty(), "empty DB should be seeded with usage tips");
    assert!(loaded.len() >= 5, "expected several tips, got {}", loaded.len());

    for e in &loaded {
        assert_eq!(e.source_name(), "CopyAttach", "tip source name");
        assert_eq!(e.source_bundle_id(), "cc.wonaren.copyattach", "tip source bundle id");
    }

    assert_eq!(loaded[0].label(), "欢迎使用 CopyAttach !");
    assert!(loaded[0].label().chars().count() <= 60, "label must fit one line");

    for e in &loaded {
        assert!(!e.preview().is_empty(), "tip must have a persisted preview");
    }
}

#[test]
fn test_first_launch_tips_not_seeded_when_history_exists() {
    let conn = test_db();
    insert_text(&conn, "real captured content", 100);

    seed_first_launch_tips(&conn);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 1, "existing history must never be re-seeded");
    assert_eq!(loaded[0].label(), "real captured content");
}

#[test]
fn test_entry_id_persistence_and_restore() {
    let db_path = std::env::temp_dir().join(format!(
        "copyattach_test_eid_{}.db", std::process::id()
    ));
    let _ = std::fs::remove_file(&db_path);

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

    drop(conn);

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

    assert_eq!(ids_after[0], ids_before[0], "newest entry ID stable after delete");
    assert_eq!(ids_after[1], ids_before[2], "oldest entry ID stable after delete");
    assert_eq!(after[0].label(), "c", "newest preserved");
    assert_eq!(after[1].label(), "a", "oldest preserved");
}

#[test]
fn test_entry_id_monotonic_after_reload() {
    let conn = test_db();

    let _a = insert_text(&conn, "first-batch-a", 100);
    let _b = insert_text(&conn, "first-batch-b", 200);
    let _c = insert_text(&conn, "first-batch-c", 300);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let max_loaded = loaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).max().unwrap();
    prime_entry_id(max_loaded + 1);

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

    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 4, "4 entries total after post-restart insert");

    let all_ids: Vec<u64> = reloaded.iter().map(|e| match e {
        ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
    }).collect();

    for orig in &loaded {
        let orig_id = match orig {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(all_ids.contains(&orig_id),
            "original entry_id {} must survive restart", orig_id);
    }
    assert!(all_ids.contains(&new_id),
        "post-restart entry_id {} must be present", new_id);
}

#[test]
fn test_trim_db_history_never_evicts_favorites() {
    let mut conn = test_db();
    for i in 0..6u64 {
        insert_text(&conn, &format!("fav-trim-{i}"), i);
    }
    let rows: Vec<(u64, String)> = {
        let mut stmt = conn
            .prepare("SELECT entry_id, label FROM clipboard_history ORDER BY timestamp ASC")
            .unwrap();
        let it = stmt
            .query_map([], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, String>(1)?)))
            .unwrap();
        it.map(|r| r.unwrap()).collect()
    };
    assert_eq!(rows.len(), 6);
    for (entry_id, _) in &rows[0..2] {
        crate::db::set_favorite(&conn, *entry_id, true).unwrap();
    }

    crate::db::trim_db_history(&conn, 3).unwrap();

    let loaded = load_history_from_db(&conn, 3);
    assert_eq!(
        loaded.len(),
        3,
        "2 favorites + the newest ordinary row must survive, got {:?}",
        loaded.iter().map(|e| e.label()).collect::<Vec<_>>()
    );
    for favored in ["fav-trim-0", "fav-trim-1"] {
        assert!(
            loaded.iter().any(|e| e.label() == favored),
            "{favored} must survive automatic trimming"
        );
    }
    assert!(
        !loaded.iter().any(|e| e.label() == "fav-trim-2"),
        "the oldest NON-favorite must be evicted"
    );
    let stored = crate::db::load_favorites(&conn).unwrap();
    assert_eq!(stored.len(), 2);

    let captured = ClipboardEntry::text_entry(new_entry_id(), "new capture", 10, String::new(), String::new(), 0);
    persist_entry_to_db(&mut conn, &captured, Some("new capture"), None, None, 3).unwrap();
    let loaded = load_history_from_db(&conn, 10);
    assert_eq!(loaded.len(), 3);
    assert_eq!(loaded.first().map(ClipboardEntry::entry_id), Some(captured.entry_id()));

    crate::db::trim_db_history(&conn, 1).unwrap();
    let loaded = load_history_from_db(&conn, 10);
    assert_eq!(loaded.len(), 2, "favorites survive when they alone exceed the threshold");
    assert!(loaded.iter().all(|entry| stored.contains(&entry.entry_id())));
}

#[test]
fn test_new_capture_survives_when_protected_rows_fill_threshold() {
    let mut conn = test_db();
    for i in 0..2u64 {
        insert_text(&conn, &format!("pinned-{i}"), i);
    }
    let pinned: Vec<u64> = {
        let mut stmt = conn
            .prepare("SELECT entry_id FROM clipboard_history ORDER BY timestamp ASC")
            .unwrap();
        let it = stmt.query_map([], |r| r.get::<_, i64>(0)).unwrap();
        it.map(|r| r.unwrap() as u64).collect()
    };
    for id in &pinned {
        set_favorite(&conn, *id, true).unwrap();
    }

    let captured = ClipboardEntry::text_entry(new_entry_id(), "fresh capture", 10, String::new(), String::new(), 0);
    let (row_id, removed) = persist_entry_to_db(&mut conn, &captured, Some("fresh capture"), None, None, 2)
        .expect("persist must succeed");

    assert!(
        !removed.contains(&row_id),
        "the row written by this capture must not be trimmed away in the same transaction"
    );
    let stored: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE id = ?1", [row_id], |r| r.get(0))
        .unwrap();
    assert_eq!(stored, 1, "the new capture must remain stored");
    let favorites: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_favorites", [], |r| r.get(0))
        .unwrap();
    assert_eq!(favorites, 2, "protected rows must still survive");
}

#[test]
fn test_import_favorites_skips_missing_rows_and_is_idempotent() {
    let conn = test_db();
    for i in 0..2u64 {
        insert_text(&conn, &format!("legacy-{i}"), i);
    }
    let ids: Vec<u64> = {
        let mut stmt = conn
            .prepare("SELECT entry_id FROM clipboard_history ORDER BY timestamp ASC")
            .unwrap();
        let it = stmt.query_map([], |r| r.get::<_, i64>(0)).unwrap();
        it.flatten().map(|id| id as u64).collect()
    };
    assert_eq!(ids.len(), 2);

    let imported = import_favorites(&conn, &[ids[0], ids[1], u64::MAX]).unwrap();
    assert_eq!(imported, 2, "ids with no row must be skipped");
    assert_eq!(load_favorites(&conn).unwrap().len(), 2);

    assert_eq!(import_favorites(&conn, &[ids[0]]).unwrap(), 0);
    assert_eq!(load_favorites(&conn).unwrap().len(), 2);
}

#[test]
fn test_set_favorite_rejects_missing_entry() {
    let conn = test_db();
    assert!(set_favorite(&conn, 42, true).is_err());
    assert!(load_favorites(&conn).unwrap().is_empty());
}

#[test]
fn test_load_includes_all_favorites_even_when_one_is_newest() {
    let conn = test_db();
    for i in 0..6u64 {
        insert_text(&conn, &format!("fav-window-{i}"), i);
    }
    let ids: Vec<u64> = {
        let mut stmt = conn
            .prepare("SELECT entry_id FROM clipboard_history ORDER BY timestamp ASC")
            .unwrap();
        let it = stmt.query_map([], |r| r.get::<_, i64>(0)).unwrap();
        it.flatten().map(|id| id as u64).collect()
    };
    set_favorite(&conn, ids[5], true).unwrap();
    set_favorite(&conn, ids[0], true).unwrap();

    let loaded = load_history_from_db(&conn, 4);
    let loaded_ids: Vec<_> = loaded.iter().map(ClipboardEntry::entry_id).collect();
    assert_eq!(loaded_ids, [ids[5], ids[4], ids[3], ids[0]]);
}

#[test]
fn test_entry_id_never_reused_after_clear_and_restart() {
    let conn = test_db();

    for i in 0..5 {
        insert_text(&conn, &format!("session-1-{i}"), i as u64);
    }
    let max_issued: u64 = load_history_from_db(&conn, 3000)
        .iter()
        .map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        })
        .max()
        .expect("rows were inserted");

    conn.execute("DELETE FROM clipboard_history", []).expect("clear");
    assert_eq!(load_history_from_db(&conn, 3000).len(), 0, "table is empty");
    assert_eq!(
        crate::db::entry_id_watermark(&conn),
        max_issued,
        "the watermark must have survived the clear"
    );

    let max_loaded = load_history_from_db(&conn, 3000)
        .iter()
        .map(|e| match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        })
        .max()
        .unwrap_or(0);
    assert_eq!(max_loaded, 0, "nothing loads from an empty table");
    let watermark = crate::db::entry_id_watermark(&conn);
    let next = max_loaded.max(watermark) + 1;

    assert!(
        next > max_issued,
        "a cleared database must not restart ids below the previously issued {max_issued} (got {next})"
    );
}

#[test]
fn test_entry_id_backfill_old_rows() {
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

    ensure_history_table(&conn).unwrap();

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 2);
    for e in &loaded {
        let eid = match e {
            ClipboardEntry::Text { id, .. } | ClipboardEntry::Image { id, .. } => *id,
        };
        assert!(eid > 0, "backfilled entry_id must be non-zero, got {}", eid);
    }

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
fn test_load_skips_unbackfilled_text_rows() {
    let conn = test_db();
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp)
         VALUES (0, 'ghost-legacy', 100)",
        [],
    ).unwrap();

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 0, "text row without persisted metadata must be skipped");
}

#[test]
fn test_persist_entry_single_transaction() {
    let mut conn = test_db();
    let entry_a = ClipboardEntry::text_entry(new_entry_id(), "txn-dedup", 100, String::new(), String::new(), 0);
    let entry_b = ClipboardEntry::text_entry(new_entry_id(), "txn-dedup", 200, String::new(), String::new(), 0);

    let (row_a, _) = persist_entry_to_db(&mut conn, &entry_a, Some("txn-dedup"), None, None, 3000).unwrap();
    let (row_b, removed) = persist_entry_to_db(&mut conn, &entry_b, Some("txn-dedup"), None, None, 3000).unwrap();

    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE entry_type = 0", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 1, "dedup inside the transaction must leave one row");
    assert_ne!(row_a, row_b, "the duplicate capture must get a fresh row");
    assert_eq!(removed, [row_a].into_iter().collect());
    let old_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE id = ?1", rusqlite::params![row_a], |r| r.get(0))
        .unwrap();
    assert_eq!(old_rows, 0, "the first capture's row must be removed by dedup");

    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].entry_id(), entry_b.entry_id());
    assert_eq!(loaded[0].label(), "txn-dedup");
}

#[test]
fn test_persist_row_id_points_at_history_row() {
    let mut conn = test_db();
    conn.execute("INSERT INTO clipboard_meta (key, value) VALUES ('undo_limit', 0)", [])
        .expect("seed an unrelated meta row so clipboard_meta rowids diverge from history rowids");
    let entry = ClipboardEntry::text_entry(new_entry_id(), "rowid-check", 100, String::new(), String::new(), 0);

    let (row_id, _) = persist_entry_to_db(&mut conn, &entry, Some("rowid-check"), None, None, 3000).unwrap();

    let history_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE id = ?1", rusqlite::params![row_id], |r| r.get(0))
        .unwrap();
    assert_eq!(history_rows, 1, "persisted row_id must address clipboard_history, not clipboard_meta");
}

#[test]
fn test_trim_range_delete_semantics() {
    let conn = test_db();
    for i in 0..5 {
        insert_text(&conn, &format!("t{i}"), i as u64);
    }
    conn.execute("DELETE FROM clipboard_history WHERE id = 3", []).unwrap();

    crate::db::trim_db_history(&conn, 10).expect("trim below threshold must succeed");
    assert_eq!(load_history_from_db(&conn, 3000).len(), 4);

    crate::db::trim_db_history(&conn, 2).expect("trim over threshold must succeed");
    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].label(), "t4");
    assert_eq!(loaded[1].label(), "t3");
}

#[test]
fn test_metadata_recompute_for_version1_default_hasher() {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE TABLE clipboard_history (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            entry_id        INTEGER NOT NULL DEFAULT 0,
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
            source_bundle_id TEXT NOT NULL DEFAULT '',
            preview         TEXT NOT NULL DEFAULT '',
            label           TEXT NOT NULL DEFAULT ''
        );"
    ).unwrap();
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, timestamp, hash, preview, label)
         VALUES (0, 'stable-me', 100, 12345, 'x', 'x')",
        [],
    ).unwrap();
    conn.pragma_update(None, "user_version", 1).unwrap();

    crate::db::ensure_history_table(&conn).unwrap();

    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].label(), "stable-me", "metadata recomputed from text");
    let hash = match &loaded[0] {
        ClipboardEntry::Text { text_hash, .. } => *text_hash,
        _ => unreachable!("expected a text entry"),
    };
    assert_eq!(hash, crate::types::text_hash("stable-me"),
        "version-1 DefaultHasher value must be replaced by the stable FNV-1a hash");

    crate::db::ensure_history_table(&conn).unwrap();
}

#[test]
fn test_metadata_version_stamped_after_text_phase() {
    let conn = test_db();
    let v: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
    assert_eq!(v, 2, "text phase stamps 2; images reach 3 via the background thread");
    assert_eq!(crate::db::METADATA_VERSION, 4);
}

#[test]
fn test_image_hash_migration_recomputes_stable_hash() {
    let conn = test_db();
    let rgba = make_test_image_rgba(8, 8, 42);
    let expected = crate::image::image_hash(&rgba, 8, 8);
    let img = make_image(&rgba, 8, 8, 100);
    let png = crate::image::encode_png(8, 8, &rgba).unwrap();
    let thumb = crate::image::create_thumbnail(8, 8, &rgba).unwrap();
    let (tw, th) = match &img {
        ClipboardEntry::Image { thumb_width, thumb_height, .. } =>
            (*thumb_width, *thumb_height),
        _ => unreachable!("make_image must produce an image entry"),
    };
    insert_entry_to_db(&conn, &img, None, Some(&png), Some((&thumb.0, tw, th))).unwrap();
    let db_id = conn.last_insert_rowid();

    conn.execute("UPDATE clipboard_history SET hash = 12345 WHERE id = ?1", rusqlite::params![db_id]).unwrap();

    let new_hash = crate::db::migrate_one_image_row(&conn, db_id).unwrap();
    assert_eq!(new_hash, expected);

    let stored: i64 = conn.query_row(
        "SELECT hash FROM clipboard_history WHERE id = ?1",
        rusqlite::params![db_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(stored as u64, expected, "persisted hash replaced with the stable algorithm");

    let loaded = load_history_from_db(&conn, 3000);
    match &loaded[0] {
        ClipboardEntry::Image { hash, .. } => assert_eq!(*hash, expected),
        _ => unreachable!("expected the image entry"),
    }
}

#[test]
fn test_image_hash_migration_undecodable_row_fails_explicitly() {
    let conn = test_db();
    conn.execute(
        "INSERT INTO clipboard_history (entry_type, png_data, width, height, hash, timestamp)
         VALUES (1, X'00FF', 1, 1, 12345, 100)",
        [],
    ).unwrap();
    let db_id = conn.last_insert_rowid();

    assert!(crate::db::migrate_one_image_row(&conn, db_id).is_err());

    let stored: i64 = conn.query_row(
        "SELECT hash FROM clipboard_history WHERE id = ?1",
        rusqlite::params![db_id],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(stored, 12345, "old hash left untouched when the PNG cannot be decoded");
}

#[test]
fn test_custom_label_persistence_and_update() {
    let mut conn = test_db();
    let entry_id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::Text {
        id: entry_id,
        preview: "test-content".to_string(),
        label: "test-content".to_string(),
        custom_label: "My Note".to_string(),
        text_hash: crate::types::text_hash("test-content"),
        timestamp: 1000,
        source_name: "App".to_string(),
        source_bundle_id: "com.app".to_string(),
        db_id: 0,
    };
    persist_entry_to_db(&mut conn, &entry, Some("test-content"), None, None, 3000).unwrap();

    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].custom_label(), "My Note");

    crate::db::update_entry_custom_label(&conn, entry_id, "Updated Remark").unwrap();
    let reloaded = load_history_from_db(&conn, 3000);
    assert_eq!(reloaded[0].custom_label(), "Updated Remark");

    crate::db::update_entry_custom_label(&conn, entry_id, "").unwrap();
    let cleared = load_history_from_db(&conn, 3000);
    assert_eq!(cleared[0].custom_label(), "");
}

#[test]
fn test_recapture_persists_preserved_custom_label() {
    let mut conn = test_db();
    let text = "shared-body-for-recapture";

    let first = ClipboardEntry::Text {
        id: new_entry_id(),
        preview: text.to_string(),
        label: text.to_string(),
        custom_label: "Production Key".to_string(),
        text_hash: crate::types::text_hash(text),
        timestamp: 1000,
        source_name: "App".to_string(),
        source_bundle_id: "com.app".to_string(),
        db_id: 0,
    };
    persist_entry_to_db(&mut conn, &first, Some(text), None, None, 3000).unwrap();
    let first_id = first.entry_id();

    let recaptured = ClipboardEntry::Text {
        id: new_entry_id(),
        preview: text.to_string(),
        label: text.to_string(),
        custom_label: String::new(),
        text_hash: crate::types::text_hash(text),
        timestamp: 2000,
        source_name: "App".to_string(),
        source_bundle_id: "com.app".to_string(),
        db_id: 0,
    };
    let merged = crate::history::add_to_history(vec![first], recaptured);
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].entry_id(), first_id, "stable id survives recapture");
    assert_eq!(merged[0].custom_label(), "Production Key");

    persist_entry_to_db(&mut conn, &merged[0], Some(text), None, None, 3000).unwrap();

    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 1, "recapture must leave exactly one row");
    assert_eq!(
        loaded[0].custom_label(),
        "Production Key",
        "the remark must survive recapture in the DB, not only in memory"
    );
    assert_eq!(loaded[0].entry_id(), first_id);
}

#[test]
fn test_thumbnail_migration_reencodes_undersized_blob() {
    let conn = test_db();
    let rgba = make_test_image_rgba(4000, 100, 77);
    let png = crate::image::encode_png(4000, 100, &rgba).unwrap();
    let stale = crate::image::encode_png(300, 8, &make_test_image_rgba(300, 8, 77)).unwrap();
    conn.execute(
        "INSERT INTO clipboard_history
         (entry_type, png_data, width, height, thumb_data, thumb_width, thumb_height, hash, timestamp)
         VALUES (1, ?1, 4000, 100, ?2, 300, 8, 1, 1)",
        rusqlite::params![png, stale],
    ).unwrap();
    let id = conn.last_insert_rowid();

    let mut blob = Vec::new();
    let (tw, th) = crate::db::migrate_one_thumbnail_row(&conn, id, &mut blob, &mut Vec::new())
        .unwrap().expect("an undersized thumbnail must be re-encoded");
    assert_eq!(tw, crate::image::THUMB_BOX_W, "40:1 source is bounded by the box width");
    assert!(th <= crate::image::THUMB_BOX_H);

    let (stored_w, stored_h, stored_len): (i64, i64, i64) = conn.query_row(
        "SELECT thumb_width, thumb_height, LENGTH(thumb_data) FROM clipboard_history WHERE id = ?1",
        rusqlite::params![id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    ).unwrap();
    assert_eq!((stored_w, stored_h), (tw as i64, th as i64), "stored dims must match the new blob");
    assert!(stored_len > 0);

    assert_eq!(crate::db::migrate_one_thumbnail_row(&conn, id, &mut blob, &mut Vec::new()).unwrap(), None,
               "a blob already at the target dims must not be re-encoded");
}

#[test]
fn test_thumbnail_migration_fails_explicitly_on_undecodable_row() {
    let conn = test_db();
    conn.execute(
        "INSERT INTO clipboard_history
         (entry_type, png_data, width, height, thumb_data, thumb_width, thumb_height, hash, timestamp)
         VALUES (1, X'00FF', 10, 10, X'0102', 300, 8, 12345, 1)",
        [],
    ).unwrap();
    let id = conn.last_insert_rowid();

    assert!(crate::db::migrate_one_thumbnail_row(&conn, id, &mut Vec::new(), &mut Vec::new()).is_err());

    let (tw, th): (i64, i64) = conn.query_row(
        "SELECT thumb_width, thumb_height FROM clipboard_history WHERE id = ?1",
        rusqlite::params![id], |r| Ok((r.get(0)?, r.get(1)?)),
    ).unwrap();
    assert_eq!((tw, th), (300, 8), "old thumbnail left untouched when the PNG cannot be decoded");
}

#[cfg(test)]
mod db_failure_classification {
    use crate::db::{classify_db_error, DbFailure};
    use rusqlite::Connection;

    #[test]
    fn test_readonly_file_is_permanent_environment() {
        let dir = tempdir();
        let path = dir.join("ro.db");
        {
            let c = Connection::open(&path).expect("create");
            crate::db::ensure_history_table(&c).expect("schema");
        }
        {
            let c = Connection::open(&path).expect("reopen");
            let _: String = c.query_row("PRAGMA journal_mode=DELETE", [], |r| r.get(0)).unwrap();
        }
        let mut perms = std::fs::metadata(&path).unwrap().permissions();
        use std::os::unix::fs::PermissionsExt;
        perms.set_mode(0o444);
        std::fs::set_permissions(&path, perms).unwrap();

        let err = Connection::open(&path)
            .and_then(|c| {
                c.execute("CREATE TABLE probe (x INTEGER)", [])
            })
            .expect_err("write to a read-only file must fail");
        assert_eq!(
            classify_db_error(&err),
            DbFailure::PermanentEnvironment,
            "read-only must be permanent-environment, got {err}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_not_a_database_is_corrupt() {
        let dir = tempdir();
        let path = dir.join("junk.db");
        std::fs::write(&path, b"this is not a sqlite database at all, not even close").unwrap();
        let err = Connection::open(&path)
            .and_then(|c| c.query_row("SELECT * FROM sqlite_master", [], |r| r.get::<_, i64>(0)))
            .expect_err("opening junk as a DB must fail");
        assert_eq!(
            classify_db_error(&err),
            DbFailure::Corrupt,
            "non-database file must classify as corrupt, got {err}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn tempdir() -> std::path::PathBuf {
        let base = std::env::temp_dir().join(format!(
            "copyattach-dbfail-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&base).unwrap();
        base
    }
}

#[cfg(test)]
mod auto_vacuum {
    use rusqlite::Connection;

    fn temp_db(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "copyattach-av-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("history.db")
    }

    fn fill_and_clear(conn: &Connection) {
        for i in 0..200i64 {
            let blob = vec![(i % 251) as u8; 100 * 1024];
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, png_data, width, height, hash, timestamp, source_name,
                     source_bundle_id, entry_id)
                 VALUES (1, ?1, 1, 1, ?2, 0, 'AV', 'com.example.av', ?2)",
                rusqlite::params![blob, i],
            )
            .unwrap();
        }
        conn.execute("DELETE FROM clipboard_history", []).unwrap();
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    }

    #[test]
    fn test_incremental_auto_vacuum_reclaims_in_batches() {
        let path = temp_db("incremental");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;").unwrap();
            crate::db::ensure_history_table(&conn).unwrap();
            assert_eq!(crate::db::auto_vacuum_mode(&conn), Some(2));
            fill_and_clear(&conn);
        }
        let conn = Connection::open(&path).unwrap();
        let free = crate::db::freelist_pages(&conn).unwrap();
        assert!(free >= 1_000, "fixture must leave free pages, got {free}");
        let before_size = std::fs::metadata(&path).unwrap().len();
        let mut rounds = 0;
        loop {
            let freed = crate::db::reclaim_free_pages(&conn, 1_024).unwrap();
            if freed == 0 {
                break;
            }
            rounds += 1;
            assert!(rounds < 1_000, "batch reclaim must converge");
        }
        assert_eq!(crate::db::freelist_pages(&conn), Some(0));
        let after_size = std::fs::metadata(&path).unwrap().len();
        assert!(
            after_size < before_size,
            "the file must shrink: {before_size} -> {after_size}"
        );
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_conversion_enables_incremental_reclaim_on_an_existing_db() {
        let path = temp_db("convert");
        {
            let conn = Connection::open(&path).unwrap();
            crate::db::ensure_history_table(&conn).unwrap();
            assert_eq!(crate::db::auto_vacuum_mode(&conn), Some(0));
            fill_and_clear(&conn);
        }
        let conn = Connection::open(&path).unwrap();
        assert!(crate::db::freelist_pages(&conn).unwrap() > 0);
        crate::db::convert_to_incremental_auto_vacuum(&conn).unwrap();
        assert_eq!(crate::db::auto_vacuum_mode(&conn), Some(2));
        assert_eq!(crate::db::freelist_pages(&conn), Some(0));

        fill_and_clear(&conn);
        assert!(crate::db::freelist_pages(&conn).unwrap() > 0);
        let freed = crate::db::reclaim_free_pages(&conn, 1_024).unwrap();
        assert!(freed > 0, "converted databases must reclaim in batches");
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }
}
