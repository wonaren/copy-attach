//! Global backend state: singleton, constants, and entry-id generator.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};
use crate::ignore::IgnoreRules;

/// Undo slot: deleted entry plus its text body (images carry their own blobs).
pub(crate) type DeletedStackEntry = (ClipboardEntry, Option<String>);

/// Max undo slots kept on the stack (newest N deletions).
pub(crate) const DELETE_STACK_LIMIT: usize = 10;

/// Max bytes the undo stack may retain across text and image payloads.
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

/// Push onto the undo stack, shedding oldest slots until both caps hold.
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
    crate::debug_log!("CopyAttach: undo_push entries={} total_payload_bytes={}", stack.len(), bytes);
}

// Constants

pub(crate) const DEFAULT_CLEANUP_THRESHOLD: usize = 3000;
/// Background clipboard poll cadence.
pub(crate) const POLL_INTERVAL_MS: u64 = 500;

// Debug logging toggle

/// Debug log gate; defaults to build profile, overridable at runtime.
static DEBUG_LOGGING: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

pub(crate) fn debug_log_enabled() -> bool {
    DEBUG_LOGGING.load(Ordering::Relaxed)
}

pub(crate) fn set_debug_logging(enabled: bool) {
    DEBUG_LOGGING.store(enabled, Ordering::Relaxed);
}

/// Backing implementation for `debug_log!`; writes unconditionally to stderr.
pub(crate) fn debug_log_fmt(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut err = std::io::stderr();
    let _ = err.write_fmt(args);
    let _ = err.write_all(b"\n");
}

/// Backing implementation for `error_log!`; always writes to stderr.
pub(crate) fn error_log_fmt(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut err = std::io::stderr();
    let _ = err.write_fmt(args);
    let _ = err.write_all(b"\n");
}

// CopyAttach temp-file convention

/// Absolute path to CopyAttach's temp root; its contents never re-enter history.
pub(crate) fn copyattach_temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join("CopyAttach")
}

/// Whether `path` is under CopyAttach's temp tree (component-wise).
pub(crate) fn is_copyattach_temp_path(path: &str) -> bool {
    Path::new(path).starts_with(copyattach_temp_root())
}

/// Process-local entitlement gate set by the Swift license verifier before the
/// clipboard core starts. 0 = denied/unknown, 1 = trial, 2 = perpetual.
pub(crate) static RUNTIME_ENTITLEMENT: AtomicUsize = AtomicUsize::new(0);

// Entry-ID Generator

/// Monotonic counter for assigning stable, unique IDs to clipboard entries.
static NEXT_ENTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Incremented when Phase 2 image encoding finishes and updates `db_id`.
pub(crate) static IMAGE_ENCODING_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Incremented whenever history ordering or metadata changes.
pub(crate) static HISTORY_REVISION: AtomicU64 = AtomicU64::new(0);

pub(crate) fn mark_history_changed() {
    HISTORY_REVISION.fetch_add(1, Ordering::Relaxed);
}

pub(crate) fn new_entry_id() -> u64 {
    NEXT_ENTRY_ID.fetch_add(1, Ordering::SeqCst)
}

/// Ensure new entry IDs won't collide with already-loaded IDs after restart.
pub(crate) fn prime_entry_id(min_next: u64) {
    NEXT_ENTRY_ID.store(min_next, Ordering::SeqCst);
}

/// The exact pasteboard change made by this app while selecting an item.
pub(crate) struct PendingSelfWrite {
    pub(crate) change_count: i64,
}

// Image capture scratch pool

/// Pooled Phase 2 PNG encode buffer, reused across captures.
static IMAGE_ENCODE_SCRATCH: Mutex<Vec<u8>> = Mutex::new(Vec::new());

/// Cap for retaining pooled encode scratch; oversized buffers are released.
pub(crate) const IMAGE_ENCODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

/// RAII guard returning the encode scratch buffer to the pool on drop.
pub(crate) struct ImageEncodeScratchGuard<'a> {
    guard: std::sync::MutexGuard<'a, Vec<u8>>,
}

impl<'a> ImageEncodeScratchGuard<'a> {
    pub(crate) fn acquire() -> Self {
        let guard = IMAGE_ENCODE_SCRATCH.lock().unwrap();
        crate::debug_log!("CopyAttach: encode_scratch acquire cap={}", guard.capacity());
        // Claim pages back before the encoder writes into the pooled buffer.
        claim_pages(guard.as_ptr(), guard.capacity());
        ImageEncodeScratchGuard { guard }
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
            // Mark oversized buffer pages reusable before releasing.
            crate::debug_log!("CopyAttach: encode_scratch drop oversized cap={} release",
                self.guard.capacity());
            mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity());
            *self.guard = Vec::new();
        } else if !self.guard.is_empty() {
            // Idle pooled buffer: remove its pages from the footprint.
            crate::debug_log!("CopyAttach: encode_scratch drop cap={} mark_reusable",
                self.guard.capacity());
            mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity());
        }
    }
}

// Purgeable scratch pages (MADV_FREE_REUSABLE)

/// Purgeable-memory helpers for macOS large allocations.
///
/// Only page-aligned blocks >= one page are marked, so small shared pages are
/// never affected. `MADV_FREE_REUSABLE` removes pages from the footprint;
/// `MADV_FREE_REUSE` claims them back.
const PAGE_SIZE: usize = 16 * 1024;

#[cfg(target_os = "macos")]
extern "C" {
    fn madvise(addr: *mut core::ffi::c_void, len: usize, advice: i32) -> i32;
}
#[cfg(target_os = "macos")]
const MADV_FREE_REUSABLE: i32 = 7; // "pages can be reused (by anyone)"
#[cfg(target_os = "macos")]
const MADV_FREE_REUSE: i32 = 8; // "caller wants to reuse those pages"

/// Mark page-aligned scratch memory as reusable by the system.
pub(crate) fn mark_pages_reusable(ptr: *const u8, byte_len: usize) {
    if byte_len < PAGE_SIZE {
        return;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
        // Unaligned blocks share pages with other allocations; never mark them.
        crate::debug_log!("CopyAttach: mark_pages_reusable SKIP unaligned base=0x{start:x} len={byte_len}");
        return;
    }
    let end = start + byte_len;
    let aligned_end = (end + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
    #[cfg(target_os = "macos")]
    unsafe {
        madvise(start as *mut core::ffi::c_void, aligned_end - start, MADV_FREE_REUSABLE);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = aligned_end;
}

/// Claim marked pages back before writing; contents are undefined.
pub(crate) fn claim_pages(ptr: *const u8, byte_len: usize) {
    if byte_len < PAGE_SIZE {
        return;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
        crate::debug_log!("CopyAttach: claim_pages SKIP unaligned base=0x{start:x} len={byte_len}");
        return;
    }
    let end = start + byte_len;
    let aligned_end = (end + PAGE_SIZE - 1) & !(PAGE_SIZE - 1);
    #[cfg(target_os = "macos")]
    unsafe {
        madvise(start as *mut core::ffi::c_void, aligned_end - start, MADV_FREE_REUSE);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = aligned_end;
}

// Image capture decode buffer pool

/// Pooled RGBA decode buffer, reused across image captures.
static IMAGE_DECODE_SCRATCH: Mutex<Option<Vec<u8>>> = Mutex::new(None);

/// Retention cap for the pooled decode buffer (bytes).
pub(crate) const IMAGE_DECODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

/// Owns the capture pipeline's RGBA pixel buffer for one ingest.
pub(crate) struct ImageDecodeBuffer {
    buf: Option<Vec<u8>>,
}

impl ImageDecodeBuffer {
    /// Take the pooled buffer (or a fresh one) and claim its pages for writing.
    pub(crate) fn acquire() -> Self {
        let buf = IMAGE_DECODE_SCRATCH.lock().unwrap().take().unwrap_or_default();
        if buf.capacity() > 0 {
            crate::debug_log!("CopyAttach: decode_scratch acquire cap={}", buf.capacity());
        }
        claim_pages(buf.as_ptr(), buf.capacity());
        ImageDecodeBuffer { buf: Some(buf) }
    }

    /// Wrap a fresh buffer; it still returns to the pool on drop.
    pub(crate) fn from_vec(v: Vec<u8>) -> Self {
        claim_pages(v.as_ptr(), v.capacity());
        ImageDecodeBuffer { buf: Some(v) }
    }

    pub(crate) fn as_mut_vec(&mut self) -> &mut Vec<u8> {
        self.buf.as_mut().expect("image decode buffer accessed after hand-off")
    }
}

impl Drop for ImageDecodeBuffer {
    fn drop(&mut self) {
        if let Some(buf) = self.buf.take() {
            if buf.capacity() <= IMAGE_DECODE_SCRATCH_RETAIN_CAP {
                let mut pool = IMAGE_DECODE_SCRATCH.lock().unwrap();
                if pool.is_none() {
                    // Idle pooled buffer: remove its pages from the footprint.
                    crate::debug_log!("CopyAttach: decode_scratch drop cap={} mark_reusable",
                        buf.capacity());
                    mark_pages_reusable(buf.as_ptr(), buf.capacity());
                    *pool = Some(buf);
                } else {
                    crate::debug_log!("CopyAttach: decode_scratch drop cap={} pool_busy release",
                        buf.capacity());
                    mark_pages_reusable(buf.as_ptr(), buf.capacity());
                }
            } else {
                // Mark oversized pages reusable before releasing.
                crate::debug_log!("CopyAttach: decode_scratch drop oversized cap={} release",
                    buf.capacity());
                mark_pages_reusable(buf.as_ptr(), buf.capacity());
            }
        }
    }
}

impl std::ops::Deref for ImageDecodeBuffer {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        self.buf.as_deref().unwrap_or(&[])
    }
}

// Backend Struct & Singleton

pub(crate) struct Backend {
    pub(crate) history: Arc<Mutex<Vec<ClipboardEntry>>>,
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    pub(crate) source_app: Arc<Mutex<SourceApp>>,
    /// Serializes our pasteboard writes with monitor event consumption.
    pub(crate) pasteboard_event_lock: Arc<Mutex<()>>,
    /// Exact pasteboard mutation produced by select-and-paste, if any.
    pub(crate) pending_self_write: Arc<Mutex<Option<PendingSelfWrite>>>,
    pub(crate) db: Arc<Mutex<Connection>>,
    pub(crate) cleanup_threshold: Arc<AtomicUsize>,
    /// Live-replaceable capture policy (metadata only, no payloads).
    pub(crate) ignore_rules: Arc<Mutex<IgnoreRules>>,
    /// Stack of deleted entries for undo (Cmd+Z). Max 10 items.
    pub(crate) deleted_stack: Arc<Mutex<Vec<DeletedStackEntry>>>,
    /// Entry ID of the most recently undo-restored entry (0 if none).
    pub(crate) last_restored_id: Arc<AtomicU64>,
}

static BACKEND: OnceLock<Backend> = OnceLock::new();

/// Returns the singleton, panicking if not yet initialized.
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

/// Reload in-memory history from the DB, respecting the cleanup threshold.
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

        assert!(is_copyattach_temp_path(&root.join("Paste/clipboard-1-2.png").to_string_lossy()));
        assert!(is_copyattach_temp_path(&root.join("Drag/clipboard-1-2.png").to_string_lossy()));
        assert!(is_copyattach_temp_path(&root_str));

        let sibling = format!("{root_str}Foo/x.png");
        assert!(!is_copyattach_temp_path(&sibling));
        assert!(!is_copyattach_temp_path("/tmp/unrelated.png"));
    }
}
