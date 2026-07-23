//! Global backend state: singleton, constants, and entry-id generator.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};
use crate::ignore::IgnoreRules;

// ═══════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════

pub(crate) const DEFAULT_CLEANUP_THRESHOLD: usize = 3000;
pub(crate) const POLL_INTERVAL_MS: u64 = 300;

// ═══════════════════════════════════════════
// Entry-ID Generator
// ═══════════════════════════════════════════

/// Monotonic counter for assigning stable, unique IDs to clipboard entries.
static NEXT_ENTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Incremented each time Phase 2 image encoding completes and updates db_id
/// in the in-memory history. Swift polls this to detect thumbnail-ready items
/// without a count change.
pub(crate) static IMAGE_ENCODING_COUNTER: AtomicU64 = AtomicU64::new(0);

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
    pub(crate) db: Arc<Mutex<Connection>>,
    pub(crate) cleanup_threshold: Arc<AtomicUsize>,
    /// Small, live-replaceable capture policy. It contains only configured rule
    /// metadata; clipboard payloads are never retained here.
    pub(crate) ignore_rules: Arc<Mutex<IgnoreRules>>,
    /// Stack of deleted entries for undo (Cmd+Z). Max 10 items.
    pub(crate) deleted_stack: Arc<Mutex<Vec<ClipboardEntry>>>,
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
