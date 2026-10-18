use std::collections::HashSet;
use std::path::PathBuf;
use rusqlite::Connection;

use crate::backend::new_entry_id;
use crate::db::backup::{export_backup, inspect_backup, restore_backup_merge, restore_backup_overwrite};
use crate::db::{ensure_history_table, insert_entry_to_db, load_history_from_db, search_history};
use crate::image::image_hash;
use crate::types::ClipboardEntry;

fn make_temp_db(name: &str) -> (PathBuf, Connection) {
    let mut dir = std::env::temp_dir();
    dir.push(format!("copyattach-test-backup-{}-{}", name, std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("test.db");
    if path.exists() {
        let _ = std::fs::remove_file(&path);
    }
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;"
    ).unwrap();
    ensure_history_table(&conn).unwrap();
    (path, conn)
}

#[test]
fn test_backup_export_inspect_and_overwrite() {
    let (_src_path, src_conn) = make_temp_db("src");
    let now = 1700000000u64;

    // 1. Seed source DB with text and image entries with custom remarks
    let e1_id = new_entry_id();
    let text1 = "重要的备忘录与账号信息";
    let mut e1 = ClipboardEntry::text_entry(
        e1_id,
        text1,
        now,
        "Notes".to_string(),
        "com.apple.Notes".to_string(),
        0,
    );
    if let ClipboardEntry::Text { ref mut custom_label, .. } = e1 {
        *custom_label = "账号备注".to_string();
    }
    insert_entry_to_db(&src_conn, &e1, Some(text1), None, None).unwrap();

    let e2_id = new_entry_id();
    let dummy_png = b"test_png_bytes_fake_for_backup";
    let dummy_thumb = b"test_thumb_bytes";
    let img_hash = image_hash(dummy_png, 800, 600);
    let e2 = ClipboardEntry::Image {
        id: e2_id,
        width: 800,
        height: 600,
        thumb_width: 200,
        thumb_height: 150,
        hash: img_hash,
        custom_label: "设计草图备注".to_string(),
        timestamp: now + 10,
        source_name: "Figma".to_string(),
        source_bundle_id: "com.figma.Desktop".to_string(),
        db_id: 0,
    };
    insert_entry_to_db(
        &src_conn,
        &e2,
        None,
        Some(dummy_png),
        Some((dummy_thumb, 200, 150)),
    ).unwrap();

    // Favorites: favorite e1_id in the durable table
    crate::db::set_favorite(&src_conn, e1_id, true).expect("favorite e1");

    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-export-{}.cabackup", std::process::id()));
    if backup_path.exists() {
        let _ = std::fs::remove_file(&backup_path);
    }

    // 2. Export backup
    let count = export_backup(&src_conn, &backup_path).expect("export_backup must succeed");
    assert_eq!(count, 2, "must export 2 items");

    // 3. Inspect backup
    let info = inspect_backup(&backup_path).expect("inspect_backup must succeed");
    assert_eq!(info.item_count, 2);
    assert_eq!(info.favorite_count, 1);
    assert!(info.timestamp > 0);

    // 4. Overwrite restore into fresh destination DB
    let (_dst_path, mut dst_conn) = make_temp_db("dst");
    let (restored_count, restored_favs) = restore_backup_overwrite(&mut dst_conn, &backup_path)
        .expect("restore_backup_overwrite must succeed");

    assert_eq!(restored_count, 2);
    assert_eq!(restored_favs, vec![e1_id]);

    let loaded = load_history_from_db(&dst_conn, 100);
    assert_eq!(loaded.len(), 2);

    // Verify remarks preserved
    let text_row = loaded.iter().find(|e| matches!(e, ClipboardEntry::Text { .. })).unwrap();
    if let ClipboardEntry::Text { custom_label, .. } = text_row {
        assert_eq!(custom_label, "账号备注");
    } else {
        panic!("expected text row");
    }

    let img_row = loaded.iter().find(|e| matches!(e, ClipboardEntry::Image { .. })).unwrap();
    if let ClipboardEntry::Image { custom_label, width, height, .. } = img_row {
        assert_eq!(custom_label, "设计草图备注");
        assert_eq!(*width, 800);
        assert_eq!(*height, 600);
    } else {
        panic!("expected image row");
    }

    // Verify FTS search index works after rebuild
    let search_results = search_history(&dst_conn, "备忘录");
    assert_eq!(search_results.len(), 1);

    // Clean up
    let _ = std::fs::remove_file(&backup_path);
}

#[test]
fn test_backup_restore_merge_behavior() {
    let (_src_path, src_conn) = make_temp_db("merge_src");
    let now = 1700000000u64;

    // Item A in backup: has remark "备份中的备注" and is favorited
    let item_a_id = new_entry_id();
    let text_a = "合并测试条目 A (相同内容)";
    let mut item_a = ClipboardEntry::text_entry(
        item_a_id,
        text_a,
        now,
        "AppA".to_string(),
        "com.app.a".to_string(),
        0,
    );
    if let ClipboardEntry::Text { ref mut custom_label, .. } = item_a {
        *custom_label = "备份中的备注".to_string();
    }
    insert_entry_to_db(&src_conn, &item_a, Some(text_a), None, None).unwrap();

    // Item B in backup: new item, not in active DB
    let item_b_id = new_entry_id();
    let text_b = "仅在备份中的独立条目 B";
    let item_b = ClipboardEntry::text_entry(
        item_b_id,
        text_b,
        now + 5,
        "AppB".to_string(),
        "com.app.b".to_string(),
        0,
    );
    insert_entry_to_db(&src_conn, &item_b, Some(text_b), None, None).unwrap();

    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-merge-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);

    crate::db::set_favorite(&src_conn, item_a_id, true).unwrap();
    crate::db::set_favorite(&src_conn, item_b_id, true).unwrap();
    export_backup(&src_conn, &backup_path).unwrap();

    // Destination DB already has Item A without remark
    let (_dst_path, mut dst_conn) = make_temp_db("merge_dst");
    let dst_item_a_id = new_entry_id();
    let dst_item_a = ClipboardEntry::text_entry(
        dst_item_a_id,
        text_a,
        now,
        "AppA".to_string(),
        "com.app.a".to_string(),
        0,
    );
    insert_entry_to_db(&dst_conn, &dst_item_a, Some(text_a), None, None).unwrap();

    // Active favorites has none initially
    let (added_count, merged_favs) = restore_backup_merge(&mut dst_conn, &backup_path)
        .expect("restore_backup_merge must succeed");

    // Only Item B was newly inserted (Item A was deduplicated and updated)
    assert_eq!(added_count, 1);

    let fav_set: HashSet<u64> = merged_favs.into_iter().collect();
    // dst_item_a_id should now be favorited because it matched Item A in backup!
    assert!(fav_set.contains(&dst_item_a_id), "existing item A must adopt favorite status");

    let loaded = load_history_from_db(&dst_conn, 100);
    assert_eq!(loaded.len(), 2);

    let updated_a = loaded.iter().find(|e| match e {
        ClipboardEntry::Text { preview, .. } => preview.contains("条目 A"),
        _ => false,
    }).unwrap();
    if let ClipboardEntry::Text { custom_label, .. } = updated_a {
        assert_eq!(custom_label, "备份中的备注", "remark must be merged into existing item");
    }

    let _ = std::fs::remove_file(&backup_path);
}

#[test]
fn test_backup_inspect_invalid_file() {
    let mut invalid_file = std::env::temp_dir();
    invalid_file.push(format!("copyattach-invalid-{}.cabackup", std::process::id()));
    std::fs::write(&invalid_file, b"this is not a sqlite database").unwrap();

    let res = inspect_backup(&invalid_file);
    assert!(res.is_err(), "inspect_backup must reject non-sqlite file");

    let non_existent = PathBuf::from("/tmp/non-existent-backup-file-12345.cabackup");
    assert!(inspect_backup(&non_existent).is_err(), "inspect_backup must reject missing file");

    let _ = std::fs::remove_file(&invalid_file);
}

// ─── Regression tests for the restore/merge defects found in review ───
//
// Each of these failed against the code as shipped in v0.107.0.

/// Merge must not push the user's own (newer) rows out of the visible window.
///
/// `restore_backup_merge` inserts without an explicit `id`, so merged rows get
/// the largest rowids. The list is ordered newest-first, and the trim deletes
/// from the old end — both keyed on row order. Merging older history therefore
/// buried the local rows and then evicted them first.
#[test]
fn test_merge_keeps_local_rows_visible_and_newest_first() {
    let (_src_path, src_conn) = make_temp_db("order_src");
    // Backup holds OLD rows.
    let mut old_ids = Vec::new();
    for i in 0..3u64 {
        let e = ClipboardEntry::text_entry(new_entry_id(), &format!("backup-old-{i}"), 1_700_000_000 + i,
                                           "App".into(), "com.a".into(), 0);
        old_ids.push(e.entry_id());
        insert_entry_to_db(&src_conn, &e, Some(&format!("backup-old-{i}")), None, None).unwrap();
    }
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-order-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    assert_eq!(old_ids.len(), 3);

    // Destination holds NEWER rows.
    let (_dst_path, mut dst_conn) = make_temp_db("order_dst");
    for i in 0..3u64 {
        let e = ClipboardEntry::text_entry(new_entry_id(), &format!("local-new-{i}"), 1_780_000_000 + i,
                                           "App".into(), "com.a".into(), 0);
        insert_entry_to_db(&dst_conn, &e, Some(&format!("local-new-{i}")), None, None).unwrap();
    }

    let (added, _favs) = restore_backup_merge(&mut dst_conn, &backup_path).unwrap();
    assert_eq!(added, 3, "all three backup rows are new to this DB");

    // The list the UI shows, newest-first.
    let loaded = load_history_from_db(&dst_conn, 3000);
    assert_eq!(loaded.len(), 6);

    // Newest-first by TIMESTAMP: the local rows are newer, so they lead.
    let labels: Vec<String> = loaded.iter().map(|e| e.label().to_string()).collect();
    let first_local = labels.iter().position(|l| l.starts_with("local-new")).unwrap();
    let last_backup = labels.iter().rposition(|l| l.starts_with("backup-old")).unwrap();
    assert!(first_local < last_backup,
        "local (newer) rows must sort above merged (older) rows; got {labels:?}");

    // And a trim to the local count must evict the OLD merged rows, not the local ones.
    crate::db::trim_db_history(&dst_conn, 3).unwrap();
    let kept = load_history_from_db(&dst_conn, 3000);
    assert_eq!(kept.len(), 3);
    assert!(kept.iter().all(|e| e.label().starts_with("local-new")),
        "trim must drop the oldest rows (the merged ones); kept {:?}",
        kept.iter().map(|e| e.label()).collect::<Vec<_>>());

    let _ = std::fs::remove_file(&backup_path);
}

/// Overwrite restore must never LOWER the persisted entry-id watermark.
///
/// The shipped code copied the backup's `clipboard_meta` over the local one and
/// then called `bump_entry_id_watermark`, which is `MAX(value, excluded)` — so
/// the overwrite won and ids the local favorites still reference could be
/// re-issued to unrelated new captures.
#[test]
fn test_overwrite_restore_never_lowers_entry_id_watermark() {
    let (_src_path, src_conn) = make_temp_db("wm_src");
    let e = ClipboardEntry::text_entry(new_entry_id(), "from-backup", 1_700_000_000,
                                       "App".into(), "com.a".into(), 0);
    insert_entry_to_db(&src_conn, &e, Some("from-backup"), None, None).unwrap();
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-wm-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    // Destination: a row carrying a very high entry id, and a watermark above it.
    let (_dst_path, mut dst_conn) = make_temp_db("wm_dst");
    let high = 900_000u64;
    let hi = ClipboardEntry::text_entry(high, "local-high-id", 1_780_000_000,
                                        "App".into(), "com.a".into(), 0);
    insert_entry_to_db(&dst_conn, &hi, Some("local-high-id"), None, None).unwrap();
    crate::db::bump_entry_id_watermark(&dst_conn, high).unwrap();
    assert_eq!(crate::db::entry_id_watermark(&dst_conn), high);

    restore_backup_overwrite(&mut dst_conn, &backup_path).unwrap();

    let after = crate::db::entry_id_watermark(&dst_conn);
    assert!(after >= high,
        "watermark must not drop below the pre-restore value {high}; got {after}");

    // The concrete hazard: `ffi::init` primes the id counter from
    // `max(loaded rows' max entry_id, watermark)`, so a watermark below the
    // pre-restore value is what would let a new capture reuse a favorite's id.
    // (The process-global counter itself is primed by the FFI layer, not by
    // this function, so it is not the thing to assert on here.)
    let max_present: u64 = dst_conn
        .query_row("SELECT COALESCE(MAX(entry_id), 0) FROM clipboard_history", [], |r| r.get::<_, i64>(0))
        .unwrap() as u64;
    assert!(after >= max_present,
        "watermark {after} must cover every entry_id present ({max_present})");

    let _ = std::fs::remove_file(&backup_path);
}

/// Merge must leave the persisted watermark at or above every id in the DB,
/// even when no new row was inserted (everything deduplicated).
#[test]
fn test_merge_raises_watermark_to_max_present_id() {
    let (_src_path, src_conn) = make_temp_db("mw_src");
    let high = 800_000u64;
    let e = ClipboardEntry::text_entry(high, "high-id-row", 1_700_000_000,
                                       "App".into(), "com.a".into(), 0);
    insert_entry_to_db(&src_conn, &e, Some("high-id-row"), None, None).unwrap();
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-mw-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    // Destination has a low watermark and an empty table.
    let (_dst_path, mut dst_conn) = make_temp_db("mw_dst");
    crate::db::bump_entry_id_watermark(&dst_conn, 10).unwrap();
    assert_eq!(crate::db::entry_id_watermark(&dst_conn), 10);

    let (added, _favs) = restore_backup_merge(&mut dst_conn, &backup_path).unwrap();
    assert_eq!(added, 1, "the backup row is new here");

    let max_present: u64 = dst_conn
        .query_row("SELECT COALESCE(MAX(entry_id), 0) FROM clipboard_history", [], |r| r.get::<_, i64>(0))
        .unwrap() as u64;
    let watermark = crate::db::entry_id_watermark(&dst_conn);
    assert!(watermark >= max_present,
        "watermark {watermark} must cover the max entry_id present ({max_present})");

    let _ = std::fs::remove_file(&backup_path);
}

/// A merge that inserts nothing must still raise the watermark over ids the
/// backup carried but that were deduplicated away.
#[test]
fn test_merge_dedup_only_still_covers_backup_ids() {
    let (_src_path, src_conn) = make_temp_db("dd_src");
    let high = 700_000u64;
    let text = "identical-content-both-sides";
    let e = ClipboardEntry::text_entry(high, text, 1_700_000_000, "App".into(), "com.a".into(), 0);
    insert_entry_to_db(&src_conn, &e, Some(text), None, None).unwrap();
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-dd-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    let (_dst_path, mut dst_conn) = make_temp_db("dd_dst");
    let local = ClipboardEntry::text_entry(new_entry_id(), text, 1_780_000_000, "App".into(), "com.a".into(), 0);
    insert_entry_to_db(&dst_conn, &local, Some(text), None, None).unwrap();

    let (added, _favs) = restore_backup_merge(&mut dst_conn, &backup_path).unwrap();
    assert_eq!(added, 0, "same content on both sides must dedup");

    let watermark = crate::db::entry_id_watermark(&dst_conn);
    assert!(watermark >= high,
        "watermark {watermark} must cover the deduplicated backup id {high}");

    let _ = std::fs::remove_file(&backup_path);
}

/// A backup archive with no `clipboard_meta` table must restore without
/// silently aborting the meta step.
///
/// `backup_db.clipboard_meta` is resolved at PREPARE time, so the previous
/// `... AND EXISTS (SELECT 1 FROM backup_db.sqlite_master ...)` guard did not
/// protect it: the statement failed to prepare, `execute_batch` aborted the
/// whole batch at the first error (so the `CREATE TABLE IF NOT EXISTS
/// main.clipboard_meta` ahead of it never applied either), and `let _ =` threw
/// the error away. The destination was left with no meta table at all.
#[test]
fn test_overwrite_restore_tolerates_archive_without_meta_table() {
    // Build a source DB, export it, then strip clipboard_meta to simulate an
    // archive written by an older build that had no meta table.
    let (_src_path, src_conn) = make_temp_db("nometa_src");
    let e = ClipboardEntry::text_entry(
        new_entry_id(),
        "no-meta-row",
        1_700_000_000,
        "App".into(),
        "com.a".into(),
        0,
    );
    insert_entry_to_db(&src_conn, &e, Some("no-meta-row"), None, None).unwrap();
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-nometa-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    {
        let raw = Connection::open(&backup_path).unwrap();
        raw.execute_batch("DROP TABLE IF EXISTS clipboard_meta;").unwrap();
        let remaining: i64 = raw
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_meta'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 0, "fixture must have no clipboard_meta");
    }

    let (_dst_path, mut dst_conn) = make_temp_db("nometa_dst");
    let res = restore_backup_overwrite(&mut dst_conn, &backup_path);
    assert!(
        res.is_ok(),
        "restore of a meta-less archive must succeed, got {res:?}"
    );

    // The rows must be there.
    let loaded = load_history_from_db(&dst_conn, 100);
    assert_eq!(loaded.len(), 1, "the archived row must be restored");

    // And the destination must have a usable meta table afterwards, not a
    // missing one (which is what the swallowed batch left behind).
    let has_meta: i64 = dst_conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clipboard_meta'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(has_meta, 1, "restore must leave a usable clipboard_meta table");

    let _ = std::fs::remove_file(&backup_path);
}

/// Exporting over a path that has a leftover `-wal` must not let the old WAL
/// leak into the new snapshot.
///
/// `VACUUM INTO` writes a fresh database, but SQLite replays a `-wal` that sits
/// beside a database file. Without purging the sidecar first, a reader of the
/// exported file saw the OLD WAL's contents layered over the new snapshot.
#[test]
fn test_export_over_existing_wal_does_not_leak_old_rows() {
    let (_src_path, src_conn) = make_temp_db("wal_src");
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-wal-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);

    // First export: one row.
    let first = ClipboardEntry::text_entry(
        new_entry_id(),
        "OLD-WAL-CONTENT",
        1_700_000_000,
        "App".into(),
        "com.a".into(),
        0,
    );
    insert_entry_to_db(&src_conn, &first, Some("OLD-WAL-CONTENT"), None, None).unwrap();
    export_backup(&src_conn, &backup_path).unwrap();

    // Forge a stale sidecar beside the target, as a crashed earlier export
    // would leave behind.
    let mut wal_path = backup_path.as_os_str().to_os_string();
    wal_path.push("-wal");
    let wal_path = PathBuf::from(wal_path);
    std::fs::write(&wal_path, b"stale-wal-bytes").unwrap();

    // Second export with different content.
    let second = ClipboardEntry::text_entry(
        new_entry_id(),
        "NEW-CONTENT",
        1_780_000_000,
        "App".into(),
        "com.a".into(),
        0,
    );
    insert_entry_to_db(&src_conn, &second, Some("NEW-CONTENT"), None, None).unwrap();
    let count = export_backup(&src_conn, &backup_path).unwrap();
    assert_eq!(count, 2, "both rows must be exported");

    assert!(
        !wal_path.exists(),
        "the stale -wal sidecar must be purged, else readers replay it"
    );

    // The archive must read back as a clean database with both rows.
    let check = Connection::open(&backup_path).unwrap();
    let n: i64 = check
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 2, "exported archive must hold exactly the two current rows");

    let _ = std::fs::remove_file(&backup_path);
}

/// Peak-RSS regression guard for the merge path.
///
/// The merge used to collect every backup row into a `Vec<RawBackupRow>` before
/// inserting any of them, so the whole archive's blobs were resident at once.
/// Measured on a 570 MB / 10 000-row archive that was +588 MB peak RSS — on a
/// 16 GB machine, the difference between a restore and a memory event. Rows are
/// now streamed from the backup cursor one at a time.
///
/// Ignored by default: it builds a multi-hundred-MB fixture and is a
/// measurement, not a fast assertion. Run with:
///     cargo test --lib -- --ignored --nocapture test_merge_peak_rss
#[test]
#[ignore]
fn test_merge_peak_rss() {
    use std::time::Instant;

    fn rss_kb() -> u64 {
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &std::process::id().to_string()])
            .output()
            .expect("ps");
        String::from_utf8_lossy(&out.stdout).trim().parse().expect("rss")
    }
    fn peak_kb() -> u64 {
        let out = std::process::Command::new("ps")
            .args(["-o", "rss=", "-p", &std::process::id().to_string()])
            .output()
            .expect("ps");
        String::from_utf8_lossy(&out.stdout).trim().parse().unwrap_or(0)
    }

    // ~570 MB of payload: 10 000 rows, ~57 KB each.
    const ROWS: usize = 10_000;
    const BLOB: usize = 56 * 1024;

    let (_src_path, src_conn) = make_temp_db("rss_src");
    let big: Vec<u8> = (0..BLOB).map(|i| (i % 251) as u8).collect();
    let thumb = b"thumb-payload".to_vec();

    for i in 0..ROWS {
        let e = ClipboardEntry::Image {
            id: new_entry_id(),
            width: BLOB as u32,
            height: 200,
            thumb_width: 200,
            thumb_height: 100,
            hash: (i as u64).wrapping_mul(2_654_435_761).wrapping_add(1),
            custom_label: String::new(),
            timestamp: 1_700_000_000 + i as u64,
            source_name: "App".into(),
            source_bundle_id: "com.a".into(),
            db_id: 0,
        };
        insert_entry_to_db(
            &src_conn,
            &e,
            None,
            Some(&big),
            Some((&thumb, 200, 100)),
        )
        .unwrap();
    }

    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-rss-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();
    let archive_mb = std::fs::metadata(&backup_path).unwrap().len() as f64 / 1_048_576.0;

    let (_dst_path, mut dst_conn) = make_temp_db("rss_dst");
    let base = rss_kb();
    let t0 = Instant::now();
    let (added, _favs) = restore_backup_merge(&mut dst_conn, &backup_path).unwrap();
    let elapsed = t0.elapsed();
    let after = peak_kb();

    println!(
        "[merge-rss] archive={:.1} MB rows={ROWS} added={added} elapsed={:.2}s rss: base={} KB after={} KB delta=+{} MB",
        archive_mb,
        elapsed.as_secs_f64(),
        base,
        after,
        (after.saturating_sub(base)) / 1024
    );

    assert_eq!(added, ROWS, "every archived row must merge in");
    // The whole archive can no longer be resident: a streaming merge holds at
    // most one row's blobs plus SQLite's own caches. Allow generous headroom
    // (2x the largest single row) but fail loudly if the whole payload lands.
    let delta_mb = (after.saturating_sub(base)) / 1024;
    assert!(
        delta_mb < (archive_mb * 0.5) as u64,
        "merge peak RSS grew by {delta_mb} MB against a {archive_mb:.1} MB archive — \
         looks like the rows are being materialized again"
    );

    let _ = std::fs::remove_file(&backup_path);
}

/// The FTS index must be searchable after a restore *without* an explicit
/// `INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')`.
///
/// `ensure_history_table` installs AFTER INSERT / AFTER DELETE triggers that
/// keep the index in sync, and they fire for the restore's own writes too
/// (`INSERT ... SELECT` fires INSERT triggers; the preceding `DELETE` fires the
/// delete trigger). The explicit rebuild was therefore redundant work: measured
/// 69 ms on a 6 000-text-row fixture, paid while holding the DB mutex that the
/// capture path also needs. This test pins the trigger-only contract so the
/// rebuild cannot be reintroduced "for safety".
#[test]
fn test_search_works_after_restore_without_explicit_rebuild() {
    let (_src_path, src_conn) = make_temp_db("fts_src");
    let needle = "zzneedlezz-unique-marker";
    for (i, body) in [needle, "ordinary row one", "ordinary row two"].iter().enumerate() {
        let e = ClipboardEntry::text_entry(
            new_entry_id(),
            body,
            1_700_000_000 + i as u64,
            "App".into(),
            "com.a".into(),
            0,
        );
        insert_entry_to_db(&src_conn, &e, Some(body), None, None).unwrap();
    }
    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-fts-{}.cabackup", std::process::id()));
    let _ = std::fs::remove_file(&backup_path);
    export_backup(&src_conn, &backup_path).unwrap();

    // Overwrite path: DELETE + INSERT..SELECT must leave FTS consistent.
    let (_dst_path, mut dst_conn) = make_temp_db("fts_dst");
    restore_backup_overwrite(&mut dst_conn, &backup_path).unwrap();
    let hits = search_history(&dst_conn, needle);
    assert_eq!(
        hits.len(),
        1,
        "overwrite restore must leave the FTS index searchable (triggers, no explicit rebuild)"
    );

    // Merge path: plain INSERTs must leave FTS consistent too.
    let (_m_path, mut merge_conn) = make_temp_db("fts_merge");
    let (added, _f) = restore_backup_merge(&mut merge_conn, &backup_path).unwrap();
    assert_eq!(added, 3, "all three rows must merge in");
    let hits = search_history(&merge_conn, needle);
    assert_eq!(
        hits.len(),
        1,
        "merge restore must leave the FTS index searchable (triggers, no explicit rebuild)"
    );

    let _ = std::fs::remove_file(&backup_path);
}
