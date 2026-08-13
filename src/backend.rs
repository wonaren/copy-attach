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
/// at delete time and stashed here for undo; image entries carry their PNG +
/// thumbnail blobs on the entry itself and store `None`.
pub(crate) type DeletedStackEntry = (ClipboardEntry, Option<String>);

/// Max undo slots kept on the stack (newest N deletions).
pub(crate) const DELETE_STACK_LIMIT: usize = 10;

/// Total bytes the undo stack may retain, counting text bodies AND image
/// blobs (png + thumb). The undo stack is the only place full payloads can
/// accumulate (the in-memory history holds metadata only), so without a
/// unified byte cap deleting a handful of large images would pin unbounded
/// memory until process exit. 48 MB covers ~10 typical multi-MB deletions;
/// oversized payloads shed oldest slots first — symmetric with the existing
/// text behavior, where a single pasted body above the cap is already
/// un-undoable.
pub(crate) const MAX_UNDO_BYTES: usize = 48 * 1024 * 1024;

/// Bytes a stack slot retains: full text body for text entries, PNG +
/// thumbnail blobs for image entries.
fn retained_bytes((entry, text): &DeletedStackEntry) -> usize {
    match (entry, text) {
        (_, Some(t)) => t.len(),
        (ClipboardEntry::Image { png_data, thumb_data, .. }, None) => {
            png_data.len() + thumb_data.len()
        }
        _ => 0,
    }
}

/// Push an entry onto the undo stack, keeping the newest `DELETE_STACK_LIMIT`
/// entries AND bounding the total retained payload bytes (`MAX_UNDO_BYTES`):
/// deleting very large pastes or images must not pin tens of MB in memory.
/// Oldest slots are shed until both caps hold.
pub(crate) fn push_deleted(
    stack: &mut Vec<DeletedStackEntry>,
    entry: ClipboardEntry,
    undo_text: Option<String>,
) {
    stack.push((entry, undo_text));
    let mut bytes: usize = stack.iter().map(retained_bytes).sum();
    while stack.len() > DELETE_STACK_LIMIT || bytes > MAX_UNDO_BYTES {
        if let Some(oldest) = stack.first() {
            bytes = bytes.saturating_sub(retained_bytes(oldest));
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
// Image capture scratch pool
// ═══════════════════════════════════════════

/// Reusable full-PNG encode scratch buffer for the capture pipeline's Phase 2
/// (see `monitor::ingest_rgba_image`). Captures are serialized by the monitor
/// thread, so one pooled buffer serves them all — a fresh multi-MB Vec per
/// capture would otherwise churn the malloc zone (large freed blocks are not
/// returned to the OS promptly in this process — measured: CFData/pasteboard
/// copies and multi-MB decode buffers linger as retained regions). The guard
/// is held across the whole Phase 2 body (encode + DB bind), then the buffer
/// returns to the pool.
static IMAGE_ENCODE_SCRATCH: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// The pooled Phase 2 encode buffer may retain capacity across captures, but
/// one oversized encode must not pin its peak size for the process lifetime.
/// Buffers below this cap keep their capacity (the point of the pool); on
/// guard drop above the cap the pool is replaced with a fresh `Vec`, freeing
/// the oversized allocation immediately.
pub(crate) const IMAGE_ENCODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

/// RAII guard over the Phase 2 encode scratch pool. Dropping it returns the
/// buffer to the pool, trimming the pool to an empty `Vec` when the retained
/// capacity exceeds [`IMAGE_ENCODE_SCRATCH_RETAIN_CAP`] — covering every exit
/// path of the encode thread (success, encode failure, DB failure) without
/// explicit cleanup at each `return`.
pub(crate) struct ImageEncodeScratchGuard<'a> {
    guard: std::sync::MutexGuard<'a, Vec<u8>>,
}

impl<'a> ImageEncodeScratchGuard<'a> {
    pub(crate) fn acquire() -> Self {
        ImageEncodeScratchGuard {
            guard: IMAGE_ENCODE_SCRATCH.lock().unwrap(),
        }
    }
}

impl std::ops::Deref for ImageEncodeScratchGuard<'_> {
    type Target = Vec<u8>;
    fn deref(&self) -> &Vec<u8> {
        &self.guard
    }
}

impl std::ops::DerefMut for ImageEncodeScratchGuard<'_> {
    fn deref_mut(&mut self) -> &mut Vec<u8> {
        &mut self.guard
    }
}

impl Drop for ImageEncodeScratchGuard<'_> {
    fn drop(&mut self) {
        if self.guard.capacity() > IMAGE_ENCODE_SCRATCH_RETAIN_CAP {
            *self.guard = Vec::new();
        }
    }
}

// ═══════════════════════════════════════════
// Backend Struct & Singleton
// ═══════════════════════════════════════════

pub(crate) struct Backend {
    pub(crate) history: Arc<Mutex<Vec<ClipboardEntry>>>,
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    pub(crate) source_app: Arc<Mutex<SourceApp>>,
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
