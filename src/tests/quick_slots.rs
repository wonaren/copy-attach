use super::{insert_text, test_db};
use crate::db::{
    ensure_history_table, insert_entry_to_db, load_history_from_db, load_quick_slots,
    toggle_quick_slot, trim_db_history, QUICK_SLOT_COUNT,
};
use crate::types::ClipboardEntry;

fn entry_id_of(conn: &rusqlite::Connection, row_id: i64) -> u64 {
    conn.query_row(
        "SELECT entry_id FROM clipboard_history WHERE id = ?1",
        rusqlite::params![row_id],
        |r| r.get::<_, i64>(0),
    )
    .expect("row entry_id") as u64
}

#[test]
fn test_schema_adds_was_slot_to_existing_deleted_table() {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "CREATE TABLE clipboard_deleted (
             row_id       INTEGER PRIMARY KEY,
             entry_id     INTEGER NOT NULL,
             deleted_at   INTEGER NOT NULL,
             was_favorite INTEGER NOT NULL DEFAULT 0
         );",
    )
    .unwrap();

    ensure_history_table(&conn).expect("migration must add the column, not fail");

    conn.prepare("SELECT was_slot FROM clipboard_deleted LIMIT 0")
        .expect("was_slot column must exist after migration");
    conn.prepare("SELECT slot, entry_id FROM clipboard_quick_slots LIMIT 0")
        .expect("quick-slot table must exist after migration");
    ensure_history_table(&conn).expect("schema setup must stay idempotent");
}

#[test]
fn test_quick_slot_protects_entry_from_trim_and_loads_without_it() {
    let conn = test_db();
    let pinned_row = insert_text(&conn, "pinned phrase", 1);
    let pinned_id = entry_id_of(&conn, pinned_row);
    for i in 0..10 {
        insert_text(&conn, &format!("filler-{i}"), 100 + i);
    }
    toggle_quick_slot(&conn, pinned_id, 1).expect("bind quick slot");

    trim_db_history(&conn, 3).expect("trim");

    let live: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .unwrap();
    assert_eq!(live, 4, "three unprotected rows plus the protected one");
    let loaded = load_history_from_db(&conn, 3);
    assert_eq!(loaded.len(), 4);
    assert!(
        loaded.iter().any(|e| e.entry_id() == pinned_id),
        "slot-bound entry must survive the threshold trim"
    );

    let slots = load_quick_slots(&conn).unwrap();
    assert_eq!(slots[0], pinned_id);
}

#[test]
fn test_quick_slot_follows_dedup_survivor() {
    let conn = test_db();
    let old = ClipboardEntry::text_entry(100, "same content", 10, String::new(), String::new(), 0);
    insert_entry_to_db(&conn, &old, Some("same content"), None, None).expect("insert old");
    toggle_quick_slot(&conn, 100, 2).expect("bind old");

    let new = ClipboardEntry::text_entry(200, "same content", 20, String::new(), String::new(), 0);
    insert_entry_to_db(&conn, &new, Some("same content"), None, None).expect("insert new");
    crate::db::delete_matching_entry(&conn, &new, Some("same content"));

    let slots = load_quick_slots(&conn).unwrap();
    assert_eq!(slots[1], 200, "slot must migrate to the surviving entry id");
    let remaining: i64 = conn
        .query_row("SELECT COUNT(*) FROM clipboard_history", [], |r| r.get(0))
        .unwrap();
    assert_eq!(remaining, 1);
}

#[test]
fn test_quick_slot_toggle_moves_and_unbinds() {
    let conn = test_db();
    let row = insert_text(&conn, "movable phrase", 1);
    let id = entry_id_of(&conn, row);

    toggle_quick_slot(&conn, id, 1).expect("bind slot 1");
    toggle_quick_slot(&conn, id, 5).expect("move to slot 5");
    let slots = load_quick_slots(&conn).unwrap();
    assert_eq!(slots, [0, 0, 0, 0, id, 0, 0, 0, 0]);

    toggle_quick_slot(&conn, id, 5).expect("unbind slot 5");
    let slots = load_quick_slots(&conn).unwrap();
    assert_eq!(slots, [0u64; QUICK_SLOT_COUNT]);

    assert!(
        toggle_quick_slot(&conn, 999_999, 1).is_err(),
        "unknown entries must be rejected"
    );
    assert!(
        toggle_quick_slot(&conn, id, 10).is_err(),
        "slot numbers above the cap must be rejected"
    );
}

#[test]
fn test_quick_slot_released_on_delete_and_pruned_on_clear() {
    let conn = test_db();
    let row = insert_text(&conn, "deletable phrase", 1);
    let id = entry_id_of(&conn, row);
    toggle_quick_slot(&conn, id, 3).expect("bind slot 3");

    crate::db::soft_delete_row(&conn, row).expect("soft delete");
    let slots = load_quick_slots(&conn).unwrap();
    assert_eq!(slots[2], 0, "soft delete must release the slot immediately");

    let deleted = crate::db::newest_deleted_row(&conn).unwrap().expect("undo row");
    assert_eq!(deleted.3, 3, "undo record must remember the slot");

    let tx = conn.unchecked_transaction().unwrap();
    tx.execute("DELETE FROM clipboard_quick_slots", []).unwrap();
    tx.commit().unwrap();
    assert_eq!(load_quick_slots(&conn).unwrap(), [0u64; QUICK_SLOT_COUNT]);
}
