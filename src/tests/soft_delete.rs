// Soft-delete undo: the DB-level contract (restart survival, visibility, sweep).
//
// These tests run against a plain `Connection` (no global backend singleton) so
// they can model a restart honestly: a second connection over the same file is
// exactly what the app does on relaunch. The FFI-level behavior (delete/undo
// through `clipboard_delete_by_id` / `clipboard_undo_delete`) is covered in
// `tests/backend.rs`; this file pins what the *database* guarantees.

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

fn insert_body(conn: &Connection, text: &str, ts: u64) -> (u64, i64) {
    let id = crate::backend::new_entry_id();
    let entry = ClipboardEntry::text_entry(id, text, ts, String::new(), String::new(), 0);
    insert_entry_to_db(conn, &entry, Some(text), None, None).expect("insert");
    (id, conn.last_insert_rowid())
}

/// A soft-deleted row must be invisible to the list load and to search, and
/// must stay invisible across a restart (it is not history any more).
#[test]
fn test_soft_deleted_row_is_not_loaded_or_searchable() {
    let (path, conn) = file_db("visible");
    let (_id_a, row_a) = insert_body(&conn, "visible-content", 100);
    let (_id_b, row_b) = insert_body(&conn, "deleted-content", 200);

    // Soft-delete the second row.
    let stamp = crate::backend::undo_stamp_now();
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![stamp, row_b],
    )
    .expect("stamp");

    // The load must contain exactly the live row.
    let loaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(loaded.len(), 1, "a soft-deleted row must not load into the list");
    assert_eq!(loaded[0].label(), "visible-content");

    // Search must not find it either (both the FTS and metadata paths).
    let hits = crate::db::search_history(&conn, "deleted-content");
    assert!(hits.is_empty(), "search must not surface a soft-deleted row: {hits:?}");
    let hits_live = crate::db::search_history(&conn, "visible-content");
    assert!(!hits_live.is_empty(), "the live row must stay searchable");

    // Restart: a fresh connection over the same file must agree.
    drop(conn);
    let conn = Connection::open(&path).expect("reopen");
    ensure_history_table(&conn).expect("schema idempotent");
    let reloaded = load_history_from_db(&conn, crate::backend::DEFAULT_CLEANUP_THRESHOLD);
    assert_eq!(reloaded.len(), 1, "soft-deleted row must stay invisible after restart");

    // And the deleted row itself is still there with its payload (that is the
    // undo), while the live row is untouched.
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

/// Dedup must ignore soft-deleted rows: re-capturing content that is sitting in
/// the undo stack must not consume the deletion (which would make it
/// un-undoable) — it inserts a fresh live row alongside the deleted one.
#[test]
fn test_dedup_does_not_consume_a_deleted_row() {
    let (path, conn) = file_db("dedup");
    let (id_a, row_a) = insert_body(&conn, "same-content", 100);

    // Delete it…
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![crate::backend::undo_stamp_now(), row_a],
    )
    .expect("stamp");

    // …then capture the same content again.
    let (_id_b, _row_b) = insert_body(&conn, "same-content", 200);

    // The deleted row must survive: `delete_matching_entry` only touches live
    // rows, so re-capture cannot silently swallow an undo candidate.
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

/// The trim and the startup bound must count only live rows, so deleted rows
/// never push live history out of the list.
#[test]
fn test_trim_counts_live_rows_only() {
    let (path, conn) = file_db("trim");
    let mut rows = Vec::new();
    for i in 0..10 {
        let (_id, row) = insert_body(&conn, &format!("trim-content-{i}"), i as u64);
        rows.push(row);
    }
    // Delete the 5 oldest.
    let stamp = crate::backend::undo_stamp_now();
    for row in rows.iter().take(5) {
        conn.execute(
            "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
             SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
            rusqlite::params![stamp, row],
        )
        .unwrap();
    }

    // Threshold 10: there are 10 physical rows but only 5 live ones, so nothing
    // may be trimmed. Counting physical rows would have deleted all 5 live rows.
    crate::db::trim_db_history(&conn, 10).expect("trim");
    let live: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(live, 5, "trim must count live rows only, not deleted ones");

    let loaded = load_history_from_db(&conn, 10);
    assert_eq!(loaded.len(), 5, "all live rows must remain loadable");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}

/// End-to-end regression for the duplicate-row bug the soft-delete design fixes.
///
/// Sequence: delete A → re-capture A → undo. The old undo path inserted without
/// dedup, so the table ended up holding two identical rows and the duplicate
/// survived a restart (the load path does not dedup). With the insert going
/// through the dedup+trim path, exactly one row survives, and it survives a
/// restart as one row.
#[test]
fn test_undo_after_recapture_leaves_one_row_across_restart() {
    let (path, conn) = file_db("recapture");
    let (id_a, row_a) = insert_body(&conn, "recaptured-content", 1);

    // Delete A (soft).
    conn.execute(
        "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
         SELECT ?2, (SELECT entry_id FROM clipboard_history WHERE id = ?2), ?1, 0",
        rusqlite::params![crate::backend::undo_stamp_now(), row_a],
    )
    .unwrap();
    // Re-capture the same content: a new live row, same stable entry_id.
    insert_entry_to_db(
        &conn,
        &ClipboardEntry::text_entry(id_a, "recaptured-content", 2, String::new(), String::new(), 0),
        Some("recaptured-content"),
        None,
        None,
    )
    .unwrap();

    // Undo, modeled on `clipboard_undo_delete`: insert the restored row, dedup
    // against the live set, then drop the deleted row.
    let restored = ClipboardEntry::text_entry(
        id_a, "recaptured-content", 3, String::new(), String::new(), 0,
    );
    let tx = conn.unchecked_transaction().unwrap();
    insert_entry_to_db(&tx, &restored, Some("recaptured-content"), None, None).unwrap();
    crate::db::delete_matching_entry(&tx, &restored, Some("recaptured-content"));
    tx.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![row_a]).unwrap();
    tx.commit().unwrap();

    // Exactly one row now — live.
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

    // Restart: still one row (the old bug showed two here).
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

/// A hard clear (清空历史) removes the deleted rows too: the confirmation the
/// user accepted says the action cannot be undone.
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

    // The clear's transaction (see `clipboard_clear_history`).
    let tx = conn.unchecked_transaction().unwrap();
    tx.execute("DELETE FROM clipboard_history", []).unwrap();
    tx.execute("DELETE FROM clipboard_favorites", []).unwrap();
    tx.commit().unwrap();

    let remaining: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .unwrap();
    assert_eq!(remaining, 0, "clear must remove live and deleted rows alike");

    drop(conn);
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
    }
}
