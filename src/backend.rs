//! Global backend state: singleton, constants, and entry-id generator.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};
use crate::ignore::IgnoreRules;

/// One slot in the undo stack: the deleted entry plus its full text body.
/// Text entries no longer hold their body in memory, so it is loaded from DB
/// at delete time and stashed here for undo; images carry their blobs on the
/// entry itself and store `None`.
pub(crate) type DeletedStackEntry = (ClipboardEntry, Option<String>);

/// Max undo slots kept on the stack (newest N deletions).
pub(crate) const DELETE_STACK_LIMIT: usize = 10;

/// Total bytes of text bodies the undo stack may retain. Normal entries are
/// far below this; only very large pastes shed the oldest undo slots early.
pub(crate) const MAX_UNDO_BYTES: usize = 16 * 1024 * 1024;

/// Push an entry onto the undo stack, keeping the newest `DELETE_STACK_LIMIT`
/// entries AND bounding the total retained text bodies (`MAX_UNDO_BYTES`):
/// deleting a very large paste must not pin tens of MB in memory (the
/// in-memory history no longer holds bodies, so the undo stack is the only
/// place full text can accumulate). Oldest slots are shed until both caps
/// hold.
pub(crate) fn push_deleted(
    stack: &mut Vec<DeletedStackEntry>,
    entry: ClipboardEntry,
    undo_text: Option<String>,
) {
    stack.push((entry, undo_text));
    let mut bytes: usize = stack
        .iter()
        .filter_map(|(_, t)| t.as_ref().map(|s| s.len()))
        .sum();
    while stack.len() > DELETE_STACK_LIMIT || bytes > MAX_UNDO_BYTES {
        if let Some((_, Some(s))) = stack.first() {
            bytes = bytes.saturating_sub(s.len());
        }
        stack.remove(0);
    }
}

// ═══════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════

pub(crate) const DEFAULT_CLEANUP_THRESHOLD: usize = 3000;
pub(crate) const POLL_INTERVAL_MS: u64 = 300;

// ═══════════════════════════════════════════
// CopyAttach temp-file convention
// ═══════════════════════════════════════════

/// Absolute path to CopyAttach's own temp root (`$TMPDIR/CopyAttach`), shared
/// by the Rust paste-file writer (`Paste/` subdir) and the Swift drag provider
/// (`Drag/` subdir). Everything under this tree is a CopyAttach artifact and
/// must never re-enter the clipboard history.
pub(crate) fn copyattach_temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join("CopyAttach")
}

/// Whether `path` lives under CopyAttach's temp tree. Component-wise, so a
/// sibling directory like `$TMPDIR/CopyAttachFoo` is not matched.
pub(crate) fn is_copyattach_temp_path(path: &str) -> bool {
    Path::new(path).starts_with(copyattach_temp_root())
}

/// Process-local entitlement gate set by the Swift license verifier before the
/// clipboard core starts. 0 = denied/unknown, 1 = trial, 2 = perpetual.
pub(crate) static RUNTIME_ENTITLEMENT: AtomicUsize = AtomicUsize::new(0);

// ═══════════════════════════════════════════
// Entry-ID Generator
// ═══════════════════════════════════════════

/// Monotonic counter for assigning stable, unique IDs to clipboard entries.
static NEXT_ENTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Incremented each time Phase 2 image encoding completes and updates `db_id`
/// in the in-memory history. Swift polls this to detect thumbnail-ready items
/// without a count change.
pub(crate) static IMAGE_ENCODING_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Incremented whenever history ordering or entry metadata changes. The UI
/// must observe this separately from item count: deduplicating a re-copy keeps
/// the count constant while moving an existing item to the top.
pub(crate) static HISTORY_REVISION: AtomicU64 = AtomicU64::new(0);

pub(crate) fn mark_history_changed() {
    HISTORY_REVISION.fetch_add(1, Ordering::Relaxed);
}

pub(crate) fn new_entry_id() -> u64 {
    NEXT_ENTRY_ID.fetch_add(1, Ordering::SeqCst)
}

/// Set the entry-id counter to at least `min_next`, ensuring new IDs don't
/// collide with already-loaded IDs after a restart. Only moves the counter
/// upward; never backward (but that can't happen since we start from 1 and
/// the store is called once during init with a value >= loaded max + 1).
pub(crate) fn prime_entry_id(min_next: u64) {
    NEXT_ENTRY_ID.store(min_next, Ordering::SeqCst);
}

/// The exact pasteboard change made by this app while selecting an item. The
/// monitor consumes this change count once; it applies equally to text and
/// images and retains no clipboard payload.
pub(crate) struct PendingSelfWrite {
    pub(crate) change_count: i64,
}

// ═══════════════════════════════════════════
// Backend Struct & Singleton
// ═══════════════════════════════════════════

pub(crate) struct Backend {
    pub(crate) history: Arc<Mutex<Vec<ClipboardEntry>>>,
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    pub(crate) source_app: Arc<Mutex<SourceApp>>,
    pub(crate) last_seen_text: Arc<Mutex<Option<String>>>,
    pub(crate) last_seen_image_hash: Arc<Mutex<Option<u64>>>,
    /// Serializes our pasteboard writes with monitor event consumption, making
    /// self-write suppression race-free without retaining clipboard payloads.
    pub(crate) pasteboard_event_lock: Arc<Mutex<()>>,
    /// Exact pasteboard mutation produced by select-and-paste, if any.
    pub(crate) pending_self_write: Arc<Mutex<Option<PendingSelfWrite>>>,
    pub(crate) db: Arc<Mutex<Connection>>,
    pub(crate) cleanup_threshold: Arc<AtomicUsize>,
    /// Small, live-replaceable capture policy. It contains only configured rule
    /// metadata; clipboard payloads are never retained here.
    pub(crate) ignore_rules: Arc<Mutex<IgnoreRules>>,
    /// Stack of deleted entries for undo (Cmd+Z). Max 10 items.
    pub(crate) deleted_stack: Arc<Mutex<Vec<DeletedStackEntry>>>,
    /// Entry ID of the most recently undo-restored entry (0 if none).
    /// Used by Swift to find the restored entry in a snapshot despite
    /// monitor-thread insert races.
    pub(crate) last_restored_id: Arc<AtomicU64>,
}

static BACKEND: OnceLock<Backend> = OnceLock::new();

/// Panics if the backend has not been initialized. All FFI functions should
/// either guard with `BACKEND.get()` or call this after init is guaranteed.
pub(crate) fn backend() -> &'static Backend {
    BACKEND.get().expect("Clipboard backend not initialized. Call clipboard_init() first.")
}

/// Set the singleton. Returns `Ok(())` on first call, `Err(())` if already set.
pub(crate) fn set_backend(b: Backend) -> Result<(), ()> {
    BACKEND.set(b).map_err(|_| ())
}

/// Access the singleton without panicking.
pub(crate) fn try_backend() -> Option<&'static Backend> {
    BACKEND.get()
}

/// Reload the in-memory history from the database, respecting the configured
/// cleanup threshold. Returns the number of entries loaded.
///
/// Single source of truth for the pattern: lock db → load → take(threshold) →
/// drop db → lock history → assign → bump revision. Every caller that needs to
/// refresh the in-memory state from the DB should go through this function.
pub(crate) fn reload_history_from_db(b: &Backend) -> usize {
    let conn = b.db.lock().unwrap();
    let threshold = b.cleanup_threshold.load(std::sync::atomic::Ordering::Relaxed);
    let loaded = crate::db::load_history_from_db(&conn, threshold);
    let trimmed: Vec<ClipboardEntry> = loaded.into_iter().take(threshold).collect();
    let count = trimmed.len();
    drop(conn);

    let mut hist = b.history.lock().unwrap();
    *hist = trimmed;
    crate::backend::HISTORY_REVISION.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    count
}

#[cfg(test)]
mod temp_path_tests {
    use super::*;

    #[test]
    fn test_is_copyattach_temp_path() {
        let root = copyattach_temp_root();
        let root_str = root.to_string_lossy().into_owned();

        // Anything under the temp root belongs to CopyAttach.
        assert!(is_copyattach_temp_path(&root.join("Paste/clipboard-1-2.png").to_string_lossy()));
        assert!(is_copyattach_temp_path(&root.join("Drag/clipboard-1-2.png").to_string_lossy()));
        assert!(is_copyattach_temp_path(&root_str));

        // Component-wise match: a sibling with a shared prefix is not ours.
        let sibling = format!("{root_str}Foo/x.png");
        assert!(!is_copyattach_temp_path(&sibling));
        assert!(!is_copyattach_temp_path("/tmp/unrelated.png"));
    }
}
