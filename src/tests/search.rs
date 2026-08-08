// Full-text search tests (FTS5 trigram + LIKE fallback) and snapshot row tests.

use crate::ffi::{clipboard_free_string, SnapshotRow};
use rusqlite::Connection;
use super::{insert_text, make_image, make_test_image_rgba, make_text, test_db};

#[test]
fn test_search_fts_case_insensitive_substring() {
    let conn = test_db();
    insert_text(&conn, "Hello World, 剪贴板历史", 100);
    insert_text(&conn, "The quick brown fox jumps", 200);

    // ≥3-char queries go through the trigram index: substring match, ASCII fold.
    assert_eq!(crate::db::search_history(&conn, "world").len(), 1);
    assert_eq!(crate::db::search_history(&conn, "WORLD").len(), 1, "trigram folds ASCII case");
    assert_eq!(crate::db::search_history(&conn, "剪贴板").len(), 1, "CJK substring match");
    assert!(crate::db::search_history(&conn, "不存在").is_empty());
}

#[test]
fn test_search_short_query_like_fallback() {
    let conn = test_db();
    insert_text(&conn, "apple pie", 100);
    insert_text(&conn, "cherry tart", 200);

    // <3-char queries cannot form a trigram — LIKE fallback, still substring.
    assert_eq!(crate::db::search_history(&conn, "ap").len(), 1);
    assert_eq!(crate::db::search_history(&conn, "a").len(), 2);
    assert_eq!(crate::db::search_history(&conn, "x").len(), 0);
}

#[test]
fn test_search_like_wildcards_escaped() {
    let conn = test_db();
    insert_text(&conn, "100% complete", 100);
    insert_text(&conn, "100X complete", 200);

    // '%' in the query is a literal percent, not a LIKE wildcard.
    assert_eq!(crate::db::search_history(&conn, "%").len(), 1);
}

#[test]
fn test_search_reflects_delete() {
    let conn = test_db();
    let db_id = insert_text(&conn, "needle in haystack", 100);
    assert_eq!(crate::db::search_history(&conn, "needle").len(), 1);

    // The AFTER DELETE trigger must remove the row from the FTS index too.
    conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![db_id]).unwrap();
    assert!(crate::db::search_history(&conn, "needle").is_empty());
}

#[test]
fn test_search_reflects_bulk_trim() {
    // trim_db_history deletes many rows in one statement; the AFTER DELETE
    // trigger fires per row, so the FTS index must shrink to the kept set.
    let conn = test_db();
    for i in 0..100 {
        insert_text(&conn, &format!("bulk entry number {i:03}"), i as u64);
    }
    assert_eq!(crate::db::search_history(&conn, "bulk").len(), 100);

    crate::db::trim_db_history(&conn, 10);
    assert_eq!(crate::db::search_history(&conn, "bulk").len(), 10, "FTS follows bulk trim");
}

#[test]
fn test_search_backfills_preexisting_rows() {
    // Rows inserted before the FTS table existed must be searchable after
    // ensure_history_table runs (the guarded one-time backfill).
    let conn = Connection::open_in_memory().unwrap();
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
         VALUES (0, 'legacy content worth finding', 100)",
        [],
    ).unwrap();

    crate::db::ensure_history_table(&conn).unwrap();

    assert_eq!(crate::db::search_history(&conn, "finding").len(), 1);
}

#[test]
fn test_snapshot_row_text() {
    let t = make_text("第一行\n第二行很长很长的内容", 100);
    let row = SnapshotRow::from_entry(&t);
    assert_eq!(row.entry_type, 0);
    assert_eq!(row.id, t.entry_id() as i64);
    assert_eq!(row.timestamp, 100);
    assert_eq!(row.label, "第一行");
    assert_eq!(row.preview, "第一行\n第二行很长很长的内容");
    assert_eq!(row.source_name, "");
    assert_eq!(row.db_id, 0);
}

#[test]
fn test_snapshot_row_text_bounded_preview() {
    // Multi-KB text must not leak into the snapshot: preview is capped at 256
    // scalars and label at the truncated first line.
    let long = make_text(&"x".repeat(1000), 200);
    let row = SnapshotRow::from_entry(&long);
    assert_eq!(row.preview.chars().count(), 256);
    assert!(row.label.chars().count() <= 61);
}

#[test]
fn test_snapshot_row_image() {
    let img_data = make_test_image_rgba(1920, 1080, 128);
    let i = make_image(&img_data, 1920, 1080, 300);
    let row = SnapshotRow::from_entry(&i);
    assert_eq!(row.entry_type, 1);
    assert_eq!(row.id, i.entry_id() as i64);
    assert_eq!(row.timestamp, 300);
    assert_eq!(row.label, "Image (1920×1080)");
    assert!(row.preview.is_empty());
    assert_eq!(row.width, 1920);
    assert_eq!(row.height, 1080);
}

#[test]
fn test_free_string_null_safe() {
    clipboard_free_string(std::ptr::null_mut());
}
