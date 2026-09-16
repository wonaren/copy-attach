// Entry-ID persistence tests — stable IDs across restarts and deletion.

use crate::backend::{new_entry_id, prime_entry_id};
use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db, persist_entry_to_db, seed_first_launch_tips};
use crate::types::ClipboardEntry;
use rusqlite::Connection;
use super::{insert_text, make_image, make_test_image_rgba, test_db};

#[test]
fn test_first_launch_tips_seed_into_empty_db() {
    let conn = test_db();
    seed_first_launch_tips(&conn);

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert!(!loaded.is_empty(), "empty DB should be seeded with usage tips");
    assert!(loaded.len() >= 5, "expected several tips, got {}", loaded.len());

    // Every seeded row must be attributed to CopyAttach so the list shows the
    // app's own icon (Swift resolves source icons by bundle id).
    for e in &loaded {
        assert_eq!(e.source_name(), "CopyAttach", "tip source name");
        assert_eq!(e.source_bundle_id(), "com.example.copyattach", "tip source bundle id");
    }

    // First tip (welcome) is intended to be read first → newest at top.
    assert_eq!(loaded[0].label(), "欢迎使用 CopyAttach !");
    assert!(loaded[0].label().chars().count() <= 60, "label must fit one line");

    // Text rows must carry persisted preview so cold-start load never reads
    // the `text` column.
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

#[test]
fn test_load_skips_unbackfilled_text_rows() {
    // A text row without persisted preview/label/hash means it was written
    // before the metadata backfill and never got it. The cold-start load must
    // skip it loudly (the load never reads the `text` column), not silently
    // re-read full text — that fallback would reintroduce the cold-start cost.
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
    // The capture write-through is one transaction: insert + dedup + trim.
    // A duplicate text capture must leave exactly one row (the newest) and
    // the returned row id must point at it.
    let mut conn = test_db();
    let entry_a = ClipboardEntry::text_entry(new_entry_id(), "txn-dedup", 100, String::new(), String::new(), 0);
    let entry_b = ClipboardEntry::text_entry(new_entry_id(), "txn-dedup", 200, String::new(), String::new(), 0);

    let row_a = persist_entry_to_db(&mut conn, &entry_a, Some("txn-dedup"), None, None, 3000).unwrap();
    let row_b = persist_entry_to_db(&mut conn, &entry_b, Some("txn-dedup"), None, None, 3000).unwrap();

    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE entry_type = 0", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 1, "dedup inside the transaction must leave one row");
    assert_ne!(row_a, row_b, "the duplicate capture must get a fresh row");
    let old_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history WHERE id = ?1", rusqlite::params![row_a], |r| r.get(0))
        .unwrap();
    assert_eq!(old_rows, 0, "the first capture's row must be removed by dedup");

    // The surviving row carries the newest entry id (entry_b) and persisted metadata.
    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].entry_id(), entry_b.entry_id());
    assert_eq!(loaded[0].label(), "txn-dedup");
}

/// The range-delete trim must keep exactly the newest N rows even when
/// rowids have gaps (deletions), and must be a no-op when the table holds
/// fewer rows than the threshold (the cutoff subquery yields NULL).
#[test]
fn test_trim_range_delete_semantics() {
    let conn = test_db();
    for i in 0..5 {
        insert_text(&conn, &format!("t{i}"), i as u64);
    }
    // Create a rowid gap by deleting the middle row ("t2", id 3).
    conn.execute("DELETE FROM clipboard_history WHERE id = 3", []).unwrap();

    // Under threshold: no-op.
    crate::db::trim_db_history(&conn, 10);
    assert_eq!(load_history_from_db(&conn, 3000).len(), 4);

    // Over threshold: exactly the newest 2 survive, gaps included.
    crate::db::trim_db_history(&conn, 2);
    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].label(), "t4");
    assert_eq!(loaded[1].label(), "t3");
}

/// Simulate a DB written by the 0.99.15-dev build (user_version 1 era, where
/// text hashes were DefaultHasher values): ensure_history_table must recompute
/// them with the stable FNV-1a algorithm and stamp user_version = 2.
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
    // DefaultHasher-era metadata: bogus hash 12345, placeholder preview/label.
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

    // The generation stamp makes the recompute a no-op from here on.
    crate::db::ensure_history_table(&conn).unwrap();
}

/// ensure stamps the text-metadata generation (2) synchronously; image hashes
/// migrate to generation 3 on the background thread driven by
/// `ffi::init::spawn_image_hash_migration`.
#[test]
fn test_metadata_version_stamped_after_text_phase() {
    let conn = test_db();
    let v: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
    assert_eq!(v, 2, "text phase stamps 2; images reach 3 via the background thread");
    assert_eq!(crate::db::METADATA_VERSION, 4);
}

/// A pre-migration image row carries a DefaultHasher value; the per-row
/// migration decodes the stored PNG and replaces it with the stable FNV-1a
/// hash — persisted value and cold-start load both agree.
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

    // Simulate the pre-migration generation: an arbitrary DefaultHasher value.
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

/// An undecodable PNG must fail the migration loudly and leave the old hash
/// untouched — never a silent placeholder.
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

    // Update custom label
    crate::db::update_entry_custom_label(&conn, entry_id, "Updated Remark").unwrap();
    let reloaded = load_history_from_db(&conn, 3000);
    assert_eq!(reloaded[0].custom_label(), "Updated Remark");

    // Clear custom label
    crate::db::update_entry_custom_label(&conn, entry_id, "").unwrap();
    let cleared = load_history_from_db(&conn, 3000);
    assert_eq!(cleared[0].custom_label(), "");
}

/// The capture path's DB invariant: re-copying the same text must keep the
/// remark in SQLite, not just in memory.
///
/// `add_to_history` preserves the label on dedup and the monitor persists
/// `hist[0]` (the merged entry), so the new row carries the old remark and the
/// superseded row is deleted. This test pins that composition — a memory-only
/// assertion would pass while the remark silently disappeared on restart.
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

    // A genuine re-copy: fresh entry, no remark of its own.
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

/// A row captured by an older build holds a thumbnail sized for the old
/// 300px-longest-edge rule. The list draws flat images ~460pt wide, so that blob
/// was upscaled ~3x in the row. This pins the re-encode to the display box, and
/// that a second run is a no-op (idempotent — the migration may be interrupted).
#[test]
fn test_thumbnail_migration_reencodes_undersized_blob() {
    let conn = test_db();
    let rgba = make_test_image_rgba(4000, 100, 77);
    let png = crate::image::encode_png(4000, 100, &rgba).unwrap();
    // The stale 300x8 blob a pre-migration capture would have stored.
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

/// An undecodable PNG must fail the thumbnail migration loudly and leave the row
/// untouched — never a silent success that stamps the version and strands it.
#[test]
fn test_thumbnail_migration_fails_explicitly_on_undecodable_row() {
    let conn = test_db();
    // Stale thumbnail dims (300x8) relative to the 10x10 source so the
    // metadata precheck does not short-circuit: this fixture must reach the
    // decode, which is the failure under test.
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

    /// A read-only file must classify as PermanentEnvironment: retrying can
    /// never succeed, but the database is intact.
    #[test]
    fn test_readonly_file_is_permanent_environment() {
        let dir = tempdir();
        let path = dir.join("ro.db");
        {
            let c = Connection::open(&path).expect("create");
            crate::db::ensure_history_table(&c).expect("schema");
        }
        // Clear outstanding WAL so the file is fully materialized before chmod.
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
                // Force a write so the read-only condition is exercised.
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

    /// A non-database file must classify as Corrupt, which is what drives the
    /// back-up-and-rebuild dialog.
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
