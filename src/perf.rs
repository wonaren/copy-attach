//! Opt-in performance tracing (the "instrument").
//!
//! This module is the Rust half of CopyAttach's latency measurement system. It
//! is deliberately tiny and self-contained:
//!
//! * **Off by default, zero behavioural change when off.** Every entry point
//!   short-circuits on one relaxed atomic load. Nothing else in the backend
//!   reads this module's state, so tracing cannot alter a measured path.
//! * **One observation channel.** Records are appended to the *same* debug log
//!   the app already writes (/tmp/copyattach_debug.log) as single lines that
//!   begin with the magic token __CA_PERF__. The collector greps for that
//!   token, so it never has to care about the surrounding diagnostic noise.
//! * **Self-describing records.** Every line carries pid, a stable per-thread
//!   id (the raw pthread_self() value, shared with Swift so both languages can
//!   be correlated), a monotonic clock reading in ns, wall-clock ms, a
//!   category/name, and -- for completed spans -- a duration in microseconds.
//!
//! Wire format (one line per record; keys are space separated; later keys
//! optional):
//!
//!   __CA_PERF__ v=1 pid=<u32> tid=<hex> t=<mono_ns> wall=<unix_ms> kind=<b|e|i|c> cat=<cat> name=<name> [dur_us=<u64>] [src=<id>] [scen=<id>] [val=<i64>] [data=<token>]
//!
//! Clock note: t is Instant-based (monotonic, process-relative). It is safe for
//! *durations* but not absolute time; wall carries absolute time for
//! cross-correlating with the human log. The analyzer only subtracts t values
//! that share a pid, which is exactly the Instant guarantee.
//!
//! Enable with the COPYATTACH_PERF=1 environment variable (direct execution) or
//! the PerfTracing user default (works through open, which does not inherit the
//! shell environment), or the clipboard_set_perf_enabled FFI.

use std::io::Write;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Record format version. Bump only for an incompatible field change; the
/// analyzer rejects unknown versions rather than mis-parsing them.
pub(crate) const PERF_VERSION: u32 = 1;

/// Magic token every machine-readable line starts with.
pub(crate) const PERF_MAGIC: &str = "__CA_PERF__";

const PERF_LOG_PATH: &str = "/tmp/copyattach_debug.log";

// Enabled state: 0 = undecided (fall back to env), 1 = on, 2 = off.
const STATE_UNDECIDED: u8 = 0;
const STATE_ON: u8 = 1;
const STATE_OFF: u8 = 2;
static ENABLED: AtomicU8 = AtomicU8::new(STATE_UNDECIDED);

#[cfg(target_os = "macos")]
extern "C" {
    fn pthread_self() -> usize;
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebase) -> i32;
}

/// mach_timebase_info_data_t -- ticks-to-nanoseconds ratio.
#[cfg(target_os = "macos")]
#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

/// Stable per-thread id shared with Swift (both report pthread_self()). Zero on
/// non-macOS, where tracing is not exercised.
fn thread_id() -> u64 {
    #[cfg(target_os = "macos")]
    let id = unsafe { pthread_self() } as u64;
    #[cfg(not(target_os = "macos"))]
    let id = 0u64;
    id
}

/// Monotonic nanoseconds on the SAME clock Swift uses.
///
/// Swift stamps DispatchTime.now().uptimeNanoseconds, which is mach_absolute_time
/// converted to nanoseconds. Rust Instant is also mach_absolute_time-backed but
/// elapsed() is process-relative, so the two would have different origins and
/// any cross-language duration would be meaningless. Reading mach_absolute_time
/// directly gives both languages one origin, which is what makes cross-boundary
/// chains (Rust capture -> Swift UI observe) measurable. Non-macOS falls back to
/// a process-relative clock.
pub(crate) fn perf_now_ns() -> u64 {
    #[cfg(target_os = "macos")]
    {
        static TIMEBASE: std::sync::OnceLock<(u32, u32)> = std::sync::OnceLock::new();
        let (numer, denom) = *TIMEBASE.get_or_init(|| {
            let mut tb = MachTimebase { numer: 1, denom: 1 };
            let rc = unsafe { mach_timebase_info(&mut tb) };
            if rc == 0 && tb.denom != 0 {
                (tb.numer, tb.denom)
            } else {
                (1, 1)
            }
        });
        let ticks = unsafe { mach_absolute_time() } as u128;
        // u128 avoids overflow: ticks * numer can exceed u64.
        ((ticks * numer as u128) / denom as u128) as u64
    }
    #[cfg(not(target_os = "macos"))]
    {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_nanos() as u64
    }
}

/// Whether tracing is currently enabled. Resolves the env default once.
pub(crate) fn perf_enabled() -> bool {
    match ENABLED.load(Ordering::Relaxed) {
        STATE_ON => true,
        STATE_OFF => false,
        _ => {
            let on = matches!(
                std::env::var("COPYATTACH_PERF").ok().as_deref(),
                Some("1") | Some("true") | Some("YES")
            );
            ENABLED.store(if on { STATE_ON } else { STATE_OFF }, Ordering::Relaxed);
            on
        }
    }
}

/// Runtime override driven from Swift. 1 on, 0 off, anything else returns to the
/// environment default.
pub(crate) fn set_perf_enabled(state: i32) {
    let encoded = match state {
        1 => STATE_ON,
        0 => STATE_OFF,
        _ => STATE_UNDECIDED,
    };
    ENABLED.store(encoded, Ordering::Relaxed);
}

/// Sanitize an arbitrary string into a single whitespace-free token. Keeps
/// [A-Za-z0-9._-]; everything else becomes '_'; capped at 48 bytes. This is what
/// keeps a record parseable and also prevents clipboard text from leaking into
/// the trace.
pub(crate) fn sanitize_token(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(48));
    for ch in raw.chars() {
        if out.len() >= 48 {
            break;
        }
        if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('-');
    }
    out
}

pub(crate) fn wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Render one record. Pure (no IO) so it can be unit-tested and so the emit
/// path is just "push a line".
#[allow(clippy::too_many_arguments)]
pub(crate) fn format_record(
    kind: &str,
    cat: &str,
    name: &str,
    t_ns: u64,
    wall: u64,
    dur_us: Option<u64>,
    src: Option<&str>,
    scen: Option<&str>,
    data: Option<&str>,
    val: Option<i64>,
) -> String {
    let mut s = String::with_capacity(192);
    s.push_str(PERF_MAGIC);
    s.push_str(" v=");
    s.push_str(&PERF_VERSION.to_string());
    s.push_str(" pid=");
    s.push_str(&std::process::id().to_string());
    s.push_str(" tid=");
    s.push_str(&format!("{:x}", thread_id()));
    s.push_str(" t=");
    s.push_str(&t_ns.to_string());
    s.push_str(" wall=");
    s.push_str(&wall.to_string());
    s.push_str(" kind=");
    s.push_str(kind);
    s.push_str(" cat=");
    s.push_str(cat);
    s.push_str(" name=");
    s.push_str(name);
    if let Some(d) = dur_us {
        s.push_str(" dur_us=");
        s.push_str(&d.to_string());
    }
    if let Some(v) = val {
        s.push_str(" val=");
        s.push_str(&v.to_string());
    }
    if let Some(x) = src {
        s.push_str(" src=");
        s.push_str(x);
    }
    if let Some(x) = scen {
        s.push_str(" scen=");
        s.push_str(x);
    }
    if let Some(x) = data {
        s.push_str(" data=");
        s.push_str(&sanitize_token(x));
    }
    s
}

/// Append a record to the shared debug log. Open/append/close per record keeps
/// this independent of the app's stderr redirect and of any long-lived handle;
/// tracing volume is bounded by design (only user-issued actions are traced),
/// so this is not a hot allocation path.
fn emit(line: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(PERF_LOG_PATH)
    {
        // ONE write for the whole record including its newline. Writing the
        // line and the newline separately let another thread append in between,
        // producing a line that looks like
        //   "...data=text__CA_PERF__ v=1 pid=..." 
        // i.e. a record with no newline glued to the next record. Because the
        // fd is O_APPEND, a single write is placed atomically at end-of-file.
        let mut buf = String::with_capacity(line.len() + 1);
        buf.push_str(line);
        buf.push('\n');
        let _ = f.write_all(buf.as_bytes());
    }
}

/// Write a probe record unconditionally (used by the self-check probes; ignores
/// the enabled gate so the observation channel can be proven while tracing is
/// off).
pub(crate) fn emit_probe(cat: &str, name: &str, data: &str) -> u64 {
    let t = perf_now_ns();
    let line = format_record("i", cat, name, t, wall_ms(), None, None, None, Some(data), None);
    emit(&line);
    t
}

/// A completed span. Created by PerfSpan::start only when tracing is on, so the
/// disabled path is a single atomic load plus an Option::None.
pub(crate) struct PerfSpan {
    cat: &'static str,
    name: &'static str,
    t0: u64,
    /// Wall clock at span START, so wall and t describe the same instant.
    /// Stamping wall at format time made them differ by the span duration,
    /// which broke wall<->monotonic correlation (caught by gate G4).
    wall0: u64,
    src: Option<&'static str>,
    scen: Option<&'static str>,
    /// Value attached at any point before the span ends (e.g. result count).
    /// Callers may write it directly once the value is known.
    pub(crate) val: Option<i64>,
    /// Sanitized context token attached before the span ends.
    pub(crate) data: Option<String>,
}

impl PerfSpan {
    /// Begin a span. Returns None when tracing is off -- callers hold an
    /// Option<PerfSpan> and simply drop it to finish.
    #[inline]
    pub(crate) fn start(cat: &'static str, name: &'static str) -> Option<PerfSpan> {
        if !perf_enabled() {
            return None;
        }
        Some(PerfSpan {
            cat,
            name,
            t0: perf_now_ns(),
            wall0: wall_ms(),
            src: None,
            scen: None,
            val: None,
            data: None,
        })
    }

    /// Begin a span and attach its context in one call.
    #[inline]
    pub(crate) fn start_with(
        cat: &'static str,
        name: &'static str,
        src: Option<&'static str>,
        scen: Option<&'static str>,
    ) -> Option<PerfSpan> {
        PerfSpan::start(cat, name).map(|s| s.with_context(src, scen))
    }

    /// Attach context to the eventual end record.
    #[allow(dead_code)]
    pub(crate) fn with_context(mut self, src: Option<&'static str>, scen: Option<&'static str>) -> Self {
        self.src = src;
        self.scen = scen;
        self
    }
}

impl Drop for PerfSpan {
    fn drop(&mut self) {
        let t1 = perf_now_ns();
        let dur_us = t1.saturating_sub(self.t0) / 1_000;
        let line = format_record(
            "e",
            self.cat,
            self.name,
            self.t0,
            self.wall0,
            Some(dur_us),
            self.src,
            self.scen,
            self.data.as_deref(),
            self.val,
        );
        emit(&line);
    }
}

/// Record an instantaneous marker (a moment in a path that is not a duration).
#[allow(dead_code)]
pub(crate) fn perf_instant(cat: &'static str, name: &'static str, data: Option<&str>) {
    if !perf_enabled() {
        return;
    }
    let t = perf_now_ns();
    let line = format_record("i", cat, name, t, wall_ms(), None, None, None, data, None);
    emit(&line);
}

/// Record a counter sample (e.g. "history has N rows" at some moment).
#[allow(dead_code)]
pub(crate) fn perf_counter(cat: &'static str, name: &'static str, value: i64) {
    if !perf_enabled() {
        return;
    }
    let t = perf_now_ns();
    let line = format_record("c", cat, name, t, wall_ms(), None, None, None, None, Some(value));
    emit(&line);
}

// FFI control/observation surface.
//
// These three symbols are what Swift uses. They are intentionally trivial; the
// correctness they must guarantee (the record is visible in the shared file) is
// asserted by clipboard_perf_selfcheck plus the cross-language probe.

/// Runtime enable/disable. 1 on, 0 off, else environment default. Returns the
/// effective state after the call (1/0).
#[no_mangle]
pub extern "C" fn clipboard_set_perf_enabled(state: i32) -> i32 {
    set_perf_enabled(state);
    if perf_enabled() { 1 } else { 0 }
}

/// Current effective state (1/0).
#[no_mangle]
pub extern "C" fn clipboard_perf_enabled() -> i32 {
    if perf_enabled() { 1 } else { 0 }
}

/// Write a probe record carrying token and return the monotonic ns at which it
/// was stamped (0 on a null token). Used by the cross-language self-check to
/// prove the Rust -> file -> collector observation chain works.
#[no_mangle]
pub extern "C" fn clipboard_perf_emit_probe(token: *const std::ffi::c_char) -> u64 {
    if token.is_null() {
        return 0;
    }
    let raw = unsafe { std::ffi::CStr::from_ptr(token) };
    let token = raw.to_string_lossy();
    emit_probe("probe", "rust_probe", &token)
}

/// Self-check of the Rust-side primitives. Returns a bitmask:
/// bit 0 -- the monotonic clock advances;
/// bit 1 -- the formatter produces a well-formed single-line record;
/// bit 2 -- the sanitizer is whitespace-free.
/// A return value of 7 means all three passed. Swift folds this into its own
/// verdict; the *observation* half is proven separately by the probe.
#[no_mangle]
pub extern "C" fn clipboard_perf_selfcheck() -> i32 {
    let mut mask = 0i32;

    let t0 = perf_now_ns();
    let spin = Instant::now();
    while spin.elapsed().as_micros() < 250 {}
    let t1 = perf_now_ns();
    if t1 > t0 {
        mask |= 1;
    }

    let rec = format_record(
        "e",
        "rust",
        "selfcheck",
        t0,
        wall_ms(),
        Some(t1.saturating_sub(t0) / 1_000),
        None,
        None,
        None,
        None,
    );
    if rec.starts_with(PERF_MAGIC)
        && !rec.contains('\n')
        && rec.contains(" dur_us=")
        && rec.contains(" cat=rust")
        && rec.contains(" name=selfcheck")
    {
        mask |= 2;
    }

    let dirty = "a b\tc\nd=%";
    let clean = sanitize_token(dirty);
    if !clean.chars().any(|c| c.is_whitespace()) && !clean.is_empty() {
        mask |= 4;
    }

    mask
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_perf_now_ns_is_monotonic() {
        let a = perf_now_ns();
        let b = perf_now_ns();
        assert!(b >= a, "monotonic clock went backwards: {a} -> {b}");
    }

    #[test]
    fn test_format_record_is_single_wellformed_line() {
        let rec = format_record(
            "e", "swift", "popup.show", 123, 456, Some(45),
            Some("s1"), Some("popup_open"), Some("x"), None,
        );
        assert!(rec.starts_with(PERF_MAGIC));
        assert!(!rec.contains('\n'));
        assert!(rec.contains(" kind=e"));
        assert!(rec.contains(" cat=swift"));
        assert!(rec.contains(" name=popup.show"));
        assert!(rec.contains(" dur_us=45"));
        assert!(rec.contains(" src=s1"));
        assert!(rec.contains(" scen=popup_open"));
        assert!(rec.contains(&format!(" pid={}", std::process::id())));
    }

    #[test]
    fn test_sanitize_token_strips_whitespace_and_caps() {
        let clean = sanitize_token("hello world\tfoo=bar");
        assert!(!clean.chars().any(|c| c.is_whitespace()));
        assert!(!clean.contains('='));
        let long = sanitize_token(&"x".repeat(200));
        assert_eq!(long.len(), 48);
        assert_eq!(sanitize_token(""), "-");
    }

    #[test]
    fn test_selfcheck_all_primitives_pass() {
        // 7 == clock advances | record well-formed | token sanitized.
        assert_eq!(clipboard_perf_selfcheck(), 7);
    }

    #[test]
    fn test_span_is_none_when_disabled() {
        set_perf_enabled(0);
        assert!(PerfSpan::start("rust", "disabled").is_none());
        set_perf_enabled(-1); // back to env default
    }
}
