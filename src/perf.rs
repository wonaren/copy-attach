use std::io::Write;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub(crate) const PERF_VERSION: u32 = 1;

pub(crate) const PERF_MAGIC: &str = "__CA_PERF__";

const PERF_LOG_PATH: &str = "/tmp/copyattach_debug.log";

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

#[cfg(target_os = "macos")]
#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

fn thread_id() -> u64 {
    #[cfg(target_os = "macos")]
    let id = unsafe { pthread_self() } as u64;
    #[cfg(not(target_os = "macos"))]
    let id = 0u64;
    id
}

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
        ((ticks * numer as u128) / denom as u128) as u64
    }
    #[cfg(not(target_os = "macos"))]
    {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_nanos() as u64
    }
}

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

pub(crate) fn set_perf_enabled(state: i32) {
    let encoded = match state {
        1 => STATE_ON,
        0 => STATE_OFF,
        _ => STATE_UNDECIDED,
    };
    ENABLED.store(encoded, Ordering::Relaxed);
}

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

fn emit(line: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(PERF_LOG_PATH)
    {
        let mut buf = String::with_capacity(line.len() + 1);
        buf.push_str(line);
        buf.push('\n');
        let _ = f.write_all(buf.as_bytes());
    }
}

pub(crate) fn emit_probe(cat: &str, name: &str, data: &str) -> u64 {
    let t = perf_now_ns();
    let line = format_record("i", cat, name, t, wall_ms(), None, None, None, Some(data), None);
    emit(&line);
    t
}

pub(crate) struct PerfSpan {
    cat: &'static str,
    name: &'static str,
    t0: u64,
    wall0: u64,
    src: Option<&'static str>,
    scen: Option<&'static str>,
    pub(crate) val: Option<i64>,
    pub(crate) data: Option<String>,
}

impl PerfSpan {
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

    #[inline]
    pub(crate) fn start_with(
        cat: &'static str,
        name: &'static str,
        src: Option<&'static str>,
        scen: Option<&'static str>,
    ) -> Option<PerfSpan> {
        PerfSpan::start(cat, name).map(|s| s.with_context(src, scen))
    }

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

#[allow(dead_code)]
pub(crate) fn perf_instant(cat: &'static str, name: &'static str, data: Option<&str>) {
    if !perf_enabled() {
        return;
    }
    let t = perf_now_ns();
    let line = format_record("i", cat, name, t, wall_ms(), None, None, None, data, None);
    emit(&line);
}

#[allow(dead_code)]
pub(crate) fn perf_counter(cat: &'static str, name: &'static str, value: i64) {
    if !perf_enabled() {
        return;
    }
    let t = perf_now_ns();
    let line = format_record("c", cat, name, t, wall_ms(), None, None, None, None, Some(value));
    emit(&line);
}

#[no_mangle]
pub extern "C" fn clipboard_set_perf_enabled(state: i32) -> i32 {
    set_perf_enabled(state);
    if perf_enabled() { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn clipboard_perf_enabled() -> i32 {
    if perf_enabled() { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn clipboard_perf_emit_probe(token: *const std::ffi::c_char) -> u64 {
    if token.is_null() {
        return 0;
    }
    let raw = unsafe { std::ffi::CStr::from_ptr(token) };
    let token = raw.to_string_lossy();
    emit_probe("probe", "rust_probe", &token)
}

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
        assert_eq!(clipboard_perf_selfcheck(), 7);
    }

    #[test]
    fn test_span_is_none_when_disabled() {
        set_perf_enabled(0);
        assert!(PerfSpan::start("rust", "disabled").is_none());
        set_perf_enabled(-1);
    }
}
