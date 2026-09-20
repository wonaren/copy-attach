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

    // Favorites: favorite e1_id
    let fav_ids = vec![e1_id];

    let mut backup_path = std::env::temp_dir();
    backup_path.push(format!("copyattach-export-{}.cabackup", std::process::id()));
    if backup_path.exists() {
        let _ = std::fs::remove_file(&backup_path);
    }

    // 2. Export backup
    let count = export_backup(&src_conn, &backup_path, &fav_ids).expect("export_backup must succeed");
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

    export_backup(&src_conn, &backup_path, &[item_a_id, item_b_id]).unwrap();

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
    let current_favs: Vec<u64> = vec![];

    let (added_count, merged_favs) = restore_backup_merge(&mut dst_conn, &backup_path, &current_favs)
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
