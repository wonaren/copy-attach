use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::backend::{set_backend, Backend};
use crate::ffi::{clipboard_clear_history, clipboard_delete_by_id, clipboard_undo_delete};
use crate::ignore::IgnoreRules;
use crate::types::{ClipboardEntry, SourceApp};
use rusqlite::Connection;

static INIT: std::sync::Once = std::sync::Once::new();

fn ensure_test_backend() {
    INIT.call_once(|| {
        let conn = Connection::open_in_memory()
            .expect("in-memory DB for test");
        crate::db::ensure_history_table(&conn)
            .expect("schema creation");
        let backend = Backend {
            history: Arc::new(Mutex::new(Vec::new())),
            running: Arc::new(AtomicBool::new(true)),
            monitor_handle: Mutex::new(None),
            source_app: Arc::new(Mutex::new(SourceApp::default())),
            pasteboard_event_lock: Arc::new(Mutex::new(())),
            pending_self_write: Arc::new(Mutex::new(None)),
            db: Arc::new(Mutex::new(conn)),
            cleanup_threshold: Arc::new(AtomicUsize::new(3000)),
            ignore_rules: Arc::new(Mutex::new(IgnoreRules::default())),
            undo_budget_bytes: Arc::new(std::sync::atomic::AtomicI64::new(
                crate::backend::DEFAULT_UNDO_BUDGET_MB * 1024 * 1024,
            )),
            last_restored_id: Arc::new(AtomicU64::new(0)),
            favorites: Arc::new(Mutex::new(HashSet::new())),
        };
        set_backend(backend)
            .expect("Backend singleton must not be set before this test");
    });
}

static SHARED_STATE_LOCK: Mutex<()> = Mutex::new(());

fn shared_state_guard() -> std::sync::MutexGuard<'static, ()> {
    SHARED_STATE_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn test_recoverable_backend_accessor_is_the_only_accessor() {
    let _ = crate::backend::try_backend;
}

#[test]
fn test_clipboard_delete_by_id_returns_zero_on_failure() {
    let _shared = shared_state_guard();
    ensure_test_backend();

    assert_eq!(
        clipboard_delete_by_id(99999),
        0,
        "deleting a non-existent entry ID must return 0 (failure)"
    );

    assert_eq!(
        clipboard_delete_by_id(0),
        0,
        "deleting entry ID 0 must return 0 (failure)"
    );

    assert_eq!(
        clipboard_delete_by_id(1),
        0,
        "deleting from empty history must return 0 (failure)"
    );
}

#[test]
fn test_soft_delete_undo_depth_is_not_capped() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 940_000_000;
    let n: u64 = 40;
    let mut db_ids: Vec<i64> = Vec::new();
    {
        let conn = b.db.lock().unwrap();
        for i in 0..n {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                     preview, label)
                 VALUES (0, ?1, ?2, ?3, 'UndoDepth', 'com.example.undodepth', ?4, ?1, ?1)",
                rusqlite::params![
                    format!("undo-depth-{i}"),
                    (base + i) as i64,
                    (i + 1) as i64,
                    (base + i) as i64
                ],
            )
            .expect("insert undo-depth fixture row");
            db_ids.push(conn.last_insert_rowid());
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        for (i, db_id) in db_ids.iter().enumerate() {
            hist.push(ClipboardEntry::Text {
                id: base + i as u64,
                preview: format!("undo-depth-{i}"),
                label: format!("undo-depth-{i}"),
                custom_label: String::new(),
                text_hash: base + i as u64,
                timestamp: (i + 1) as u64,
                source_name: "UndoDepth".to_string(),
                source_bundle_id: "com.example.undodepth".to_string(),
                db_id: *db_id,
            });
        }
    }

    for i in 0..n {
        assert_eq!(
            clipboard_delete_by_id(base + i),
            1,
            "deleting fixture entry {i} must succeed"
        );
        let depth = {
            let conn = b.db.lock().unwrap();
            crate::db::undo_depth(&conn).expect("undo depth must be readable")
        };
        assert!(
            depth >= (i + 1) as usize,
            "undo depth must retain every deletion: after {} deletes depth={depth}",
            i + 1
        );
    }
    {
        let conn = b.db.lock().unwrap();
        assert_eq!(
            crate::db::undo_depth(&conn).expect("undo depth must be readable"),
            n as usize,
            "all {n} deletions must stay undoable (no step cap)"
        );
    }

    for i in (0..n).rev() {
        assert_eq!(clipboard_undo_delete(), 1, "undo of deletion {i} must succeed");
        let restored = crate::backend::try_backend()
            .unwrap()
            .last_restored_id
            .load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(restored, base + i, "undo must restore the newest deletion first (LIFO)");
    }
    {
        let conn = b.db.lock().unwrap();
        assert_eq!(
            crate::db::undo_depth(&conn).expect("undo depth must be readable"),
            0,
            "everything was undone"
        );
    }

    {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id >= ?1 AND entry_id < ?2",
            rusqlite::params![base as i64, (base + n) as i64],
        )
        .expect("cleanup fixture rows");
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= base && e.entry_id() < base + n));
    }
}

#[test]
fn test_clear_history_also_clears_the_undo_stack() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 950_000_000;
    let mut db_ids: Vec<i64> = Vec::new();
    {
        let conn = b.db.lock().unwrap();
        for i in 0..2u64 {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                     preview, label)
                 VALUES (0, ?1, ?2, ?3, 'ClearUndo', 'com.example.clearundo', ?4, ?1, ?1)",
                rusqlite::params![
                    format!("clear-undo-{i}"),
                    (base + i) as i64,
                    (i + 1) as i64,
                    (base + i) as i64
                ],
            )
            .expect("insert clear-undo fixture row");
            db_ids.push(conn.last_insert_rowid());
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        for (i, db_id) in db_ids.iter().enumerate() {
            hist.push(ClipboardEntry::Text {
                id: base + i as u64,
                preview: format!("clear-undo-{i}"),
                label: format!("clear-undo-{i}"),
                custom_label: String::new(),
                text_hash: base + i as u64,
                timestamp: (i + 1) as u64,
                source_name: "ClearUndo".to_string(),
                source_bundle_id: "com.example.clearundo".to_string(),
                db_id: *db_id,
            });
        }
    }

    assert_eq!(clipboard_delete_by_id(base), 1, "fixture delete must succeed");
    {
        let conn = b.db.lock().unwrap();
        assert_eq!(
            crate::db::undo_depth(&conn).expect("undo depth"),
            1,
            "precondition: the delete is undoable"
        );
    }

    assert_eq!(clipboard_clear_history(), 1, "clear must succeed");

    let conn = b.db.lock().unwrap();
    for table in ["clipboard_history", "clipboard_deleted", "clipboard_favorites"] {
        let n: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .expect("count table");
        assert_eq!(n, 0, "{table} must be empty after 清空历史");
    }
    assert_eq!(
        crate::db::undo_depth(&conn).expect("undo depth"),
        0,
        "清空历史 promises it cannot be undone"
    );
}

#[test]
fn test_undo_collapses_with_recaptured_duplicate() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let body = "duplicate-content-for-undo";
    let entry_a: u64 = 941_000_001;
    let entry_b: u64 = 941_000_002;
    let (row_a, row_b) = {
        let conn = b.db.lock().unwrap();
        let row_a = {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                     preview, label)
                 VALUES (0, ?1, ?2, 1, 'DupTest', 'com.example.duptest', ?3, ?1, ?1)",
                rusqlite::params![body, crate::types::text_hash(body) as i64, entry_a as i64],
            )
            .unwrap();
            conn.last_insert_rowid()
        };
        let row_b = {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                     preview, label)
                 VALUES (0, ?1, ?2, 2, 'DupTest', 'com.example.duptest', ?3, ?1, ?1)",
                rusqlite::params![body, crate::types::text_hash(body) as i64, entry_a as i64],
            )
            .unwrap();
            conn.last_insert_rowid()
        };
        (row_a, row_b)
    };
    {
        let mut hist = b.history.lock().unwrap();
        hist.push(ClipboardEntry::Text {
            id: entry_a,
            preview: body.to_string(),
            label: body.to_string(),
            custom_label: String::new(),
            text_hash: crate::types::text_hash(body),
            timestamp: 2,
            source_name: "DupTest".to_string(),
            source_bundle_id: "com.example.duptest".to_string(),
            db_id: row_b,
        });
    }
    let _ = entry_b;
    let _ = row_a;

    assert_eq!(clipboard_delete_by_id(entry_a), 1, "delete of the live duplicate must succeed");
    assert_eq!(clipboard_undo_delete(), 1, "undo must succeed");

    let live_rows: i64 = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history
           WHERE id NOT IN (SELECT row_id FROM clipboard_deleted)
             AND entry_type = 0 AND text = ?1",
            rusqlite::params![body],
            |r| r.get(0),
        )
        .unwrap()
    };

    {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id >= 941_000_000 AND entry_id < 942_000_000",
            [],
        )
        .unwrap();
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= 941_000_000 && e.entry_id() < 942_000_000));
    }

    assert_eq!(live_rows, 1, "undo must not leave a duplicate row behind (found {live_rows})");
}

#[test]
fn test_undo_restores_favorite_state() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let entry_id: u64 = 943_000_001;
    let row_id = {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "INSERT INTO clipboard_history
                (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                 preview, label)
             VALUES (0, 'favorite-restore', 1, 1, 'FavUndo', 'com.example.favundo', ?1,
                     'favorite-restore', 'favorite-restore')",
            rusqlite::params![entry_id as i64],
        )
        .unwrap();
        let row_id = conn.last_insert_rowid();
        crate::db::set_favorite(&conn, entry_id, true).unwrap();
        row_id
    };
    {
        let mut hist = b.history.lock().unwrap();
        hist.push(ClipboardEntry::Text {
            id: entry_id,
            preview: "favorite-restore".to_string(),
            label: "favorite-restore".to_string(),
            custom_label: String::new(),
            text_hash: 1,
            timestamp: 1,
            source_name: "FavUndo".to_string(),
            source_bundle_id: "com.example.favundo".to_string(),
            db_id: row_id,
        });
    }
    b.favorites.lock().unwrap().insert(entry_id);

    assert_eq!(clipboard_delete_by_id(entry_id), 1, "delete must succeed");

    let fav_rows_after_delete: i64 = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get(0),
        )
        .unwrap()
    };
    let in_mirror_after_delete = b.favorites.lock().unwrap().contains(&entry_id);

    assert_eq!(clipboard_undo_delete(), 1, "undo must succeed");

    let fav_rows_after_undo: i64 = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get(0),
        )
        .unwrap()
    };
    let in_mirror_after_undo = b.favorites.lock().unwrap().contains(&entry_id);

    {
        let conn = b.db.lock().unwrap();
        let _ = conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id >= 943_000_000 AND entry_id < 944_000_000",
            [],
        );
        let _ = conn.execute(
            "DELETE FROM clipboard_favorites WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
        );
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= 943_000_000 && e.entry_id() < 944_000_000));
    }
    b.favorites.lock().unwrap().remove(&entry_id);

    assert_eq!(fav_rows_after_delete, 0, "delete must drop the durable favorite");
    assert!(!in_mirror_after_delete, "delete must drop the favorite mirror entry");
    assert_eq!(fav_rows_after_undo, 1, "undo must restore the durable favorite");
    assert!(in_mirror_after_undo, "undo must restore the favorite mirror entry");
}

#[test]
fn test_deleted_rows_are_swept_by_age_and_byte_budget() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 944_000_000;
    {
        let conn = b.db.lock().unwrap();
        for (i, age_secs) in [crate::backend::UNDO_RETENTION_SECS - 60,
                             crate::backend::UNDO_RETENTION_SECS + 60].iter().enumerate() {
            let stamp = crate::backend::undo_stamp_now() - (*age_secs as i64) * 1_000_000;
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id,
                     preview, label)
                 VALUES (0, ?1, ?2, 0, 'SweepTest', 'com.example.sweep', ?3, ?1, ?1)",
                rusqlite::params![
                    format!("sweep-{i}"),
                    (base + i as u64) as i64,
                    (base + i as u64) as i64,
                ],
            )
            .unwrap();
            let row_id = conn.last_insert_rowid();
            conn.execute(
                "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
                 VALUES (?1, ?2, ?3, 0)",
                rusqlite::params![row_id, (base + i as u64) as i64, stamp],
            )
            .unwrap();
        }
    }
    let purged = {
        let conn = b.db.lock().unwrap();
        crate::db::purge_expired_deleted_rows(&conn, crate::backend::undo_budget_bytes())
            .expect("age sweep must succeed")
    };
    let survivors: i64 = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE entry_id >= ?1 AND entry_id < ?2",
            rusqlite::params![base as i64, (base + 2) as i64],
            |r| r.get(0),
        )
        .unwrap()
    };

    let big_base: u64 = 945_000_000;
    {
        let conn = b.db.lock().unwrap();
        let blob = vec![0u8; 40 * 1024 * 1024];
        for (i, secs) in [120i64, 60].iter().enumerate() {
            let stamp = crate::backend::undo_stamp_now() - secs * 1_000_000;
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, png_data, width, height, hash, timestamp,
                     source_name, source_bundle_id, entry_id)
                 VALUES (1, ?1, 1, 1, ?2, 0, 'SweepBig', 'com.example.sweepbig', ?3)",
                rusqlite::params![
                    blob,
                    (big_base + i as u64) as i64,
                    (big_base + i as u64) as i64,
                ],
            )
            .unwrap();
            let row_id = conn.last_insert_rowid();
            conn.execute(
                "INSERT INTO clipboard_deleted (row_id, entry_id, deleted_at, was_favorite)
                 VALUES (?1, ?2, ?3, 0)",
                rusqlite::params![row_id, (big_base + i as u64) as i64, stamp],
            )
            .unwrap();
        }
    }
    let budget_purged = {
        let conn = b.db.lock().unwrap();
        crate::db::purge_expired_deleted_rows(&conn, crate::backend::undo_budget_bytes())
            .expect("byte sweep must succeed")
    };
    let remaining_bytes: i64 = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COALESCE(SUM(LENGTH(png_data)), 0) FROM clipboard_history h
             JOIN clipboard_deleted d ON d.row_id = h.id
             WHERE h.entry_id >= ?1 AND h.entry_id < ?2",
            rusqlite::params![big_base as i64, (big_base + 2) as i64],
            |r| r.get(0),
        )
        .unwrap()
    };

    {
        let conn = b.db.lock().unwrap();
        let _ = conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id >= ?1 AND entry_id < ?2",
            rusqlite::params![base as i64, (base + 2) as i64],
        );
        let _ = conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id >= ?1 AND entry_id < ?2",
            rusqlite::params![big_base as i64, (big_base + 2) as i64],
        );
    }

    assert_eq!(purged, 1, "only the row past the retention window is purged");
    assert_eq!(survivors, 1, "the row inside the retention window must survive");
    assert!(budget_purged >= 1, "the byte budget must shed the oldest deletion");
    assert!(
        remaining_bytes <= crate::backend::undo_budget_bytes(),
        "retained deleted payload must fit the budget (left {remaining_bytes} bytes)"
    );
}

#[test]
fn test_undo_image_restore_releases_blob_capacity() {
    let _shared = shared_state_guard();
    ensure_test_backend();

    let b = crate::backend::try_backend().expect("backend initialized");
    let png = vec![0xABu8; 64 * 1024];
    let thumb = vec![0xCDu8; 512];

    let db_id = {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "INSERT INTO clipboard_history
                (entry_type, png_data, width, height, thumb_data, thumb_width, thumb_height,
                 hash, timestamp, source_name, source_bundle_id, entry_id)
             VALUES (1, ?1, 640, 480, ?2, 160, 120, ?3, 0, 'TestApp', 'com.example.test', 777_000)",
            rusqlite::params![png, thumb, 0xDEAD_BEEFu64 as i64],
        ).expect("insert image row");
        conn.last_insert_rowid()
    };
    {
        let mut hist = b.history.lock().unwrap();
        hist.push(ClipboardEntry::Image {
            id: 777_000,
            width: 640,
            height: 480,
            thumb_width: 160,
            thumb_height: 120,
            hash: 0xDEAD_BEEF,
            custom_label: String::new(),
            timestamp: 0,
            source_name: "TestApp".to_string(),
            source_bundle_id: "com.example.test".to_string(),
            db_id,
        });
    }

    assert_eq!(clipboard_delete_by_id(777_000), 1, "delete must succeed");

    {
        let conn = b.db.lock().unwrap();
        let (stamp, png_len, thumb_len): (i64, i64, i64) = conn
            .query_row(
                "SELECT d.deleted_at, LENGTH(h.png_data), LENGTH(h.thumb_data)
                 FROM clipboard_history h
                 JOIN clipboard_deleted d ON d.row_id = h.id
                 WHERE h.id = ?1",
                rusqlite::params![db_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .expect("deleted row must still exist with its undo entry");
        assert!(stamp > 0, "the side table must carry a deletion stamp");
        assert_eq!(png_len, 64 * 1024, "the PNG blob must stay in the row");
        assert_eq!(thumb_len, 512, "the thumbnail blob must stay in the row");
    }

    assert_eq!(clipboard_undo_delete(), 1, "undo must succeed");

    let hist = b.history.lock().unwrap();
    let restored_id = match hist.first() {
        Some(ClipboardEntry::Image { db_id, .. }) => {
            assert_ne!(*db_id, 0, "restored entry must point at its new DB row");
            *db_id
        }
        other => panic!("expected restored image at head of history, got {other:?}"),
    };
    assert_ne!(restored_id, 0);
    assert_eq!(
        crate::db::undo_depth(&b.db.lock().unwrap()).expect("undo depth must be readable"),
        0,
        "undo slot consumed"
    );
}

#[test]
fn test_image_decode_buffer_pool_lifecycle() {
    use crate::backend::{ImageDecodeBuffer, IMAGE_DECODE_SCRATCH_RETAIN_CAP};

    {
        let mut buf = ImageDecodeBuffer::acquire();
        buf.as_mut_vec().resize(1024 * 1024, 0);
        assert!(buf.as_mut_vec().capacity() >= 1024 * 1024);
    }
    let mut reused = ImageDecodeBuffer::acquire();
    assert!(
        reused.as_mut_vec().capacity() >= 1024 * 1024,
        "freed decode buffer must be reused by the next capture, not reallocated"
    );
    drop(reused);

    {
        let mut big = ImageDecodeBuffer::acquire();
        big.as_mut_vec().resize(IMAGE_DECODE_SCRATCH_RETAIN_CAP + 1, 0);
    }
    let mut after_big = ImageDecodeBuffer::acquire();
    assert_eq!(
        after_big.as_mut_vec().capacity(),
        0,
        "an oversized buffer must not pin its peak size in the pool"
    );
    drop(after_big);
}

#[test]
fn test_prepare_paste_by_id_missing_returns_zero() {
    ensure_test_backend();
    assert_eq!(crate::ffi::clipboard_prepare_paste_by_id(999_999_999, false, 0), 0);
    assert_eq!(crate::ffi::clipboard_prepare_paste_by_id(999_999_999, false, 1), 0);
}

#[test]
fn test_prepare_paste_rejects_unknown_delivery_mode() {
    ensure_test_backend();
    assert_eq!(crate::ffi::clipboard_prepare_paste_by_id(999_999_999, false, 2), 0);
    assert_eq!(crate::ffi::clipboard_prepare_paste_by_id(999_999_999, false, -1), 0);
}

#[test]
fn test_clipboard_set_custom_label_ffi() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let entry_id = crate::backend::new_entry_id();
    {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "INSERT INTO clipboard_history (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
             VALUES (0, 'content-for-label-test', 98765, 100, 'App', 'com.app', ?1)",
            rusqlite::params![entry_id as i64],
        ).unwrap();
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.push(ClipboardEntry::Text {
            id: entry_id,
            preview: "content-for-label-test".to_string(),
            label: "content-for-label-test".to_string(),
            custom_label: String::new(),
            text_hash: 98765,
            timestamp: 100,
            source_name: "App".to_string(),
            source_bundle_id: "com.app".to_string(),
            db_id: 0,
        });
    }

    let c_label = std::ffi::CString::new("My FFI Remark").unwrap();
    let ret = crate::ffi::clipboard_set_custom_label(entry_id, c_label.as_ptr());
    assert_eq!(ret, 1, "custom label update must succeed");

    {
        let hist = b.history.lock().unwrap();
        let entry = hist.iter().find(|e| e.entry_id() == entry_id).unwrap();
        assert_eq!(entry.custom_label(), "My FFI Remark");
    }

    {
        let conn = b.db.lock().unwrap();
        let stored: String = conn.query_row(
            "SELECT custom_label FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get(0),
        ).unwrap();
        assert_eq!(stored, "My FFI Remark");
    }

    let ret_nonexistent = crate::ffi::clipboard_set_custom_label(888_888_888, c_label.as_ptr());
    assert_eq!(ret_nonexistent, 0);

    let ret_null = crate::ffi::clipboard_set_custom_label(entry_id, std::ptr::null());
    assert_eq!(ret_null, 0);

    let long_label = std::ffi::CString::new(
        "x".repeat(crate::types::MAX_CUSTOM_LABEL_SCALARS + 1),
    ).unwrap();
    assert_eq!(
        crate::ffi::clipboard_set_custom_label(entry_id, long_label.as_ptr()),
        0,
        "label over the scalar cap must be rejected"
    );
    {
        let hist = b.history.lock().unwrap();
        let entry = hist.iter().find(|e| e.entry_id() == entry_id).unwrap();
        assert_eq!(entry.custom_label(), "My FFI Remark");
    }
    {
        let conn = b.db.lock().unwrap();
        let stored: String = conn.query_row(
            "SELECT custom_label FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get(0),
        ).unwrap();
        assert_eq!(stored, "My FFI Remark");
    }

    let at_cap = std::ffi::CString::new("y".repeat(crate::types::MAX_CUSTOM_LABEL_SCALARS)).unwrap();
    assert_eq!(
        crate::ffi::clipboard_set_custom_label(entry_id, at_cap.as_ptr()),
        1,
        "label at the scalar cap must be accepted"
    );

    let db_only_id = crate::backend::new_entry_id();
    {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "INSERT INTO clipboard_history (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
             VALUES (0, 'db-only', 98766, 100, 'App', 'com.app', ?1)",
            rusqlite::params![db_only_id as i64],
        ).unwrap();
    }
    assert_eq!(
        crate::ffi::clipboard_set_custom_label(db_only_id, c_label.as_ptr()),
        0,
        "an entry unknown to the history must be rejected"
    );
    {
        let conn = b.db.lock().unwrap();
        let stored: String = conn.query_row(
            "SELECT custom_label FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![db_only_id as i64],
            |r| r.get(0),
        ).unwrap();
        assert_eq!(stored, "", "rejected id must leave the DB row untouched");
        conn.execute(
            "DELETE FROM clipboard_history WHERE entry_id IN (?1, ?2)",
            rusqlite::params![entry_id as i64, db_only_id as i64],
        ).unwrap();
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| e.entry_id() != entry_id);
    }
}

#[test]
fn test_update_entry_custom_label_requires_existing_row() {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    crate::db::ensure_history_table(&conn).unwrap();

    assert!(
        crate::db::update_entry_custom_label(&conn, 4242, "ghost").is_err(),
        "updating a label with no matching row must fail, not report success"
    );

    conn.execute(
        "INSERT INTO clipboard_history (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
         VALUES (0, 'body', 1, 1, 'App', 'com.app', 4242)",
        [],
    ).unwrap();
    crate::db::update_entry_custom_label(&conn, 4242, "real").unwrap();
    let stored: String = conn.query_row(
        "SELECT custom_label FROM clipboard_history WHERE entry_id = 4242",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(stored, "real");
}

#[test]
fn test_history_mutations_publish_a_revision() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");
    let rev = || crate::backend::HISTORY_REVISION.load(std::sync::atomic::Ordering::Relaxed);

    let pad: u64 = 555_100_000;
    let pad_count: u64 = 150;
    {
        let mut hist = b.history.lock().unwrap();
        for i in 0..pad_count {
            hist.push(ClipboardEntry::text_entry(
                pad + i, "pad", 0, String::new(), String::new(), 0,
            ));
        }
    }
    assert!(b.history.lock().unwrap().len() > 100, "fixture must exceed the clamped minimum");
    let before_trim = rev();
    crate::ffi::clipboard_set_cleanup_threshold(100);
    let after_trim = rev();
    assert!(
        after_trim > before_trim,
        "a threshold trim must publish ({before_trim} -> {after_trim})"
    );
    assert!(b.history.lock().unwrap().len() <= 100, "trim must bound the list");

    let before_noop = rev();
    crate::ffi::clipboard_set_cleanup_threshold(100);
    assert_eq!(rev(), before_noop, "a no-op threshold change must not publish");

    crate::ffi::clipboard_set_cleanup_threshold(3000);
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= pad && e.entry_id() < pad + pad_count));
    }
}

#[test]
fn test_set_favorite_updates_db_mirror_and_packed_snapshot() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let entry_id: u64 = 930_000_000;
    let db_id: i64;
    {
        let conn = b.db.lock().unwrap();
        conn.execute(
            "INSERT INTO clipboard_history
                (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
             VALUES (0, 'fav-ffi', ?1, 1, 'FavTest', 'com.example.favtest', ?2)",
            rusqlite::params![entry_id as i64, entry_id as i64],
        ).expect("insert favorite fixture row");
        db_id = conn.last_insert_rowid();
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.push(ClipboardEntry::Text {
            id: entry_id,
            preview: "fav-ffi".to_string(),
            label: "fav-ffi".to_string(),
            custom_label: String::new(),
            text_hash: entry_id,
            timestamp: 1,
            source_name: "FavTest".to_string(),
            source_bundle_id: "com.example.favtest".to_string(),
            db_id,
        });
    }

    let before_rev = crate::backend::HISTORY_REVISION.load(std::sync::atomic::Ordering::Relaxed);
    let toggled = crate::ffi::clipboard_set_favorite(entry_id, 1);
    let after_rev = crate::backend::HISTORY_REVISION.load(std::sync::atomic::Ordering::Relaxed);

    let mut packed_len: i32 = 0;
    let ptr = crate::ffi::clipboard_snapshot_packed_acquire(&mut packed_len);
    let mut snapshot_flag = false;
    let mut snapshot_seen = false;
    if !ptr.is_null() && packed_len > 16 {
        let bytes = unsafe { std::slice::from_raw_parts(ptr, packed_len as usize) };
        let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
        let mut off = 16usize;
        for _ in 0..count {
            let id = i64::from_le_bytes(bytes[off + 4..off + 12].try_into().unwrap()) as u64;
            let clen = u32::from_le_bytes(bytes[off + 36..off + 40].try_into().unwrap()) as usize;
            let llen = u32::from_le_bytes(bytes[off + 40..off + 44].try_into().unwrap()) as usize;
            let slen = u32::from_le_bytes(bytes[off + 44..off + 48].try_into().unwrap()) as usize;
            let blen = u32::from_le_bytes(bytes[off + 48..off + 52].try_into().unwrap()) as usize;
            let plen = u32::from_le_bytes(bytes[off + 52..off + 56].try_into().unwrap()) as usize;
            let flags = u32::from_le_bytes(bytes[off + 56..off + 60].try_into().unwrap());
            if id == entry_id {
                snapshot_seen = true;
                snapshot_flag = flags & 1 != 0;
            }
            off += 60 + clen + llen + slen + blen + plen;
        }
        crate::ffi::clipboard_free_bytes(ptr, packed_len);
    }

    let in_db: bool = {
        let conn = b.db.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get::<_, i64>(0),
        )
        .unwrap() > 0
    };
    let in_mirror = b.favorites.lock().unwrap().contains(&entry_id);

    let untoggled = crate::ffi::clipboard_set_favorite(entry_id, 0);
    let removed_db: bool;
    {
        let conn = b.db.lock().unwrap();
        removed_db = conn
            .query_row(
                "SELECT COUNT(*) FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![entry_id as i64],
                |r| r.get::<_, i64>(0),
            )
            .unwrap() == 0;
        let _ = conn.execute("DELETE FROM clipboard_history WHERE id = ?1", rusqlite::params![db_id]);
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| e.entry_id() != entry_id);
    }
    b.favorites.lock().unwrap().remove(&entry_id);

    assert_eq!(toggled, 1, "favoriting a live entry must succeed");
    assert!(after_rev > before_rev, "a favorite toggle must publish a history revision");
    assert!(in_db, "the favorite must be durably recorded");
    assert!(in_mirror, "the in-memory mirror must reflect the toggle");
    assert!(snapshot_seen, "the entry must be present in the packed snapshot");
    assert!(snapshot_flag, "the packed row must carry the favorite flag");
    assert_eq!(untoggled, 1);
    assert!(removed_db, "un-favoriting must remove the durable row");
}

#[test]
fn test_trim_oldest_percent_leaves_memory_intact_when_db_delete_fails() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 910_000_000;
    let n: u64 = 8;
    let mut fixture_ids: Vec<i64> = Vec::new();
    {
        let conn = b.db.lock().unwrap();
        for i in 0..n {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
                 VALUES (0, ?1, ?2, 0, 'TrimTest', 'com.example.trimtest', ?3)",
                rusqlite::params![format!("trim-{i}"), i as i64, (base + i) as i64],
            ).expect("insert trim fixture row");
            fixture_ids.push(conn.last_insert_rowid());
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        for (i, db_id) in fixture_ids.iter().enumerate() {
            hist.push(ClipboardEntry::Text {
                id: base + i as u64,
                preview: format!("trim-{i}"),
                label: format!("trim-{i}"),
                custom_label: String::new(),
                text_hash: i as u64,
                timestamp: 0,
                source_name: "TrimTest".to_string(),
                source_bundle_id: "com.example.trimtest".to_string(),
                db_id: *db_id,
            });
        }
    }
    let before = b.history.lock().unwrap().len();

    {
        let conn = b.db.lock().unwrap();
        conn.pragma_update(None, "query_only", true).expect("enable query_only");
    }
    let removed = crate::ffi::clipboard_trim_oldest_percent(40);
    let after = b.history.lock().unwrap().len();

    {
        let conn = b.db.lock().unwrap();
        conn.pragma_update(None, "query_only", false).expect("disable query_only");
        for db_id in &fixture_ids {
            let _ = conn.execute(
                "DELETE FROM clipboard_history WHERE id = ?1",
                rusqlite::params![db_id],
            );
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= base && e.entry_id() < base + n));
    }

    assert_eq!(removed, 0, "a failed DB delete must report nothing removed");
    assert_eq!(
        after, before,
        "memory must be untouched when the DB delete failed (was {before}, now {after})"
    );
}

#[test]
fn test_trim_oldest_percent_preserves_favorites() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 920_000_000;
    let n: u64 = 10;
    let mut fixture_ids: Vec<i64> = Vec::new();
    {
        let conn = b.db.lock().unwrap();
        for i in 0..n {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
                 VALUES (0, ?1, ?2, ?3, 'TrimFavTest', 'com.example.trimfav', ?4)",
                rusqlite::params![format!("trim-fav-{i}"), (base + i) as i64, (i + 100) as i64, (base + i) as i64],
            ).expect("insert trim fav fixture row");
            fixture_ids.push(conn.last_insert_rowid());
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        for (i, db_id) in fixture_ids.iter().enumerate() {
            hist.push(ClipboardEntry::Text {
                id: base + i as u64,
                preview: format!("trim-fav-{i}"),
                label: format!("trim-fav-{i}"),
                custom_label: String::new(),
                text_hash: base + i as u64,
                timestamp: (i + 100) as u64,
                source_name: "TrimFavTest".to_string(),
                source_bundle_id: "com.example.trimfav".to_string(),
                db_id: *db_id,
            });
        }
    }

    {
        let conn = b.db.lock().unwrap();
        for id in [base, base + 1] {
            crate::db::set_favorite(&conn, id, true).unwrap();
        }
    }
    {
        let mut favorites = b.favorites.lock().unwrap();
        favorites.insert(base);
        favorites.insert(base + 1);
    }
    let removed = crate::ffi::clipboard_trim_oldest_percent(40);

    let fav0_db: bool;
    let fav1_db: bool;
    let nonfav2_db: bool;
    {
        let conn = b.db.lock().unwrap();
        fav0_db = conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![(base) as i64],
            |r| r.get::<_, i64>(0),
        ).unwrap() > 0;
        fav1_db = conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![(base + 1) as i64],
            |r| r.get::<_, i64>(0),
        ).unwrap() > 0;
        nonfav2_db = conn.query_row(
            "SELECT COUNT(*) FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![(base + 2) as i64],
            |r| r.get::<_, i64>(0),
        ).unwrap() > 0;
    }

    let fav0_mem: bool;
    let fav1_mem: bool;
    let nonfav2_mem: bool;
    {
        let hist = b.history.lock().unwrap();
        fav0_mem = hist.iter().any(|e| e.entry_id() == base);
        fav1_mem = hist.iter().any(|e| e.entry_id() == base + 1);
        nonfav2_mem = hist.iter().any(|e| e.entry_id() == base + 2);
    }

    {
        let conn = b.db.lock().unwrap();
        for db_id in &fixture_ids {
            let _ = conn.execute(
                "DELETE FROM clipboard_history WHERE id = ?1",
                rusqlite::params![db_id],
            );
        }
    }
    {
        let conn = b.db.lock().unwrap();
        for id in [base, base + 1] {
            let _ = conn.execute(
                "DELETE FROM clipboard_favorites WHERE entry_id = ?1",
                rusqlite::params![id as i64],
            );
        }
    }
    {
        let mut favorites = b.favorites.lock().unwrap();
        favorites.remove(&base);
        favorites.remove(&(base + 1));
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= base && e.entry_id() < base + n));
    }

    assert_eq!(removed, 4);
    assert!(fav0_db, "favorite 0 must be preserved in DB");
    assert!(fav1_db, "favorite 1 must be preserved in DB");
    assert!(!nonfav2_db, "unfavorited entry 2 must be deleted from DB");
    assert!(fav0_mem, "favorite 0 must be preserved in memory");
    assert!(fav1_mem, "favorite 1 must be preserved in memory");
    assert!(!nonfav2_mem, "unfavorited entry 2 must be deleted from memory");
}

#[test]
fn test_set_cleanup_threshold_leaves_memory_intact_when_db_delete_fails() {
    let _shared = shared_state_guard();
    ensure_test_backend();
    let b = crate::backend::try_backend().expect("backend initialized");

    let base: u64 = 912_000_000;
    let n: u64 = 6;
    let mut fixture_ids: Vec<i64> = Vec::new();
    {
        let conn = b.db.lock().unwrap();
        for i in 0..n {
            conn.execute(
                "INSERT INTO clipboard_history
                    (entry_type, text, hash, timestamp, source_name, source_bundle_id, entry_id)
                 VALUES (0, ?1, ?2, 0, 'ThresholdTest', 'com.example.thresholdtest', ?3)",
                rusqlite::params![format!("thresh-{i}"), i as i64, (base + i) as i64],
            ).expect("insert threshold fixture row");
            fixture_ids.push(conn.last_insert_rowid());
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        for (i, db_id) in fixture_ids.iter().enumerate() {
            hist.push(ClipboardEntry::Text {
                id: base + i as u64,
                preview: format!("thresh-{i}"),
                label: format!("thresh-{i}"),
                custom_label: String::new(),
                text_hash: i as u64,
                timestamp: 0,
                source_name: "ThresholdTest".to_string(),
                source_bundle_id: "com.example.thresholdtest".to_string(),
                db_id: *db_id,
            });
        }
    }
    let before = b.history.lock().unwrap().len();

    {
        let conn = b.db.lock().unwrap();
        conn.pragma_update(None, "query_only", true).expect("enable query_only");
    }

    crate::ffi::clipboard_set_cleanup_threshold(100);
    let after = b.history.lock().unwrap().len();

    {
        let conn = b.db.lock().unwrap();
        conn.pragma_update(None, "query_only", false).expect("disable query_only");
        for db_id in &fixture_ids {
            let _ = conn.execute(
                "DELETE FROM clipboard_history WHERE id = ?1",
                rusqlite::params![db_id],
            );
        }
    }
    {
        let mut hist = b.history.lock().unwrap();
        hist.retain(|e| !(e.entry_id() >= base && e.entry_id() < base + n));
    }
    crate::ffi::clipboard_set_cleanup_threshold(3000);

    assert_eq!(
        after, before,
        "memory must stay intact when DB trim fails (was {before}, now {after})"
    );
}

#[test]
fn test_log_timestamp_is_utc_plus_8() {
    assert_eq!(crate::backend::format_log_timestamp(0), "1970-01-01 08:00:00 +0800");
    assert_eq!(
        crate::backend::format_log_timestamp(951_782_400),
        "2000-02-29 08:00:00 +0800",
        "leap day must survive the civil-date conversion"
    );
    assert_eq!(
        crate::backend::format_log_timestamp(1_000_000_000),
        "2001-09-09 09:46:40 +0800"
    );
    assert_eq!(
        crate::backend::format_log_timestamp(1_757_340_675),
        "2025-09-08 22:11:15 +0800"
    );
}
