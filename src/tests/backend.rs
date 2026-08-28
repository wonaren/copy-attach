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
    let image_entry = |i: u64, png: Vec<u8>| ClipboardEntry::Image {
        id: i,
        png_data: png,
        width: 1,
        height: 1,
        thumb_data: Vec::new(),
        thumb_width: 0,
        thumb_height: 0,
        hash: i,
        timestamp: 0,
        source_name: String::new(),
        source_bundle_id: String::new(),
        db_id: i as i64,
    };
    let mut stack = Vec::new();
    for i in 0..3 {
        push_deleted(&mut stack, mem_slot(image_entry(i, vec![0u8; 20 * 1024 * 1024]), 20 * 1024 * 1024));
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
                png_data: Vec::new(),
                width: 1,
                height: 1,
                thumb_data: Vec::new(),
                thumb_width: 0,
                thumb_height: 0,
                hash: i,
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
            png_data: Vec::new(),
            width: 640,
            height: 480,
            thumb_data: Vec::new(),
            thumb_width: 160,
            thumb_height: 120,
            hash: 0xDEAD_BEEF,
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
            ClipboardEntry::Image { png_data, thumb_data, .. } => {
                assert!(png_data.is_empty() && thumb_data.is_empty(),
                    "undo slot entry must be metadata-only after payload materialization");
            }
            other => panic!("expected image slot, got {other:?}"),
        }
        assert!(!slot.payload_path.as_os_str().is_empty(), "payload path must be materialized");
        assert!(slot.payload_path.exists(), "payload file must exist");
    }

    assert_eq!(clipboard_undo_delete(), 1, "undo must succeed");

    let hist = b.history.lock().unwrap();
    let restored = match hist.first() {
        Some(ClipboardEntry::Image { png_data, thumb_data, db_id, .. }) => {
            assert_ne!(*db_id, 0, "restored entry must point at its new DB row");
            (png_data.capacity(), thumb_data.capacity(), png_data.is_empty(), thumb_data.is_empty())
        }
        other => panic!("expected restored image at head of history, got {other:?}"),
    };
    assert!(restored.2 && restored.3, "restored entry must hold no blob bytes");
    assert_eq!(restored.0, 0, "png buffer capacity must be released, not cleared");
    assert_eq!(restored.1, 0, "thumb buffer capacity must be released, not cleared");
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
