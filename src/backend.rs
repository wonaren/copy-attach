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
    crate::debug_log!("CopyAttach: undo_push entries={} total_payload_bytes={}", stack.len(), bytes);
}

// ═══════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════

pub(crate) const DEFAULT_CLEANUP_THRESHOLD: usize = 3000;
/// Background clipboard poll cadence. 500ms keeps capture latency well under a
/// second while further reducing idle wakeups on top of the single park/wake
/// primitive used by the monitor.
pub(crate) const POLL_INTERVAL_MS: u64 = 500;

// ═══════════════════════════════════════════
// Debug logging toggle
// ═══════════════════════════════════════════

/// Debug/release log gate.
///
/// Default follows the build profile: `cargo build` (debug_assertions) logs,
/// `cargo build --release` (distribution) does not. Swift can override this at
/// runtime through `clipboard_set_debug_logging` / the in-app setting so a
/// release build can still produce diagnostics when explicitly enabled.
static DEBUG_LOGGING: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

pub(crate) fn debug_log_enabled() -> bool {
    DEBUG_LOGGING.load(Ordering::Relaxed)
}

pub(crate) fn set_debug_logging(enabled: bool) {
    DEBUG_LOGGING.store(enabled, Ordering::Relaxed);
}

/// The implementation behind the `debug_log!` macro. The macro performs the
/// enabled check before formatting, so this function can write unconditionally.
/// Writing via `stderr()` keeps the macro definition free of `eprintln!`, so
/// mechanically replacing legacy `eprintln!` call sites with `crate::debug_log!`
/// is safe.
pub(crate) fn debug_log_fmt(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut err = std::io::stderr();
    let _ = err.write_fmt(args);
    let _ = err.write_all(b"\n");
}

/// Always-on implementation behind `error_log!`. This is intentionally not
/// gated: errors are exceptional and should survive release builds for support.
pub(crate) fn error_log_fmt(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut err = std::io::stderr();
    let _ = err.write_fmt(args);
    let _ = err.write_all(b"\n");
}

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
        let guard = IMAGE_ENCODE_SCRATCH.lock().unwrap();
        crate::debug_log!("CopyAttach: encode_scratch acquire cap={}", guard.capacity());
        // The pooled buffer may be marked reusable from the previous idle
        // cycle — claim its pages back before the encoder writes into it.
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
            // Release an oversized buffer without leaving its pages counted
            // as freed-but-retained residue: mark them reusable first.
            crate::debug_log!("CopyAttach: encode_scratch drop oversized cap={} release",
                self.guard.capacity());
            mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity());
            *self.guard = Vec::new();
        } else if !self.guard.is_empty() {
            // Idle pooled buffer: its pages stop counting against the process
            // footprint until the next capture claims them back.
            crate::debug_log!("CopyAttach: encode_scratch drop cap={} mark_reusable",
                self.guard.capacity());
            mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity());
        }
    }
}

// ═══════════════════════════════════════════
// Purgeable scratch pages (MADV_FREE_REUSABLE)
// ═══════════════════════════════════════════

/// macOS does not return freed large malloc pages to the process footprint by
/// ANY means (measured on this OS: `free`, `madvise(MADV_FREE)`,
/// `madvise(MADV_DONTNEED)` and `malloc_zone_pressure_relief` all leave
/// `phys_footprint` unchanged), so the background footprint of a clipboard
/// app ratchets up with every large transient allocation and stays there for
/// the session. The one working mechanism is the purgeable-memory contract:
/// `madvise(MADV_FREE_REUSABLE)` removes pages from the footprint and lets
/// the kernel hand them out; `madvise(MADV_FREE_REUSE)` claims them back for
/// writing. The two capture scratch pools use exactly this cycle — the buffer
/// is fully rewritten before every read (decode writes every pixel, the PNG
/// encoder writes every output byte), so the kernel reusing or zeroing an
/// idle pool's pages is harmless.
///
/// Safety: only buffers that are page-aligned and ≥ one page are marked —
/// those are the malloc large-zone (mmap'd) blocks, which own their pages
/// exclusively. Small blocks share pages with other allocations; marking a
/// shared page would forfeit a neighbor's data.
///
/// macOS page size (Apple Silicon; the max supported page size on arm64).
const PAGE_SIZE: usize = 16 * 1024;

#[cfg(target_os = "macos")]
extern "C" {
    fn madvise(addr: *mut core::ffi::c_void, len: usize, advice: i32) -> i32;
}
#[cfg(target_os = "macos")]
const MADV_FREE_REUSABLE: i32 = 7; // "pages can be reused (by anyone)"
#[cfg(target_os = "macos")]
const MADV_FREE_REUSE: i32 = 8; // "caller wants to reuse those pages"

/// Mark `[ptr, ptr + byte_len)` as reusable-by-anyone: the pages stop counting
/// against the process footprint and the kernel may reclaim them. Contents are
/// forfeited — only valid for scratch buffers fully rewritten before every
/// read. No-op unless the range starts page-aligned and covers ≥ one page
/// (the malloc large-zone / mmap'd blocks, which own their pages exclusively;
/// small blocks share pages with other allocations and are never marked).
pub(crate) fn mark_pages_reusable(ptr: *const u8, byte_len: usize) {
    if byte_len < PAGE_SIZE {
        return;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
        // A >=1-page block whose base is not page-aligned cannot come from the
        // malloc large zone (mmap'd, page-aligned) — it grew in place out of a
        // small-zone block and shares pages with other allocations, so it must
        // NOT be marked. Log only when debug logging is explicitly enabled;
        // such buffers silently pin their pages in the footprint, and this is
        // exactly the kind of path that would otherwise hide.
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

/// Claim marked pages back so writes land in them again. Contents are
/// undefined (the kernel may have reused or zeroed them) — callers must
/// rewrite before reading, which the scratch pools do by contract.
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

// ═══════════════════════════════════════
// Image capture decode buffer pool
// ═══════════════════════════════════════

/// Pooled RGBA pixel buffer for the capture pipeline's *input* side
/// (companion to [`IMAGE_ENCODE_SCRATCH`], which serves the output side).
///
/// macOS does not return large freed malloc regions to the OS promptly
/// (measured: a freed multi-MB decode buffer lingers as a retained region
/// while the next capture allocates a fresh one), so a per-capture
/// `to_rgba8()` alloc + free ratchets RSS upward with every large image
/// copied — the steady-state "常驻" the process shows at idle. The pool
/// keeps ONE allocation reused across captures; the guard is held from the
/// monitor-thread decode through the Phase 2 encode thread and returns the
/// buffer on every exit path (success, encode failure, DB failure). An
/// oversized buffer is released instead of pooled, so one huge image cannot
/// pin its peak size for the process lifetime (mirrors the encode scratch cap).
static IMAGE_DECODE_SCRATCH: Mutex<Option<Vec<u8>>> = Mutex::new(None);

/// Retention cap for the pooled decode buffer (bytes).
pub(crate) const IMAGE_DECODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

/// Owns the capture pipeline's RGBA pixel buffer for one ingest. `Deref`
/// exposes the pixels to hashing/thumbnail/encode; dropping returns the
/// buffer to the pool (or releases it when over the retention cap).
pub(crate) struct ImageDecodeBuffer {
    buf: Option<Vec<u8>>,
}

impl ImageDecodeBuffer {
    /// Take the pooled buffer (an empty `Vec` when the pool is currently
    /// borrowed by another in-flight ingest — captures can overlap the
    /// monitor thread's hand-off to the Phase 2 encode thread). Pages marked
    /// reusable by the previous idle cycle are claimed back for writing.
    pub(crate) fn acquire() -> Self {
        let buf = IMAGE_DECODE_SCRATCH.lock().unwrap().take().unwrap_or_default();
        if buf.capacity() > 0 {
            crate::debug_log!("CopyAttach: decode_scratch acquire cap={}", buf.capacity());
        }
        claim_pages(buf.as_ptr(), buf.capacity());
        ImageDecodeBuffer { buf: Some(buf) }
    }

    /// Wrap a freshly allocated buffer (the generic-decoder fallback for
    /// non-RGBA8 formats). It still returns to the pool on drop, so the next
    /// capture reuses it. The decoder has already written every byte, but the
    /// allocator may have handed back pages still marked reusable from an
    /// earlier scratch — claim them so the kernel cannot reclaim the pixels
    /// while the capture pipeline reads them (hashing/thumbnail/encode).
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
                // A buffer already parked there (an overlapping ingest
                // returned first) — release this one rather than churning.
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
                // Oversized: drop it, but mark first so its pages do not stay
                // counted as freed-but-retained residue.
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
