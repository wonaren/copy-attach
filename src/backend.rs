//! Global backend state: singleton, constants, and entry-id generator.

use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;
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
pub(crate) fn undo_payload_dir() -> Result<PathBuf, std::io::Error> {
    let dir = copyattach_temp_root().join("Undo");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
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
    image_blobs: Option<(&[u8], &[u8])>,
) -> Result<(PathBuf, usize), ()> {
    let dir = undo_payload_dir().map_err(|e| {
        crate::error_log!("CopyAttach: cannot create undo payload directory: {e}");
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
        ClipboardEntry::Image { .. } => {
            let (png_data, thumb_data) = image_blobs.ok_or_else(|| {
                crate::error_log!("CopyAttach: cannot materialize image undo payload without image blobs");
            })?;
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
            // A rejected claim leaves the body on pages the kernel may still
            // reclaim, so the restored text could read back zeroed. Fail the
            // undo instead of handing the user corrupted content (the slot is
            // re-pushed by the caller, so the retry stays available).
            if !crate::backend::claim_pages(body.as_ptr(), body.capacity()) {
                crate::backend::mark_pages_reusable(body.as_ptr(), body.capacity());
                crate::error_log!("CopyAttach: undo text payload {} could not be claimed — treating as unreadable", path.display());
                return Err(());
            }
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
            // Same rule as the text payload: an unclaimable blob is one the
            // kernel may zero while it is live, so refuse rather than restore
            // an image that renders as garbage.
            let png_ok = claim_pages(png.as_ptr(), png.capacity());
            let thumb_ok = claim_pages(thumb.as_ptr(), thumb.capacity());
            if !png_ok || !thumb_ok {
                // Release-side symmetry: whatever was claimed goes back to the
                // system before these buffers drop, or the pass leaves the pages
                // dirty in the footprint.
                crate::backend::mark_pages_reusable(png.as_ptr(), png.capacity());
                crate::backend::mark_pages_reusable(thumb.as_ptr(), thumb.capacity());
                crate::error_log!("CopyAttach: undo image payload {} could not be claimed — treating as unreadable", path.display());
                return Err(());
            }
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
    write_log_line(args);
}

/// Backing implementation for `error_log!`; always writes to stderr.
pub(crate) fn error_log_fmt(args: std::fmt::Arguments<'_>) {
    write_log_line(args);
}

/// One log line: <timestamp> <message>\n, written in a SINGLE write.
///
/// Both log macros share it so every Rust line carries the same UTC+8 stamp as
/// the Swift side's DebugLog (yyyy-MM-dd HH:mm:ss +0800). Without a stamp,
/// Rust-side errors were impossible to place on a timeline against the Swift
/// lines around them.
///
/// The single write matters: a human line must never be torn by a concurrent
/// perf record. Emitting the four pieces separately let a one-write trace
/// record land between the timestamp and the message, producing a line like
/// "2026-09-16 21:11:28 +0800__CA_PERF__ ..." — corrupting both records.
fn write_log_line(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut line = String::with_capacity(96);
    line.push_str(&log_timestamp());
    line.push(' ');
    let _ = std::fmt::Write::write_fmt(&mut line, args);
    line.push('\n');
    // stderr is unbuffered in Rust, so this is one write(2) to the log fd.
    let _ = std::io::stderr().write_all(line.as_bytes());
}

/// Current time stamped as UTC+8, matching the Swift formatter.
fn log_timestamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format_log_timestamp(secs)
}

/// Format Unix seconds as `yyyy-MM-dd HH:mm:ss +0800`.
///
/// The offset is fixed rather than taken from the system timezone: the log is a
/// support artifact that gets compared across machines, and a fixed offset
/// makes two reports directly comparable (the stamp spells out `+0800`, so a
/// reader in another timezone can still convert).
pub(crate) fn format_log_timestamp(unix_secs: u64) -> String {
    const UTC8_OFFSET_SECS: u64 = 8 * 3600;
    let shifted = unix_secs + UTC8_OFFSET_SECS;
    let (y, m, d) = civil_from_days((shifted / 86_400) as i64);
    let sod = shifted % 86_400;
    format!(
        "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02} +0800",
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

/// Days since 1970-01-01 → (year, month, day); Howard Hinnant's civil_from_days.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
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

// Entry-ID Generator

/// Monotonic counter for assigning stable, unique IDs to clipboard entries.
static NEXT_ENTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Incremented when Phase 2 persists a full-resolution image and assigns the
/// entry's `db_id` — on both the encode path and the `ExistingPng` path, where
/// the pasteboard already carried PNG and nothing is re-encoded. It signals
/// that a row's image blob became loadable, not that encoding ran.
pub(crate) static IMAGE_ENCODING_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Incremented whenever history ordering or metadata changes.
pub(crate) static HISTORY_REVISION: AtomicU64 = AtomicU64::new(0);

// History-change event wire.
//
// The UI used to poll the counters below on a 500 ms timer, so a capture took up
// to half a second to appear (measured p95 ~522 ms end to end, while the backend
// itself finished in ~1 ms). The frontend now blocks on this channel instead,
// which turns capture -> visible into a latency proportional to the actual work
// rather than to a timer period.
//
// Contract: the pending revision is stored and notified in the same critical
// section as the mutation it describes, and only while the history lock is held.
// Because every history mutation takes the history lock, this makes
// "mutate -> publish" atomic:
//
//   * a waiter can never miss a change (either it observes the bumped revision,
//     or the pending value is still set from an earlier unpublished change), and
//   * a burst of changes between two waits costs one backend reload at most,
//     because the pending value collapses them into a single "changed" signal.
//
// Callers must invoke mark_history_changed() while holding the history lock (or
// a lock that serializes against it). Every mutation site does so.
static HISTORY_EVENT: OnceLock<Arc<(Mutex<u64>, Condvar)>> = OnceLock::new();
const NO_EVENT: u64 = u64::MAX;

fn history_event() -> &'static (Mutex<u64>, Condvar) {
    HISTORY_EVENT.get_or_init(|| Arc::new((Mutex::new(NO_EVENT), Condvar::new())))
}

/// Publish a history change. MUST be called while holding the history lock (or a
/// lock that serializes with it): the revision increment and the wakeup then
/// cannot be reordered against the mutation by another thread.
pub(crate) fn mark_history_changed() {
    HISTORY_REVISION.fetch_add(1, Ordering::Relaxed);
    let (m, cv) = history_event();
    let mut pending = m.lock().unwrap_or_else(|e| e.into_inner());
    *pending = HISTORY_REVISION.load(Ordering::Relaxed);
    cv.notify_all();
}

/// Block until history changes after since, or timeout_ms elapses.
///
/// Returns the newest observed revision (always > since when awakened), or the
/// current revision on timeout. The timeout is a safety net against a missed
/// wakeup: with a correct publish protocol it should never fire, but the UI must
/// never hang forever if a notify is ever lost.
#[no_mangle]
pub extern "C" fn clipboard_wait_for_history_change(since: u64, timeout_ms: u64) -> u64 {
    let (m, cv) = history_event();
    let mut pending = m.lock().unwrap_or_else(|e| e.into_inner());
    if *pending == NO_EVENT || *pending <= since {
        let (guard, _timeout) = cv
            .wait_timeout_while(pending, Duration::from_millis(timeout_ms), |p| {
                *p == NO_EVENT || *p <= since
            })
            .unwrap_or_else(|e| e.into_inner());
        pending = guard;
    }
    let current = HISTORY_REVISION.load(Ordering::Relaxed);
    if *pending != NO_EVENT && *pending > since {
        *pending
    } else {
        current.max(since)
    }
}

/// The revision values the UI keys its reload decision on, read together so the
/// comparison stays consistent with the counters the backend increments.
#[no_mangle]
pub extern "C" fn clipboard_history_counters(
    out_revision: *mut u64,
    out_image_encoding: *mut u64,
) -> i32 {
    if out_revision.is_null() || out_image_encoding.is_null() {
        return 0;
    }
    unsafe {
        *out_revision = HISTORY_REVISION.load(Ordering::Relaxed);
        *out_image_encoding = IMAGE_ENCODING_COUNTER.load(Ordering::Relaxed);
    }
    1
}

pub(crate) fn new_entry_id() -> u64 {
    NEXT_ENTRY_ID.fetch_add(1, Ordering::SeqCst)
}

/// Ensure new entry IDs won't collide with ids already issued for this
/// database.
///
/// Monotonic (`fetch_max`, not `store`): ids are the identity Swift records
/// favorites against, so moving the counter backwards would hand out an id
/// that a favorite still points at, and an unrelated new capture would come
/// up already-starred.
pub(crate) fn prime_entry_id(min_next: u64) {
    NEXT_ENTRY_ID.fetch_max(min_next, Ordering::SeqCst);
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
        let mut guard = IMAGE_ENCODE_SCRATCH.lock().unwrap();
        crate::debug_log!("CopyAttach: encode_scratch acquire cap={}", guard.capacity());
        // Claim pages back before the encoder writes into the pooled buffer.
        // A failed claim leaves pages in an unknown reclaimable state, so the
        // buffer must not be written to: drop it and let the encoder allocate.
        if !claim_pages(guard.as_ptr(), guard.capacity()) {
            crate::debug_log!("CopyAttach: encode_scratch claim failed cap={} release",
                guard.capacity());
            *guard = Vec::new();
        }
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
            if !mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity()) {
                // The mapping rejects madvise (EINVAL from a realloc-spliced
                // region). Pooling it would pin dirty pages for the process
                // lifetime and make every later mark/claim fail too.
                crate::debug_log!("CopyAttach: encode_scratch drop cap={} unmarkable release",
                    self.guard.capacity());
                *self.guard = Vec::new();
            }
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

#[cfg(target_os = "macos")]
fn advise_pages(ptr: *const u8, byte_len: usize, advice: i32, operation: &str) -> bool {
    let result = unsafe { madvise(ptr as *mut core::ffi::c_void, byte_len, advice) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        // A rejected madvise means the footprint contract broke for this
        // buffer. The first occurrence per process is a real defect signal
        // and must survive with debug logging off; repeats stay verbose-only.
        static REPORTED: AtomicBool = AtomicBool::new(false);
        if !REPORTED.swap(true, Ordering::SeqCst) {
            crate::error_log!("CopyAttach: madvise {operation} failed len={byte_len}: {error} (first occurrence; buffer will not be pooled)");
        } else {
            crate::debug_log!("CopyAttach: madvise {operation} failed len={byte_len}: {error}");
        }
        return false;
    }
    true
}

/// `SKIP unaligned` is benign (small-zone blobs) but 1000+ lines per day
/// bury real signals; log the first few then every 256th.
fn log_skip_unaligned(what: &str, start: usize, byte_len: usize) {
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let n = COUNT.fetch_add(1, Ordering::Relaxed);
    if n < 4 || n.is_multiple_of(256) {
        crate::debug_log!("CopyAttach: {what} SKIP unaligned base=0x{start:x} len={byte_len} (occurrence #{})", n + 1);
    }
}

/// Mark page-aligned scratch memory as reusable by the system.
///
/// Only whole pages strictly inside the buffer bounds are marked reusable.
/// Sub-page remainders at the end are rounded down to avoid advising adjacent
/// heap allocations that might share or sit directly past this buffer.
///
/// Returns `false` only when the kernel rejected the advice (EINVAL on a
/// mapping that `vm_map_reusable_pages` cannot handle, e.g. a block that
/// libmalloc grew in place across several VM entries). Callers that pool the
/// buffer must release it in that case: such a mapping keeps rejecting every
/// later mark/claim, and pooling it pins the dirty pages for the process
/// lifetime. Small or unaligned blocks are skipped and return `true` — there
/// is nothing to mark and pooling them is harmless.
pub(crate) fn mark_pages_reusable(ptr: *const u8, byte_len: usize) -> bool {
    if byte_len < PAGE_SIZE {
        return true;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
        // Unaligned blocks share pages with other allocations; never mark them.
        log_skip_unaligned("mark_pages_reusable", start, byte_len);
        return true;
    }
    let aligned_len = byte_len & !(PAGE_SIZE - 1);
    if aligned_len < PAGE_SIZE {
        return true;
    }
    #[cfg(target_os = "macos")]
    return advise_pages(ptr, aligned_len, MADV_FREE_REUSABLE, "FREE_REUSABLE");
    #[cfg(not(target_os = "macos"))]
    {
        let _ = aligned_len;
        true
    }
}

/// Claim marked pages back before writing; contents are undefined.
///
/// Symmetric with `mark_pages_reusable`: claims only whole pages strictly
/// within the buffer bounds. Returns `false` when the kernel rejected the
/// claim; the caller must then treat the buffer as unusable (its pages may
/// still be reclaimable while live) and allocate afresh.
///
/// The result is `#[must_use]` because the failure is silent and severe: the
/// allocator hands back freed-but-marked blocks as-is, so a buffer whose claim
/// was rejected can be zeroed by the kernel while it is live. Ignoring the
/// return is only correct where the buffer is about to be fully overwritten
/// before any read — and that intent has to be written down, not implied.
#[must_use = "a rejected claim leaves the buffer reclaimable while live; either branch on the result or document why the buffer is fully rewritten"]
pub(crate) fn claim_pages(ptr: *const u8, byte_len: usize) -> bool {
    if byte_len < PAGE_SIZE {
        return true;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
        log_skip_unaligned("claim_pages", start, byte_len);
        return true;
    }
    let aligned_len = byte_len & !(PAGE_SIZE - 1);
    if aligned_len < PAGE_SIZE {
        return true;
    }
    #[cfg(target_os = "macos")]
    return advise_pages(ptr, aligned_len, MADV_FREE_REUSE, "FREE_REUSE");
    #[cfg(not(target_os = "macos"))]
    {
        let _ = aligned_len;
        true
    }
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

/// Marks transient image blobs (PNG and thumb) reusable on drop. Used by
/// paste and delete/undo paths that load blobs from SQLite.
pub(crate) struct MarkImageBlobsReusableOnDrop {
    pub(crate) png: Vec<u8>,
    pub(crate) thumb: Vec<u8>,
}

impl Drop for MarkImageBlobsReusableOnDrop {
    fn drop(&mut self) {
        mark_pages_reusable(self.png.as_ptr(), self.png.capacity());
        mark_pages_reusable(self.thumb.as_ptr(), self.thumb.capacity());
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
        let mut buf = IMAGE_DECODE_SCRATCH.lock().unwrap().take().unwrap_or_default();
        if buf.capacity() > 0 {
            crate::debug_log!("CopyAttach: decode_scratch acquire cap={}", buf.capacity());
        }
        if !claim_pages(buf.as_ptr(), buf.capacity()) {
            // Unclaimable pages may be reclaimed while live; never decode
            // into them. The decoder will allocate a fresh block.
            crate::debug_log!("CopyAttach: decode_scratch claim failed cap={} release",
                buf.capacity());
            buf = Vec::new();
        }
        ImageDecodeBuffer { buf: Some(buf) }
    }

    /// Wrap a fresh buffer; it still returns to the pool on drop.
    ///
    /// An unclaimable buffer is dropped rather than carried: its pages may be
    /// reclaimed while the decode pipeline writes into them. `Vec::new()` is
    /// the honest representation of "no usable buffer" here, and the caller's
    /// fill/allocate path handles the empty capacity.
    pub(crate) fn from_vec(v: Vec<u8>) -> Self {
        if !claim_pages(v.as_ptr(), v.capacity()) {
            crate::debug_log!("CopyAttach: from_vec claim failed cap={} release", v.capacity());
            mark_pages_reusable(v.as_ptr(), v.capacity());
            return ImageDecodeBuffer { buf: Some(Vec::new()) };
        }
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
                    // Only a successfully marked buffer goes back to the pool;
                    // an unmarkable mapping would fail forever and pin its
                    // dirty pages until process exit.
                    crate::debug_log!("CopyAttach: decode_scratch drop cap={} mark_reusable",
                        buf.capacity());
                    if mark_pages_reusable(buf.as_ptr(), buf.capacity()) {
                        *pool = Some(buf);
                    } else {
                        crate::debug_log!("CopyAttach: decode_scratch drop cap={} unmarkable release",
                            buf.capacity());
                    }
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

// NOTE: there is deliberately NO panicking accessor here. These functions are
// called from extern "C" entry points, where a panic cannot unwind ("panic in a
// function that cannot unwind" -> abort / SIGABRT). The UI can reach them
// before or without a successful clipboard_init (init is gated on entitlement
// and is retried on failure), so a panicking accessor turns a recoverable
// "backend unavailable" state into a hard process crash.
// Always use try_backend() and return the documented sentinel.

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
    // Publish under the history lock (bulk reload replaced the whole list).
    mark_history_changed();

    count
}

#[cfg(test)]
mod history_event_tests {
    use super::*;

    /// A publish from another thread must wake a parked waiter.
    ///
    /// Robust under parallel tests: it asserts only that our own publish is
    /// observed, so unrelated concurrent publishes cannot make it fail (at
    /// worst they wake the waiter early — still a wake).
    #[test]
    fn test_wait_wakes_on_publish() {
        let before = HISTORY_REVISION.load(Ordering::Relaxed);
        let publisher = thread::spawn(|| {
            thread::sleep(Duration::from_millis(40));
            mark_history_changed();
        });
        let observed = clipboard_wait_for_history_change(before, 5_000);
        publisher.join().unwrap();
        assert!(
            observed > before,
            "waiter did not observe the publish: before={before} observed={observed}"
        );
    }

    /// A waiter that can never be satisfied must time out and return the input
    /// revision. u64::MAX is unreachable by any real revision, so concurrent
    /// publishes cannot spuriously satisfy it — deterministic under parallelism.
    #[test]
    fn test_wait_times_out() {
        let start = std::time::Instant::now();
        let observed = clipboard_wait_for_history_change(u64::MAX, 80);
        let elapsed = start.elapsed();
        assert_eq!(observed, u64::MAX);
        assert!(
            elapsed >= Duration::from_millis(60),
            "returned before the timeout: {elapsed:?}"
        );
    }
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
