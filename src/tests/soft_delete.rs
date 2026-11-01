use rusqlite::Connection;

use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db};
use crate::types::ClipboardEntry;

fn file_db(name: &str) -> (std::path::PathBuf, Connection) {
    let path = std::env::temp_dir().join(format!(
        "copyattach_test_softdel_{}_{}.db",
        std::process::id(),
        name
    ));
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
    let conn = Connection::open(&path).expect("open temp DB");
    ensure_history_table(&conn).expect("schema");
    (path, conn)
}

fn insert_image_row(
    conn: &Connection,
    entry: &ClipboardEntry,
    png: &[u8],
    thumb: &[u8],
) -> i64 {
    let before: i64 = conn
        .query_row("SELECT COALESCE(MAX(id), 0) FROM clipboard_history", [], |r| r.get(0))
        .expect("read id bound");
    crate::db::insert_entry_to_db(conn, entry, None, Some(png), Some((thumb, 10, 10)))
        .expect("insert image");
    let after: i64 = conn
        .query_row("SELECT COALESCE(MAX(id), 0) FROM clipboard_history", [], |r| r.get(0))
        .expect("read id bound");
    assert!(after > before, "insert must produce a new history row");
    after
}

fn insert_body(conn: &Connection, text: &str, ts: u64) -> (u64, i64) {
    let id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::text_entry(id, text, ts, String::new(), String::new(), 0);
    insert_entry_to_db(conn, &entry, Some(text), None, None).expect("insert");
    (id, conn.last_insert_rowid())
}

#[test]
fn test_soft_deleted_row_is_not_loaded_or_searchable() {
    let (path, conn) = file_db("visible");
    let (_id_a, row_a) = insert_body(&conn, "visible-content", 100);
    let (_id_b, row_b) = insert_body(&conn, "deleted-content", 200);

    let stamp = crate::backend::undo_stamp_now();
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![stamp, row_b],
    )
    .expect("stamp");

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 1, "a soft-deleted row must not load into the list");
    assert_eq!(loaded[0].label(), "visible-content");

    let hits = crate::db::search_history(&conn, "deleted-content");
    assert!(hits.is_empty(), "search must not surface a soft-deleted row: {hits:?}");
    let hits_live = crate::db::search_history(&conn, "visible-content");
    assert!(!hits_live.is_empty(), "the live row must stay searchable");

    drop(conn);
    let conn = Connection::open(&path).expect("reopen");
    ensure_history_table(&conn).expect("schema idempotent");
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 1, "soft-deleted row must stay invisible after restart");

    let (deleted_present, deleted_body): (i64, String) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(h.text), '') FROM clipboard_history h
           JOIN clipboard_deleted d ON d.row_id = h.id WHERE h.id = ?1",
            rusqlite::params![row_b],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(deleted_present, 1, "the deleted row must stay in the table with its payload");
    assert_eq!(deleted_body, "deleted-content");

    let (live_present, live_body): (i64, String) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(text), '') FROM clipboard_history
           WHERE id = ?1 AND id NOT IN (SELECT row_id FROM clipboard_deleted)",
            rusqlite::params![row_a],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(live_present, 1, "the live row is present");
    assert_eq!(live_body, "visible-content");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_dedup_does_not_consume_a_deleted_row() {
    let (path, conn) = file_db("dedup");
    let (id_a, row_a) = insert_body(&conn, "same-content", 100);

    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![crate::backend::undo_stamp_now(), row_a],
    )
    .expect("stamp");

    let (id_b, _row_b) = insert_body(&conn, "same-content", 200);
    let recaptured = ClipboardEntry::text_entry(
        id_b, "same-content", 200, String::new(), String::new(), 0,
    );
    crate::db::delete_matching_entry(&conn, &recaptured, Some("same-content"));

    let deleted_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_history h
           JOIN clipboard_deleted d ON d.row_id = h.id WHERE h.entry_id = ?1",
            rusqlite::params![id_a as i64],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(deleted_rows, 1, "re-capture must not consume the deleted row");

    let live_rows: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_history
           WHERE id NOT IN (SELECT row_id FROM clipboard_deleted) AND text = 'same-content'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(live_rows, 1, "exactly one live copy of the re-captured content");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_trim_counts_live_rows_only() {
    let (path, conn) = file_db("trim");
    let mut rows = Vec::new();
    for i in 0..13 {
        let (_id, row) = insert_body(&conn, &format!("trim-content-{i}"), i as u64);
        rows.push(row);
    }
    let stamp = crate::backend::undo_stamp_now();
    for row in rows.iter().take(5) {
        conn.execute(
            "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
             SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
            rusqlite::params![stamp, row],
        )
        .unwrap();
    }

    let live_count = |conn: &Connection| -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)",
            [],
            |r| r.get(0),
        )
        .unwrap()
    };

    crate::db::trim_db_history(&conn, 10).expect("trim");
    assert_eq!(live_count(&conn), 8, "trim must count live rows only, not deleted ones");

    crate::db::trim_db_history(&conn, 6).expect("trim");
    assert_eq!(live_count(&conn), 6, "trim must shed only the live excess");

    let loaded = load_history_from_db(&conn, 10);
    assert_eq!(loaded.len(), 6, "all live rows must remain loadable");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_undo_after_recapture_leaves_one_row_across_restart() {
    let (path, conn) = file_db("recapture");
    let (id_a, row_a) = insert_body(&conn, "recaptured-content", 1);

    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![crate::backend::undo_stamp_now(), row_a],
    )
    .unwrap();
    insert_entry_to_db(
        &conn,
        &ClipboardEntry::text_entry(id_a, "recaptured-content", 2, String::new(), String::new(), 0),
        Some("recaptured-content"),
        None,
        None,
    )
    .unwrap();

    let restored = ClipboardEntry::text_entry(
        id_a, "recaptured-content", 3, String::new(), String::new(), 0,
    );
    let tx = conn.unchecked_transaction().unwrap();
    insert_entry_to_db(&tx, &restored, Some("recaptured-content"), None, None).unwrap();
    crate::db::delete_matching_entry(&tx, &restored, Some("recaptured-content"));
    tx.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![row_a]).unwrap();
    tx.commit().unwrap();

    let (total, live): (i64, i64) = conn
        .query_row(
            "SELECT COUNT(*), SUM(id NOT IN (SELECT row_id FROM clipboard_deleted))
           FROM clipboard_history WHERE text = 'recaptured-content'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(total, 1, "undo must collapse to a single row");
    assert_eq!(live, 1, "that row must be live");

    drop(conn);
    let conn = Connection::open(&path).expect("reopen");
    ensure_history_table(&conn).expect("schema idempotent");
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    let matching: Vec<_> = loaded.iter().filter(|e| e.label() == "recaptured-content").collect();
    assert_eq!(matching.len(), 1, "restart must not reveal a duplicate row (found {})", matching.len());

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_clear_removes_deleted_rows() {
    let (path, conn) = file_db("clear");
    let (_id, row) = insert_body(&conn, "clear-content", 1);
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![crate::backend::undo_stamp_now(), row],
    )
    .unwrap();

    let tx = conn.unchecked_transaction().unwrap();
    tx.execute("DELETE FROM clipboard_history", []).unwrap();
    tx.execute("DELETE FROM clipboard_favorites", []).unwrap();
    tx.execute("DELETE FROM clipboard_deleted", []).unwrap();
    tx.commit().unwrap();

    for table in ["clipboard_history", "clipboard_deleted"] {
        let remaining: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap();
        assert_eq!(remaining, 0, "clear must empty {table}");
    }

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_soft_delete_primitives_report_read_failures() {
    let (path, conn) = file_db("failures");
    let (_id, row) = insert_body(&conn, "failure-probe", 1);

    assert_eq!(
        crate::db::undo_depth(&conn).expect("live read must succeed"),
        0,
        "nothing deleted yet"
    );
    assert!(
        crate::db::newest_deleted_row(&conn).expect("live read must succeed").is_none(),
        "nothing deleted yet"
    );
    crate::db::soft_delete_row(&conn, row).expect("delete must succeed on a live row");

    assert!(
        crate::db::soft_delete_row(&conn, row).is_err(),
        "deleting the same row twice must fail"
    );
    assert_eq!(
        crate::db::undo_depth(&conn).expect("read must succeed"),
        1,
        "the first delete left one undoable row"
    );

    {
        let ro = Connection::open(&path).expect("reopen read-only connection");
        ro.pragma_update(None, "query_only", true).expect("query_only");
        assert_eq!(
            crate::db::undo_depth(&ro).expect("read must work on a query_only connection"),
            1,
            "reading is unaffected by query_only"
        );
    }

    {
        let ro = Connection::open(&path).expect("reopen");
        ro.pragma_update(None, "query_only", true).expect("query_only");
        drop(ro);
        conn.execute(
            "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
             VALUES (999999, 4242, ?1, 0)",
            rusqlite::params![crate::backend::undo_stamp_now() + 1],
        )
        .expect("insert orphan side row");
        let ro = Connection::open(&path).expect("reopen");
        ro.pragma_update(None, "query_only", true).expect("query_only");
        assert!(
            crate::db::newest_deleted_row(&ro).is_err(),
            "an undeletable orphan must surface as an error, not an infinite loop"
        );
    }

    conn.execute("DELETE FROM clipboard_deleted WHERE row_id = 999999", [])
        .expect("cleanup orphan");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_eviction_preview_matches_the_real_sweep() {
    let (path, conn) = file_db("eviction");
    let blob = vec![0xEEu8; 2 * 1024 * 1024];
    let thumb = vec![0x11u8; 1024];

    let mut deleted_rows = Vec::new();
    for i in 0..3 {
        let id = crate::backend::new_entry_id();
        let entry = ClipboardEntry::Image {
            id,
            width: 100,
            height: 100,
            thumb_width: 10,
            thumb_height: 10,
            hash: id,
            custom_label: String::new(),
            timestamp: i as u64,
            source_name: "EvictTest".to_string(),
            source_bundle_id: "com.example.evict".to_string(),
            db_id: 0,
        };
        let row = insert_image_row(&conn, &entry, &blob, &thumb);
        crate::db::soft_delete_row(&conn, row).expect("soft delete");
        deleted_rows.push(row);
    }
    assert_eq!(
        crate::db::undo_depth(&conn).expect("depth"),
        3,
        "three deletions fit the 6 MB budget"
    );

    let id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::Image {
        id,
        width: 100,
        height: 100,
        thumb_width: 10,
        thumb_height: 10,
        hash: id,
        custom_label: String::new(),
        timestamp: 99,
        source_name: "EvictTest".to_string(),
        source_bundle_id: "com.example.evict".to_string(),
        db_id: 0,
    };
    let incoming_row = insert_image_row(&conn, &entry, &blob, &thumb);
    let incoming_bytes =
        crate::db::history_row_payload_bytes(&conn, incoming_row).expect("payload size");

    let predicted =
        crate::db::pending_undo_evictions(&conn, incoming_bytes, 6 * 1024 * 1024)
            .expect("preview");
    assert!(
        predicted >= 1,
        "adding a fourth 2 MB deletion over a 6 MB budget must predict at least one eviction"
    );

    crate::db::soft_delete_row(&conn, incoming_row).expect("soft delete");
    crate::db::purge_expired_deleted_rows(&conn, 6 * 1024 * 1024).expect("sweep");

    let evicted = 4 - crate::db::undo_depth(&conn).expect("depth");
    let retained: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(COALESCE(LENGTH(h.png_data), 0)
                               + COALESCE(LENGTH(h.thumb_data), 0)), 0)
             FROM clipboard_deleted d JOIN clipboard_history h ON h.id = d.row_id",
            [],
            |r| r.get(0),
        )
        .unwrap();

    assert_eq!(
        evicted, predicted,
        "the preview promised {predicted} eviction(s) but the sweep evicted {evicted}"
    );
    assert!(
        retained <= 6 * 1024 * 1024,
        "the sweep must leave the retained payload inside the budget (left {retained})"
    );

    let newest_survives: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_deleted WHERE row_id = ?1",
            rusqlite::params![incoming_row],
            |r| r.get::<_, i64>(0),
        )
        .unwrap()
        > 0;
    let oldest_gone: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_deleted WHERE row_id = ?1",
            rusqlite::params![deleted_rows[0]],
            |r| r.get::<_, i64>(0),
        )
        .unwrap()
        == 0;
    assert!(newest_survives, "the newest deletion must stay undoable");
    assert!(oldest_gone, "the oldest deletion must be the one evicted");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_eviction_preview_counts_self_eviction() {
    let (path, conn) = file_db("eviction_self");
    let budget: i64 = 6 * 1024 * 1024;
    let thumb = vec![0x11u8; 1024];
    let blob = vec![0xABu8; 8 * 1024 * 1024];

    let id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::Image {
        id,
        width: 100,
        height: 100,
        thumb_width: 10,
        thumb_height: 10,
        hash: id,
        custom_label: String::new(),
        timestamp: 2,
        source_name: "EvictTest".to_string(),
        source_bundle_id: "com.example.evict".to_string(),
        db_id: 0,
    };
    let row = insert_image_row(&conn, &entry, &blob, &thumb);
    let incoming_bytes = crate::db::history_row_payload_bytes(&conn, row).unwrap();
    assert!(incoming_bytes > budget, "fixture must exceed the budget on its own");

    let predicted = crate::db::pending_undo_evictions(&conn, incoming_bytes, budget).unwrap();
    assert_eq!(predicted, 1, "the preview must warn that the item itself cannot be kept");

    crate::db::soft_delete_row(&conn, row).unwrap();
    crate::db::purge_expired_deleted_rows(&conn, budget).unwrap();
    assert_eq!(
        crate::db::undo_depth(&conn).unwrap(),
        0,
        "the over-budget deletion cannot stay undoable"
    );

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_eviction_preview_excludes_expired_deletions() {
    let (path, conn) = file_db("eviction_expired");
    let budget: i64 = 6 * 1024 * 1024;
    let thumb = vec![0x11u8; 1024];

    let entry_for = |id: u64, ts: u64| ClipboardEntry::Image {
        id,
        width: 100,
        height: 100,
        thumb_width: 10,
        thumb_height: 10,
        hash: id,
        custom_label: String::new(),
        timestamp: ts,
        source_name: "EvictTest".to_string(),
        source_bundle_id: "com.example.evict".to_string(),
        db_id: 0,
    };

    let expired_id = crate::backend::new_entry_id();
    let expired_blob = vec![0xEEu8; 4 * 1024 * 1024];
    let expired_row = insert_image_row(&conn, &entry_for(expired_id, 1), &expired_blob, &thumb);
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         VALUES (?1, ?2, ?3, 0)",
        rusqlite::params![
            expired_row,
            expired_id as i64,
            crate::backend::undo_stamp_now()
                - (crate::backend::UNDO_RETENTION_SECS as i64 + 60) * 1_000_000
        ],
    )
    .unwrap();

    let incoming_id = crate::backend::new_entry_id();
    let incoming_blob = vec![0xABu8; 4 * 1024 * 1024];
    let incoming_row = insert_image_row(&conn, &entry_for(incoming_id, 2), &incoming_blob, &thumb);
    let incoming_bytes = crate::db::history_row_payload_bytes(&conn, incoming_row).unwrap();
    assert!(incoming_bytes <= budget, "fixture must fit the budget on its own");

    let predicted = crate::db::pending_undo_evictions(&conn, incoming_bytes, budget).unwrap();
    assert_eq!(
        predicted, 0,
        "expired deletions are swept by age and must not be charged to the byte budget"
    );

    crate::db::soft_delete_row(&conn, incoming_row).unwrap();
    crate::db::purge_expired_deleted_rows(&conn, budget).unwrap();
    assert_eq!(
        crate::db::undo_depth(&conn).unwrap(),
        1,
        "the expired row is swept while the incoming deletion stays undoable"
    );

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_unlimited_budget_never_evicts() {
    let (path, conn) = file_db("unlimited");
    let (_, row) = insert_body(&conn, "unlimited-probe", 1);
    assert_eq!(
        crate::db::pending_undo_evictions(&conn, 10 * 1024 * 1024 * 1024, 0)
            .expect("preview with unlimited budget"),
        0,
        "an unlimited budget must never predict evictions"
    );
    crate::db::soft_delete_row(&conn, row).expect("soft delete");
    assert_eq!(
        crate::db::purge_expired_deleted_rows(&conn, 0).expect("sweep"),
        0,
        "an unlimited budget must purge nothing"
    );
    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_undo_keeps_the_star_of_the_recaptured_copy() {
    let (path, conn) = file_db("undo_star");

    let original_id = crate::backend::new_entry_id();
    let original = ClipboardEntry::text_entry(original_id, "same-content", 100, String::new(), String::new(), 0);
    crate::db::insert_entry_to_db(&conn, &original, Some("same-content"), None, None).unwrap();
    let original_row = conn.last_insert_rowid();
    crate::db::soft_delete_row(&conn, original_row).expect("delete the original");

    let recaptured_id = crate::backend::new_entry_id();
    let recaptured = ClipboardEntry::text_entry(recaptured_id, "same-content", 200, String::new(), String::new(), 0);
    crate::db::insert_entry_to_db(&conn, &recaptured, Some("same-content"), None, None).unwrap();
    crate::db::set_favorite(&conn, recaptured_id, true).expect("star the recaptured copy");

    let restored = ClipboardEntry::text_entry(original_id, "same-content", 300, String::new(), String::new(), 0);
    crate::db::insert_entry_to_db(&conn, &restored, Some("same-content"), None, None).unwrap();
    crate::db::delete_matching_entry(&conn, &restored, Some("same-content"));
    conn.execute("DELETE FROM clipboard_deleted WHERE row_id = ?1", rusqlite::params![original_row])
        .expect("drop the undo entry");
    conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![original_row])
        .expect("drop the deleted payload row");

    let surviving_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .unwrap();
    assert_eq!(surviving_rows, 1, "the dedup must collapse to one row");

    let before_prune = crate::db::load_favorites(&conn).expect("load favorites");
    assert_eq!(
        before_prune.len(), 1,
        "the star transfer must not leave the deduped entry's favorite behind: {before_prune:?}"
    );

    crate::db::prune_orphan_favorites(&conn).expect("prune");
    let favorites = crate::db::load_favorites(&conn).expect("load favorites");
    assert_eq!(favorites.len(), 1, "exactly one star must remain: {favorites:?}");

    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 1, "one visible row");
    assert!(
        favorites.contains(&loaded[0].entry_id()),
        "the surviving row must be the starred one (favorites={favorites:?}, row id={})",
        loaded[0].entry_id()
    );

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

#[test]
fn test_storage_breakdown_separates_text_image_and_undo() {
    let (path, conn) = file_db("storage_breakdown");
    insert_body(&conn, "hello", 1);

    let id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::Image {
        id,
        width: 1,
        height: 1,
        thumb_width: 10,
        thumb_height: 10,
        hash: id,
        custom_label: String::new(),
        timestamp: 2,
        source_name: "StoreTest".to_string(),
        source_bundle_id: "com.example.store".to_string(),
        db_id: 0,
    };
    let png = vec![0xEEu8; 4096];
    let thumb = vec![0x11u8; 1024];
    let row = insert_image_row(&conn, &entry, &png, &thumb);

    let (text, image, undo) = crate::db::storage_breakdown(&conn).expect("breakdown");
    assert_eq!(text, 5, "live text bytes");
    assert_eq!(image, 4096 + 1024, "live image bytes");
    assert_eq!(undo, 0, "no undo payload yet");

    crate::db::soft_delete_row(&conn, row).unwrap();
    let (text, image, undo) = crate::db::storage_breakdown(&conn).expect("breakdown");
    assert_eq!(text, 5, "deleting an image must not move its bytes into text");
    assert_eq!(image, 0, "deleted image must leave the live image total");
    assert_eq!(undo, 4096 + 1024, "the deleted payload must count as undo retention");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}
