use crate::ffi::{clipboard_free_string, SnapshotRow};
use rusqlite::Connection;
use super::{ClipboardEntry, insert_text, make_image, make_test_image_rgba, make_text, test_db};

#[test]
fn test_search_fts_case_insensitive_substring() {
    let conn = test_db();
    insert_text(&conn, "Hello World, 剪贴板历史", 100);
    insert_text(&conn, "The quick brown fox jumps", 200);

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

    assert_eq!(crate::db::search_history(&conn, "ap").len(), 1);
    assert_eq!(crate::db::search_history(&conn, "a").len(), 2);
    assert_eq!(crate::db::search_history(&conn, "x").len(), 0);
}

#[test]
fn test_search_like_wildcards_escaped() {
    let conn = test_db();
    insert_text(&conn, "100% complete", 100);
    insert_text(&conn, "100X complete", 200);

    assert_eq!(crate::db::search_history(&conn, "%").len(), 1);
}

#[test]
fn test_search_short_query_matches_full_text_middle() {
    let long = format!("{}MIDDLE{}", "x".repeat(200), "x".repeat(200));
    let conn = test_db();
    insert_text(&conn, &long, 100);

    assert_eq!(crate::db::search_history(&conn, "mi").len(), 1,
        "short query must reach the middle of a long document");
    assert_eq!(crate::db::search_history(&conn, "mid").len(), 1,
        "trigram path agrees on the same middle match");
}

#[test]
fn test_search_reflects_delete() {
    let conn = test_db();
    let db_id = insert_text(&conn, "needle in haystack", 100);
    assert_eq!(crate::db::search_history(&conn, "needle").len(), 1);

    conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![db_id]).unwrap();
    assert!(crate::db::search_history(&conn, "needle").is_empty());
}

#[test]
fn test_search_reflects_bulk_trim() {
    let conn = test_db();
    for i in 0..100 {
        insert_text(&conn, &format!("bulk entry number {i:03}"), i as u64);
    }
    assert_eq!(crate::db::search_history(&conn, "bulk").len(), 100);

    crate::db::trim_db_history(&conn, 10).expect("bulk trim must succeed");
    assert_eq!(crate::db::search_history(&conn, "bulk").len(), 10, "FTS follows bulk trim");
}

#[test]
fn test_search_backfills_preexisting_rows() {
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
fn test_fts_cap_skips_huge_text() {
    use crate::db::FTS_MAX_INDEXED_TEXT_LEN;
    let cap = FTS_MAX_INDEXED_TEXT_LEN as usize;
    let huge = format!(
        "{}MIDDLE-MARKER{}",
        "x".repeat(cap / 2),
        "y".repeat(cap / 2)
    );
    assert!(huge.chars().count() > cap, "test text must exceed the cap");

    let conn = test_db();
    insert_text(&conn, &huge, 100);
    insert_text(&conn, "small needle here", 200);

    let fts_count: i64 = conn
        .query_row("SELECT count(*) FROM clipboard_fts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(fts_count, 1, "only the small text may be trigram-indexed");

    assert_eq!(crate::db::search_history(&conn, "marker").len(), 1,
        "huge un-indexed text must stay searchable via the LIKE fallback");
    assert_eq!(crate::db::search_history(&conn, "needle").len(), 1);
}

#[test]
fn test_fts_cap_legacy_oversized_rows_evicted() {
    use crate::db::FTS_MAX_INDEXED_TEXT_LEN;
    let cap = FTS_MAX_INDEXED_TEXT_LEN as usize;
    let huge = format!("{}LEGACY-HUGE{}", "a".repeat(cap / 2), "b".repeat(cap / 2));

    let conn = test_db();
    let db_id = insert_text(&conn, &huge, 100);
    let entry_id: i64 = conn
        .query_row(
            "SELECT entry_id FROM clipboard_history WHERE id = ?1",
            rusqlite::params![db_id],
            |r| r.get(0),
        )
        .unwrap();

    conn.execute(
        "INSERT INTO clipboard_fts(rowid, text)
         SELECT id, text FROM clipboard_history WHERE id = ?1",
        rusqlite::params![db_id],
    ).unwrap();
    let fts_count: i64 = conn
        .query_row("SELECT count(*) FROM clipboard_fts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(fts_count, 1, "precondition: legacy oversized row is indexed");

    crate::db::ensure_history_table(&conn).unwrap();
    let fts_count: i64 = conn
        .query_row("SELECT count(*) FROM clipboard_fts", [], |r| r.get(0))
        .unwrap();
    assert_eq!(fts_count, 0, "oversized legacy row must be evicted from FTS");

    let hits = crate::db::search_history(&conn, "huge");
    assert_eq!(hits.len(), 1, "evicted row must stay searchable");
    assert_eq!(hits[0] as i64, entry_id);
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
    let long = make_text(&"x".repeat(1000), 200);
    let row = SnapshotRow::from_entry(&long);
    assert_eq!(row.preview.chars().count(), 256);
    assert!(row.label.chars().count() <= 61);
}

#[test]
fn test_snapshot_row_text_bounded_preview_keeps_tail() {
    let text = format!("{}结尾标记", "填充内容".repeat(100));
    let row = SnapshotRow::from_entry(&make_text(&text, 300));
    assert!(row.preview.ends_with("结尾标记"), "preview lost the tail: {}", row.preview);
    assert!(row.preview.chars().count() <= 256);
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

#[test]
fn test_search_matches_label_custom_label_and_source_name() {
    let conn = test_db();

    conn.execute(
        "INSERT INTO clipboard_history
            (entry_type, text, label, custom_label, source_name, source_bundle_id, entry_id, timestamp)
         VALUES (0, 'content-alpha', 'Alpha Document', 'Important Work', 'Safari', 'com.apple.Safari', 5001, 100)",
        [],
    ).unwrap();

    conn.execute(
        "INSERT INTO clipboard_history
            (entry_type, custom_label, source_name, source_bundle_id, entry_id, timestamp)
         VALUES (1, 'Architecture Diagram', 'Photoshop', 'com.adobe.photoshop', 5002, 200)",
        [],
    ).unwrap();

    let res = crate::db::search_history(&conn, "content-alpha");
    assert_eq!(res, vec![5001]);

    let res = crate::db::search_history(&conn, "Alpha");
    assert_eq!(res, vec![5001]);

    let res = crate::db::search_history(&conn, "Important");
    assert_eq!(res, vec![5001]);

    let res = crate::db::search_history(&conn, "Safari");
    assert_eq!(res, vec![5001]);

    let res = crate::db::search_history(&conn, "1920");
    assert!(res.is_empty(), "image size must not be searchable, got {res:?}");

    let res = crate::db::search_history(&conn, "Architecture");
    assert_eq!(res, vec![5002]);

    let res = crate::db::search_history(&conn, "Photoshop");
    assert_eq!(res, vec![5002]);

    let res_ph = crate::db::search_history(&conn, "Ph");
    assert_eq!(res_ph, vec![5001, 5002]);

    let res_19 = crate::db::search_history(&conn, "19");
    assert!(res_19.is_empty(), "image size must not be searchable, got {res_19:?}");
}

#[test]
fn test_image_dimensions_are_not_searchable_via_insert_path() {
    let conn = test_db();
    let rgba = make_test_image_rgba(64, 48, 7);
    let entry = make_image(&rgba, 64, 48, 900);
    let png = crate::image::encode_png(64, 48, &rgba).unwrap();
    let thumb = crate::image::create_thumbnail(64, 48, &rgba).unwrap();
    let (tw, th) = match &entry {
        ClipboardEntry::Image { thumb_width, thumb_height, .. } => (*thumb_width, *thumb_height),
        _ => unreachable!("make_image must produce an image entry"),
    };
    crate::db::insert_entry_to_db(&conn, &entry, None, Some(&png), Some((&thumb.0, tw, th)))
        .expect("insert image");

    let (count, label): (i64, String) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(MAX(label), '') FROM clipboard_history WHERE entry_type = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(count, 1, "image row should be persisted");
    assert_eq!(label, "", "image rows must not persist a label");

    for q in ["64", "48", "64×48", "Image"] {
        let res = crate::db::search_history(&conn, q);
        assert!(
            res.is_empty(),
            "query {q:?} must not match an image by size/label, got {res:?}"
        );
    }
}
