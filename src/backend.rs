//! Global backend state: singleton, constants, and entry-id generator.

use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};
use crate::ignore::IgnoreRules;

/// Undo slot: deleted entry metadata plus its payload materialized on disk.
///
/// The full payload (text body, or PNG + thumbnail blobs) is written to a file
/// at delete time and the in-memory entry stays metadata-only. The undo stack
/// therefore never pins up to `MAX_UNDO_BYTES` of resident memory indefinitely
/// after a single deletion; the disk file is read back only when the user
/// actually undoes.
#[derive(Debug)]
pub(crate) struct DeletedStackEntry {
    pub(crate) entry: ClipboardEntry,
    /// Absolute path of the materialized payload file. Empty only for
    /// in-memory test slots constructed directly.
    pub(crate) payload_path: PathBuf,
    /// Payload bytes on disk; drives the `MAX_UNDO_BYTES` cap.
    pub(crate) payload_bytes: usize,
}

/// Max undo slots kept on the stack (newest N deletions).
pub(crate) const DELETE_STACK_LIMIT: usize = 1;

/// Max bytes the undo stack may retain across text and image payloads.
pub(crate) const MAX_UNDO_BYTES: usize = 48 * 1024 * 1024;

/// Bytes a stack slot retains on disk.
fn retained_bytes(slot: &DeletedStackEntry) -> usize {
    slot.payload_bytes
}

/// Delete a slot's payload file. No-op for in-memory test slots whose path is
/// empty.
pub(crate) fn remove_undo_payload_file(slot: &DeletedStackEntry) {
    if !slot.payload_path.as_os_str().is_empty() {
        if let Err(e) = std::fs::remove_file(&slot.payload_path) {
            crate::debug_log!("CopyAttach: failed to remove undo payload {}: {e}",
                slot.payload_path.display());
        }
    }
}

/// Push onto the undo stack, shedding oldest slots until both caps hold.
pub(crate) fn push_deleted(stack: &mut Vec<DeletedStackEntry>, slot: DeletedStackEntry) {
    stack.push(slot);
    let mut bytes: usize = stack.iter().map(retained_bytes).sum();
    while stack.len() > DELETE_STACK_LIMIT || bytes > MAX_UNDO_BYTES {
        if let Some(oldest) = stack.first() {
            bytes = bytes.saturating_sub(retained_bytes(oldest));
            remove_undo_payload_file(oldest);
        }
        stack.remove(0);
    }
    crate::debug_log!("CopyAttach: undo_push entries={} total_payload_bytes={}", stack.len(), bytes);
}

// Materialized undo payloads (on disk, under the CopyAttach temp root)

const UNDO_PAYLOAD_MAGIC: &[u8; 4] = b"CUND";
const UNDO_PAYLOAD_VERSION: u32 = 1;

/// Directory holding materialized undo payloads. The directory lives under the
/// CopyAttach temp root because an undo stack never survives a restart:
/// startup purges any stale files.
pub(crate) fn undo_payload_dir() -> Option<PathBuf> {
    let dir = copyattach_temp_root().join("Undo");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Payload read back from an undo file.
pub(crate) enum UndoPayload {
    Text(String),
    Image { png: Vec<u8>, thumb: Vec<u8> },
}

fn undo_io_err(action: &str, path: &Path, e: &std::io::Error) {
    crate::error_log!("CopyAttach: failed to {action} undo payload {}: {e}", path.display());
}

/// Serialize a deleted entry's payload to a new undo file. Returns the file
/// path and the number of payload bytes written. The entry's image blobs or
/// the `text` body are read once; the caller releases them after this returns.
pub(crate) fn write_undo_payload(
    entry: &ClipboardEntry,
    text: Option<&str>,
) -> Result<(PathBuf, usize), ()> {
    let dir = undo_payload_dir().ok_or_else(|| {
        crate::error_log!("CopyAttach: cannot create undo payload directory");
    })?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0);
    let path = dir.join(format!("undo-{}-{}.bin", entry.entry_id(), nonce));
    let file = std::fs::File::create(&path).map_err(|e| {
        undo_io_err("create", &path, &e);
    })?;
    let mut w = BufWriter::new(file);
    let mut written = 0usize;

    w.write_all(UNDO_PAYLOAD_MAGIC).map_err(|e| undo_io_err("write header", &path, &e))?;
    written += 4;
    w.write_all(&UNDO_PAYLOAD_VERSION.to_le_bytes()).map_err(|e| undo_io_err("write version", &path, &e))?;
    written += 4;

    match entry {
        ClipboardEntry::Text { .. } => {
            let body = text.ok_or_else(|| {
                crate::error_log!("CopyAttach: cannot materialize text undo payload without its body");
            })?;
            w.write_all(&0u32.to_le_bytes()).map_err(|e| undo_io_err("write kind", &path, &e))?;
            written += 4;
            w.write_all(&(body.len() as u64).to_le_bytes()).map_err(|e| undo_io_err("write text length", &path, &e))?;
            written += 8;
            w.write_all(body.as_bytes()).map_err(|e| undo_io_err("write text body", &path, &e))?;
            written += body.len();
        }
        ClipboardEntry::Image { png_data, thumb_data, .. } => {
            w.write_all(&1u32.to_le_bytes()).map_err(|e| undo_io_err("write kind", &path, &e))?;
            written += 4;
            w.write_all(&(png_data.len() as u64).to_le_bytes()).map_err(|e| undo_io_err("write png length", &path, &e))?;
            written += 8;
            w.write_all(png_data).map_err(|e| undo_io_err("write png body", &path, &e))?;
            written += png_data.len();
            w.write_all(&(thumb_data.len() as u64).to_le_bytes()).map_err(|e| undo_io_err("write thumb length", &path, &e))?;
            written += 8;
            w.write_all(thumb_data).map_err(|e| undo_io_err("write thumb body", &path, &e))?;
            written += thumb_data.len();
        }
    }
    w.flush().map_err(|e| undo_io_err("flush", &path, &e))?;
    Ok((path, written))
}

fn read_exact_or(r: &mut impl Read, buf: &mut [u8], path: &Path) -> Result<(), ()> {
    r.read_exact(buf).map_err(|e| undo_io_err("read", path, &e))
}

fn read_u32(r: &mut impl Read, path: &Path) -> Result<u32, ()> {
    let mut b = [0u8; 4];
    read_exact_or(r, &mut b, path)?;
    Ok(u32::from_le_bytes(b))
}

fn read_u64(r: &mut impl Read, path: &Path) -> Result<u64, ()> {
    let mut b = [0u8; 8];
    read_exact_or(r, &mut b, path)?;
    Ok(u64::from_le_bytes(b))
}

/// Read a materialized undo payload back into memory. The returned buffers are
/// claimed (`claim_pages`) because the allocator may have handed back pages
/// previously marked reusable; callers must mark them reusable before dropping.
pub(crate) fn read_undo_payload(path: &Path) -> Result<UndoPayload, ()> {
    let mut file = std::fs::File::open(path).map_err(|e| {
        undo_io_err("open", path, &e);
    })?;
    let mut magic = [0u8; 4];
    read_exact_or(&mut file, &mut magic, path)?;
    if &magic != UNDO_PAYLOAD_MAGIC {
        crate::error_log!("CopyAttach: undo payload {} has bad magic", path.display());
        return Err(());
    }
    let version = read_u32(&mut file, path)?;
    if version != UNDO_PAYLOAD_VERSION {
        crate::error_log!("CopyAttach: undo payload {} has unsupported version {version}", path.display());
        return Err(());
    }
    let kind = read_u32(&mut file, path)?;
    match kind {
        0 => {
            let len = read_u64(&mut file, path)? as usize;
            if len > MAX_UNDO_BYTES {
                crate::error_log!("CopyAttach: undo payload {} text length {len} exceeds cap", path.display());
                return Err(());
            }
            let mut buf = vec![0u8; len];
            read_exact_or(&mut file, &mut buf, path)?;
            let body = String::from_utf8(buf).map_err(|e| {
                crate::error_log!("CopyAttach: undo payload {} is not UTF-8: {e}", path.display());
            })?;
            crate::backend::claim_pages(body.as_ptr(), body.capacity());
            Ok(UndoPayload::Text(body))
        }
        1 => {
            let png_len = read_u64(&mut file, path)? as usize;
            let mut png = vec![0u8; png_len];
            read_exact_or(&mut file, &mut png, path)?;
            let thumb_len = read_u64(&mut file, path)? as usize;
            if png_len.saturating_add(thumb_len) > MAX_UNDO_BYTES {
                crate::error_log!("CopyAttach: undo payload {} image lengths exceed cap: png_len={png_len} thumb_len={thumb_len}", path.display());
                return Err(());
            }
            let mut thumb = vec![0u8; thumb_len];
            read_exact_or(&mut file, &mut thumb, path)?;
            crate::debug_log!("CopyAttach: undo read ok png_len={png_len} thumb_len={thumb_len} png_first={} thumb_first={}",
                png.first().copied().unwrap_or(0), thumb.first().copied().unwrap_or(0));
            claim_pages(png.as_ptr(), png.capacity());
            claim_pages(thumb.as_ptr(), thumb.capacity());
            Ok(UndoPayload::Image { png, thumb })
        }
        other => {
            crate::error_log!("CopyAttach: undo payload {} has unknown kind {other}", path.display());
            Err(())
        }
    }
}

/// Purge all materialized undo files. Called at startup: the in-memory undo
/// stack does not survive a restart, so every file in the directory is stale.
pub(crate) fn purge_undo_payload_dir() {
    let dir = copyattach_temp_root().join("Undo");
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        if e.kind() != std::io::ErrorKind::NotFound {
            crate::debug_log!("CopyAttach: failed to purge undo payload dir {}: {e}", dir.display());
        }
    }
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
        } else if self.guard.capacity() > 0 {
            // Idle pooled buffer: remove its pages from the footprint. Gate on
            // capacity, not len — a failed encode clears len but keeps the
            // pooled pages, and those must still stop counting.
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

/// Marks a transient blob Vec's pages reusable when dropped. Release-path
/// symmetry for buffers that were claimed on acquisition (DB blobs,
/// pasteboard reads): without this their pages stay dirty in the footprint
/// until the allocator happens to reuse them.
pub(crate) struct MarkBlobReusableOnDrop(pub(crate) Vec<u8>);

impl Drop for MarkBlobReusableOnDrop {
    fn drop(&mut self) {
        mark_pages_reusable(self.0.as_ptr(), self.0.capacity());
    }
}

/// String counterpart of [`MarkBlobReusableOnDrop`] for transient full-text
/// bodies loaded from SQLite (paste/preview/undo paths).
pub(crate) struct MarkStringReusableOnDrop(pub(crate) String);

impl Drop for MarkStringReusableOnDrop {
    fn drop(&mut self) {
        mark_pages_reusable(self.0.as_ptr(), self.0.capacity());
    }
}

/// Marks an entry's transient image blobs reusable on drop. Used by the
/// paste path, whose DB-loaded blobs are re-persisted from slices and never
/// stored — every early return must free their pages, so the guard owns the
/// entry for the scope.
pub(crate) struct MarkEntryBlobsReusableOnDrop(pub(crate) ClipboardEntry);

impl Drop for MarkEntryBlobsReusableOnDrop {
    fn drop(&mut self) {
        if let ClipboardEntry::Image { png_data, thumb_data, .. } = &self.0 {
            mark_pages_reusable(png_data.as_ptr(), png_data.capacity());
            mark_pages_reusable(thumb_data.as_ptr(), thumb_data.capacity());
        }
    }
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
    /// Stack of deleted entries for undo (Cmd+Z). Caps: DELETE_STACK_LIMIT
    /// entries + MAX_UNDO_BYTES total payload (see `push_deleted`).
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
