use std::collections::HashSet;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use rusqlite::Connection;

use crate::types::{ClipboardEntry, SourceApp};
use crate::ignore::IgnoreRules;

pub(crate) fn purge_legacy_undo_payload_dir() {
    let dir = copyattach_temp_root().join("Undo");
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        if e.kind() != std::io::ErrorKind::NotFound {
            crate::debug_log!("CopyAttach: failed to purge legacy undo payload dir {}: {e}", dir.display());
        }
    }
}

pub(crate) const DEFAULT_CLEANUP_THRESHOLD: usize = 3000;
pub(crate) const MAX_CLEANUP_THRESHOLD: usize = 10000;
pub(crate) const MIN_CLEANUP_THRESHOLD: usize = 100;
pub(crate) const POLL_INTERVAL_MS: u64 = 500;

pub(crate) const UNDO_RETENTION_SECS: u64 = 7 * 24 * 60 * 60;

pub(crate) const DEFAULT_UNDO_BUDGET_MB: i64 = 16;

pub(crate) const MAX_UNDO_BUDGET_MB: i64 = 512;

pub(crate) const UNDO_BUDGET_UNLIMITED: i64 = 0;

pub(crate) fn undo_stamp_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0)
}

pub(crate) fn undo_budget_bytes() -> i64 {
    match BACKEND.get() {
        Some(b) => b.undo_budget_bytes.load(Ordering::Relaxed),
        None => DEFAULT_UNDO_BUDGET_MB * 1024 * 1024,
    }
}

static DEBUG_LOGGING: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

pub(crate) fn debug_log_enabled() -> bool {
    DEBUG_LOGGING.load(Ordering::Relaxed)
}

pub(crate) fn set_debug_logging(enabled: bool) {
    DEBUG_LOGGING.store(enabled, Ordering::Relaxed);
}

pub(crate) fn debug_log_fmt(args: std::fmt::Arguments<'_>) {
    write_log_line(args);
}

pub(crate) fn error_log_fmt(args: std::fmt::Arguments<'_>) {
    write_log_line(args);
}

fn write_log_line(args: std::fmt::Arguments<'_>) {
    use std::io::Write;
    let mut line = String::with_capacity(96);
    line.push_str(&log_timestamp());
    line.push(' ');
    let _ = std::fmt::Write::write_fmt(&mut line, args);
    line.push('\n');
    let _ = std::io::stderr().write_all(line.as_bytes());
}

fn log_timestamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format_log_timestamp(secs)
}

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

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub(crate) fn copyattach_temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join("CopyAttach")
}

pub(crate) fn is_copyattach_temp_path(path: &str) -> bool {
    Path::new(path).starts_with(copyattach_temp_root())
}

static NEXT_ENTRY_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) static IMAGE_ENCODING_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) static HISTORY_REVISION: AtomicU64 = AtomicU64::new(0);

static HISTORY_EVENT: OnceLock<Arc<(Mutex<u64>, Condvar)>> = OnceLock::new();
const NO_EVENT: u64 = u64::MAX;

fn history_event() -> &'static (Mutex<u64>, Condvar) {
    HISTORY_EVENT.get_or_init(|| Arc::new((Mutex::new(NO_EVENT), Condvar::new())))
}

pub(crate) fn mark_history_changed() {
    HISTORY_REVISION.fetch_add(1, Ordering::Relaxed);
    let (m, cv) = history_event();
    let mut pending = m.lock().unwrap_or_else(|e| e.into_inner());
    *pending = HISTORY_REVISION.load(Ordering::Relaxed);
    cv.notify_all();
}

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

pub(crate) fn prime_entry_id(min_next: u64) {
    NEXT_ENTRY_ID.fetch_max(min_next, Ordering::SeqCst);
}

pub(crate) struct PendingSelfWrite {
    pub(crate) change_count: i64,
}

static IMAGE_ENCODE_SCRATCH: Mutex<Vec<u8>> = Mutex::new(Vec::new());

pub(crate) const IMAGE_ENCODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

pub(crate) struct ImageEncodeScratchGuard<'a> {
    guard: std::sync::MutexGuard<'a, Vec<u8>>,
}

impl<'a> ImageEncodeScratchGuard<'a> {
    pub(crate) fn acquire() -> Self {
        let mut guard = IMAGE_ENCODE_SCRATCH.lock().unwrap();
        crate::debug_log!("CopyAttach: encode_scratch acquire cap={}", guard.capacity());
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
            crate::debug_log!("CopyAttach: encode_scratch drop oversized cap={} release",
                self.guard.capacity());
            mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity());
            *self.guard = Vec::new();
        } else if self.guard.capacity() > 0 {
            crate::debug_log!("CopyAttach: encode_scratch drop cap={} mark_reusable",
                self.guard.capacity());
            if !mark_pages_reusable(self.guard.as_ptr(), self.guard.capacity()) {
                crate::debug_log!("CopyAttach: encode_scratch drop cap={} unmarkable release",
                    self.guard.capacity());
                *self.guard = Vec::new();
            }
        }
    }
}

const PAGE_SIZE: usize = 16 * 1024;

#[cfg(target_os = "macos")]
extern "C" {
    fn madvise(addr: *mut core::ffi::c_void, len: usize, advice: i32) -> i32;
}
#[cfg(target_os = "macos")]
const MADV_FREE_REUSABLE: i32 = 7;
#[cfg(target_os = "macos")]
const MADV_FREE_REUSE: i32 = 8;

#[cfg(target_os = "macos")]
fn advise_pages(ptr: *const u8, byte_len: usize, advice: i32, operation: &str) -> bool {
    let result = unsafe { madvise(ptr as *mut core::ffi::c_void, byte_len, advice) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
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

fn log_skip_unaligned(what: &str, start: usize, byte_len: usize) {
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let n = COUNT.fetch_add(1, Ordering::Relaxed);
    if n < 4 || n.is_multiple_of(256) {
        crate::debug_log!("CopyAttach: {what} SKIP unaligned base=0x{start:x} len={byte_len} (occurrence #{})", n + 1);
    }
}

pub(crate) fn mark_pages_reusable(ptr: *const u8, byte_len: usize) -> bool {
    if byte_len < PAGE_SIZE {
        return true;
    }
    let start = ptr as usize;
    if !start.is_multiple_of(PAGE_SIZE) {
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

pub(crate) struct MarkBlobReusableOnDrop(pub(crate) Vec<u8>);

impl Drop for MarkBlobReusableOnDrop {
    fn drop(&mut self) {
        mark_pages_reusable(self.0.as_ptr(), self.0.capacity());
    }
}

pub(crate) struct MarkStringReusableOnDrop(pub(crate) String);

impl Drop for MarkStringReusableOnDrop {
    fn drop(&mut self) {
        mark_pages_reusable(self.0.as_ptr(), self.0.capacity());
    }
}

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

static IMAGE_DECODE_SCRATCH: Mutex<Option<Vec<u8>>> = Mutex::new(None);

pub(crate) const IMAGE_DECODE_SCRATCH_RETAIN_CAP: usize = 64 * 1024 * 1024;

pub(crate) struct ImageDecodeBuffer {
    buf: Option<Vec<u8>>,
}

impl ImageDecodeBuffer {
    pub(crate) fn acquire() -> Self {
        let mut buf = IMAGE_DECODE_SCRATCH.lock().unwrap().take().unwrap_or_default();
        if buf.capacity() > 0 {
            crate::debug_log!("CopyAttach: decode_scratch acquire cap={}", buf.capacity());
        }
        if !claim_pages(buf.as_ptr(), buf.capacity()) {
            crate::debug_log!("CopyAttach: decode_scratch claim failed cap={} release",
                buf.capacity());
            buf = Vec::new();
        }
        ImageDecodeBuffer { buf: Some(buf) }
    }

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

pub(crate) struct Backend {
    pub(crate) history: Arc<Mutex<Vec<ClipboardEntry>>>,
    pub(crate) running: Arc<AtomicBool>,
    pub(crate) monitor_handle: Mutex<Option<thread::JoinHandle<()>>>,
    pub(crate) source_app: Arc<Mutex<SourceApp>>,
    pub(crate) pasteboard_event_lock: Arc<Mutex<()>>,
    pub(crate) pending_self_write: Arc<Mutex<Option<PendingSelfWrite>>>,
    pub(crate) db: Arc<Mutex<Connection>>,
    pub(crate) cleanup_threshold: Arc<AtomicUsize>,
    pub(crate) ignore_rules: Arc<Mutex<IgnoreRules>>,
    pub(crate) undo_budget_bytes: Arc<AtomicI64>,
    pub(crate) last_restored_id: Arc<AtomicU64>,
    pub(crate) favorites: Arc<Mutex<HashSet<u64>>>,
}

static BACKEND: OnceLock<Backend> = OnceLock::new();

pub(crate) fn set_backend(b: Backend) -> Result<(), ()> {
    BACKEND.set(b).map_err(|_| ())
}

pub(crate) fn try_backend() -> Option<&'static Backend> {
    BACKEND.get()
}

pub(crate) fn trim_history_memory(
    hist: &mut Vec<ClipboardEntry>,
    threshold: usize,
    favorites: &HashSet<u64>,
) {
    let cleanable = hist
        .iter()
        .filter(|e| !favorites.contains(&e.entry_id()))
        .count();
    if cleanable <= threshold {
        return;
    }
    let mut excess = cleanable - threshold;
    let mut doomed: HashSet<u64> = HashSet::with_capacity(excess);
    for entry in hist.iter().rev() {
        if excess == 0 {
            break;
        }
        if !favorites.contains(&entry.entry_id()) {
            doomed.insert(entry.entry_id());
            excess -= 1;
        }
    }
    hist.retain(|e| !doomed.contains(&e.entry_id()));
}

pub(crate) fn reload_history_from_db(b: &Backend) -> usize {
    let conn = b.db.lock().unwrap();
    let threshold = b.cleanup_threshold.load(std::sync::atomic::Ordering::Relaxed);
    let loaded = crate::db::load_history_from_db(&conn, threshold);
    drop(conn);

    let mut hist = b.history.lock().unwrap();
    {
        let favorites = b.favorites.lock().unwrap();
        *hist = loaded;
        trim_history_memory(&mut hist, threshold, &favorites);
    }
    let count = hist.len();
    mark_history_changed();

    count
}

#[cfg(test)]
mod history_event_tests {
    use super::*;

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
