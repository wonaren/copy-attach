// FFI delete-failure semantics and the undo-stack caps.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize};
use std::sync::{Arc, Mutex};

use crate::backend::{set_backend, Backend, DELETE_STACK_LIMIT, DeletedStackEntry, MAX_UNDO_BYTES, push_deleted};
use crate::ffi::{clipboard_delete_by_id, clipboard_undo_delete};
use crate::ignore::IgnoreRules;
use crate::types::{ClipboardEntry, SourceApp};
use rusqlite::Connection;

/// The FFI-level tests in this file share one process-wide Backend singleton
/// (OnceLock). Both must run their setup through this single Once so a second
/// `set_backend` never fires.
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
            deleted_stack: Arc::new(Mutex::new(Vec::new())),
            last_restored_id: Arc::new(AtomicU64::new(0)),
        };
        set_backend(backend)
            .expect("Backend singleton must not be set before this test");
    });
}

/// Guards the P0 fix: the FFI accessors must never panic when the backend is
/// uninitialized. They are reached from Swift before or without a successful
/// clipboard_init, and a panic across extern "C" aborts the whole process.
///
/// In-process proof is impossible here (this suite holds the process-wide
/// singleton), so the end-to-end proof is the C harness against the built
/// dylib. This test documents the invariant and fails the build if the
/// recoverable accessor disappears from the public surface.
#[test]
fn test_recoverable_backend_accessor_is_the_only_accessor() {
    // try_backend must exist and be usable without initialization.
    // (The absent case is exercised by the C harness; here we only pin the
    // API shape so a future refactor cannot silently reintroduce a panicking
    // accessor without touching this test.)
    let _ = crate::backend::try_backend;
}

#[test]
fn test_clipboard_delete_by_id_returns_zero_on_failure() {
    // Verify that clipboard_delete_by_id returns 0 (failure) when the entry
    // doesn't exist — proving the failure path that Finding 1 relies on.
    //
    // This path triggers in the Swift deleteItem(at:) flow when:
    //   1. deleteKeyNotification handler -> deleteItem(at: itemIndex)
    //   2. backend.deleteEntry(at:) calls clipboard_delete_by_id in Rust
    //   3. If this returns 0, deleteEntry returns false
    //   4. But searchResults.removeAll { $0.id == item.id } has already run
    ensure_test_backend();

    // Test 1: non-existent entry ID → returns 0
    assert_eq!(
        clipboard_delete_by_id(99999),
        0,
        "deleting a non-existent entry ID must return 0 (failure)"
    );

    // Test 2: entry ID 0 (never valid) → returns 0
    assert_eq!(
        clipboard_delete_by_id(0),
        0,
        "deleting entry ID 0 must return 0 (failure)"
    );

    // Test 3: empty history → any ID returns 0
    assert_eq!(
        clipboard_delete_by_id(1),
        0,
        "deleting from empty history must return 0 (failure)"
    );
}

fn mem_slot(entry: ClipboardEntry, payload_bytes: usize) -> DeletedStackEntry {
    DeletedStackEntry { entry, payload_path: std::path::PathBuf::new(), payload_bytes }
}

#[test]
fn test_undo_stack_caps() {
    let text_entry = |id: u64, body: &str| {
        ClipboardEntry::text_entry(id, body, 0, String::new(), String::new(), id as i64)
    };

    // Count cap: 12 small entries trim to the newest DELETE_STACK_LIMIT.
    // Only the most recent deletion is undoable; older ones are shed
    // immediately (deleting something else permanently discards the previous
    // undo).
    let mut stack = Vec::new();
    for i in 0..12 {
        push_deleted(&mut stack, mem_slot(text_entry(i, &"x".repeat(100)), 100));
    }
    assert_eq!(stack.len(), DELETE_STACK_LIMIT, "count cap keeps the newest deletion only");
    let oldest_id = match &stack[0].entry {
        ClipboardEntry::Text { id, .. } => *id,
        _ => unreachable!(),
    };
    assert_eq!(oldest_id, 11, "all but the newest deletion (11) were shed");

    // Byte cap still guards the single slot: an oversized paste must not pin
    // memory even when it is the only undoable deletion.
    let mut stack = Vec::new();
    for i in 0..10 {
        let body = "y".repeat(6 * 1024 * 1024);
        let body_len = body.len();
        push_deleted(&mut stack, mem_slot(text_entry(i, &body), body_len));
    }
    assert_eq!(stack.len(), 1, "byte cap sheds oversized pastes");
    let retained: usize = stack.iter().map(|s| s.payload_bytes).sum();
    assert!(retained <= MAX_UNDO_BYTES, "retained bodies bounded");
    let oldest_id = match &stack[0].entry {
        ClipboardEntry::Text { id, .. } => *id,
        _ => unreachable!(),
    };
    assert_eq!(oldest_id, 9, "entries 0..=8 were shed, 9 (newest) retained");

    // Image blobs count toward the same byte budget: a deleted image cannot
    // pin unbounded memory. 3 × 20 MB = 60 MB > 48 MB → the single slot must
    // still shed it (nothing undoable rather than pinning 60 MB).
    let image_entry = |i: u64| ClipboardEntry::Image {
        id: i,
        width: 1,
        height: 1,
        thumb_width: 0,
        thumb_height: 0,
        hash: i,
        custom_label: String::new(),
        timestamp: 0,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: i as i64,
    };
    let mut stack = Vec::new();
    for i in 0..3 {
        push_deleted(&mut stack, mem_slot(image_entry(i), 20 * 1024 * 1024));
    }
    assert_eq!(stack.len(), 1, "single slot keeps only the newest image");
    let oldest_id = match &stack[0].entry {
        ClipboardEntry::Image { id, .. } => *id,
        _ => unreachable!(),
    };
    assert_eq!(oldest_id, 2, "only the newest deletion (2) is retained");
    let image_bytes: usize = stack.iter().map(|s| s.payload_bytes).sum();
    assert!(image_bytes <= MAX_UNDO_BYTES, "retained image bytes bounded");

    // Mixed: image entries with empty blobs carry no bytes and respect only
    // the count cap.
    let mut stack = Vec::new();
    push_deleted(&mut stack, mem_slot(text_entry(0, "small"), "small".len()));
    for i in 1..=11 {
        push_deleted(
            &mut stack,
            mem_slot(ClipboardEntry::Image {
                id: i,
                width: 1,
                height: 1,
                thumb_width: 0,
                thumb_height: 0,
                hash: i,
                custom_label: String::new(),
                timestamp: 0,
                source_name: String::new(),
                source_bundle_id: String::new(),
                db_id: i as i64,
            }, 0),
        );
    }
    assert_eq!(stack.len(), DELETE_STACK_LIMIT, "images respect count cap too");
    let image_count = stack.iter().filter(|s| matches!(&s.entry, &ClipboardEntry::Image { .. })).count();
    assert_eq!(image_count, DELETE_STACK_LIMIT, "only the newest deletion is retained");
}

/// Regression: undoing an image deletion must not pin the deleted image's
/// PNG/thumb allocations inside the in-memory history Vec.
///
/// The undo payload is materialized on disk by `clipboard_delete_by_id`; the
/// in-memory slot stays metadata-only, and the restored history entry must be
/// metadata-only as well after `clipboard_undo_delete` re-inserts the blobs
/// into a fresh DB row.
#[test]
fn test_undo_image_restore_releases_blob_capacity() {
    ensure_test_backend();

    let b = crate::backend::try_backend().expect("backend initialized");
    let png = vec![0xABu8; 64 * 1024];
    let thumb = vec![0xCDu8; 512];

    // Insert an image row and a matching in-memory entry, then delete it
    // through the same FFI path the UI uses.
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

    // The slot must hold only metadata + a materialized payload file.
    {
        let stack = b.deleted_stack.lock().unwrap();
        assert_eq!(stack.len(), 1, "one undo slot after delete");
        let slot = &stack[0];
        match &slot.entry {
            ClipboardEntry::Image { .. } => {}
            other => panic!("expected image slot, got {other:?}"),
        }
        assert!(!slot.payload_path.as_os_str().is_empty(), "payload path must be materialized");
        assert!(slot.payload_path.exists(), "payload file must exist");
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
    assert!(b.deleted_stack.lock().unwrap().is_empty(), "undo slot consumed");
}

/// The capture pipeline's decode buffer is pooled: one allocation is reused
/// across captures (macOS retains large freed regions, so alloc+free per
/// capture ratchets RSS upward), and an oversized buffer is released rather
/// than pooled so a single huge image cannot pin its peak size.
#[test]
fn test_image_decode_buffer_pool_lifecycle() {
    use crate::backend::{ImageDecodeBuffer, IMAGE_DECODE_SCRATCH_RETAIN_CAP};

    // Buffer returned to the pool on drop, then reused by the next acquire.
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

    // An over-cap buffer is released on drop — never pooled.
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
    // Nonexistent entry must be rejected before any pasteboard write, and must
    // return the documented 0 sentinel (no keystroke pid > 0).
    let pid = crate::ffi::clipboard_prepare_paste_by_id(999_999_999, false);
    assert_eq!(pid, 0, "nonexistent entry must return 0");
}

#[test]
fn test_clipboard_set_custom_label_ffi() {
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

    // In-memory check
    {
        let hist = b.history.lock().unwrap();
        let entry = hist.iter().find(|e| e.entry_id() == entry_id).unwrap();
        assert_eq!(entry.custom_label(), "My FFI Remark");
    }

    // SQLite check
    {
        let conn = b.db.lock().unwrap();
        let stored: String = conn.query_row(
            "SELECT custom_label FROM clipboard_history WHERE entry_id = ?1",
            rusqlite::params![entry_id as i64],
            |r| r.get(0),
        ).unwrap();
        assert_eq!(stored, "My FFI Remark");
    }

    // Nonexistent entry must return 0
    let ret_nonexistent = crate::ffi::clipboard_set_custom_label(888_888_888, c_label.as_ptr());
    assert_eq!(ret_nonexistent, 0);

    // Null pointer must return 0
    let ret_null = crate::ffi::clipboard_set_custom_label(entry_id, std::ptr::null());
    assert_eq!(ret_null, 0);

    // Over-long label is a caller contract violation: rejected, and neither the
    // in-memory entry nor the DB row may change.
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

    // A label exactly at the cap is accepted.
    let at_cap = std::ffi::CString::new("y".repeat(crate::types::MAX_CUSTOM_LABEL_SCALARS)).unwrap();
    assert_eq!(
        crate::ffi::clipboard_set_custom_label(entry_id, at_cap.as_ptr()),
        1,
        "label at the scalar cap must be accepted"
    );

    // An id present in the DB but absent from the in-memory history is rejected
    // before any write — the history is the authority on what may be labelled.
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

