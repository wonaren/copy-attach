//! Global backend state: singleton, constants, and entry-id generator.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};

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

pub(crate) fn new_entry_id() -> u64 {
    NEXT_ENTRY_ID.fetch_add(1, Ordering::SeqCst)
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
    /// Stack of deleted entries for undo (Cmd+Z). Max 10 items.
    pub(crate) deleted_stack: Arc<Mutex<Vec<ClipboardEntry>>>,
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
