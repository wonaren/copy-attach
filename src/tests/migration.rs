// Legacy history.json → SQLite migration tests (feature `migration`).

/// The legacy JSON array is ordered newest-first (mirroring the old in-memory
/// history Vec). Migration inserts oldest-first so SQLite rowids increase with
/// age and `ORDER BY id DESC` reproduces the original newest-first order.
#[cfg(feature = "migration")]
#[test]
fn test_legacy_json_migration_assigns_stable_entry_ids() {
    use crate::db::{ensure_history_table, load_history_from_db, migrate_from_json_to_db_at};
    use crate::types::ClipboardEntry;

    let dir = std::env::temp_dir().join(format!("copyattach_migtest_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let json_path = dir.join("history.json");
    std::fs::write(&json_path, r#"[
        {"Text":{"text":"legacy favorite two","timestamp":300}},
        {"Image":{"png_data":"","width":1,"height":1,"hash":0,"timestamp":200}},
        {"Text":{"text":"legacy favorite one","timestamp":100}}
    ]"#).unwrap();

    let db_path = dir.join("history.db");
    let mut conn = rusqlite::Connection::open(&db_path).unwrap();
    ensure_history_table(&conn).unwrap();
    migrate_from_json_to_db_at(&mut conn, &dir);

    let loaded = load_history_from_db(&conn, 3000);
    assert_eq!(loaded.len(), 3, "all three legacy entries migrated");

    // Migrated rows must carry persisted entry_id == SQLite rowid. Rows left
    // at the default 0 would get a FRESH id from the monotonic counter on
    // every load — favorites are keyed by entry_id and would break on each
    // restart.
    let ids: Vec<u64> = loaded.iter().map(ClipboardEntry::entry_id).collect();
    assert!(ids.iter().all(|id| *id > 0), "migrated entry_ids must be non-zero: {ids:?}");

    // Oldest inserted first → newest JSON entry has the highest rowid and
    // sits at index 0 after `ORDER BY id DESC`.
    assert_eq!(loaded[0].label(), "legacy favorite two");
    assert_eq!(ids[0], 3, "newest entry_id must equal its SQLite rowid");

    // Simulate a restart: a second load must reproduce identical ids.
    let reloaded = load_history_from_db(&conn, 3000);
    let reload_ids: Vec<u64> = reloaded.iter().map(ClipboardEntry::entry_id).collect();
    assert_eq!(ids, reload_ids, "entry_ids must be stable across loads");

    drop(conn);
    let _ = std::fs::remove_dir_all(&dir);
}
