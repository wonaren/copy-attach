import Foundation
import Darwin
import Synchronization

/// Opt-in performance tracing (the "instrument"), Swift half.
///
/// Shares the wire format and the observation channel with the Rust half
/// (`src/perf.rs`): one line per record, prefixed with `__CA_PERF__`, appended
/// to the same debug log. Both languages stamp a monotonic clock
/// (`DispatchTime.uptimeNanoseconds` here, `Instant` in Rust) and a stable
/// per-thread id (`pthread_self()`) so records can be ordered and correlated
/// across the FFI boundary.
///
/// Design constraints, all load-bearing:
/// * **Off by default, and effectively inert when off.** `Perf.isEnabled` is an
///   atomic check before any work; the disabled path allocates nothing and
///   writes nothing.
/// * **The instrument must not change what it measures.** Tracing only appends
///   to the existing log; it never blocks, retains, or reorders UI work.
/// * **No clipboard content in the trace.** Context values are numeric or
///   sanitized short tokens only.
/// * **Records are self-describing.** Category, name, and the optional
///   source/scenario ids let the analyzer reconstruct a latency chain without
///   reading source.
///
/// Enable by setting the `PerfTracing` user default to true (the app is a
/// bundled agent launched by `open`, which does not inherit the shell
/// environment), or by exporting `COPYATTACH_PERF=1` when running the binary
/// directly.
enum Perf {
    /// Magic token every machine-readable line starts with. Byte-identical to
    /// `crate::perf::PERF_MAGIC`.
    static let magic = "__CA_PERF__"
    static let version = 1

    private static let logPath = "/tmp/copyattach_debug.log"
    private static let logURL = URL(fileURLWithPath: logPath)

    /// Enabled flag. An `Atomic` (not a mutable `static var`) so the check is
    /// race-free and legal under Swift 6 strict concurrency.
    private static let enabledFlag = Atomic<UInt8>(0)

    private static func resolveEnabled() -> Bool {
        if let explicit = UserDefaults.standard.object(forKey: "PerfTracing") as? Bool {
            return explicit
        }
        let env = ProcessInfo.processInfo.environment["COPYATTACH_PERF"]
        return env == "1" || env == "true" || env == "YES"
    }

    /// Resolve the enabled state from the preference/environment. Idempotent;
    /// safe to call once at startup and again after a preference change.
    @discardableResult
    static func refreshEnabled() -> Bool {
        let on = resolveEnabled()
        enabledFlag.store(on ? 1 : 0, ordering: .relaxed)
        return on
    }

    /// Read without doing any preference IO.
    @inline(__always)
    static var isEnabled: Bool { enabledFlag.load(ordering: .relaxed) == 1 }

    /// Resolve the enabled state and mirror it to the Rust side, so both halves
    /// of the instrument agree. Must run before any measured path.
    @discardableResult
    static func bootstrap() -> Bool {
        let on = refreshEnabled()
        _ = clipboard_set_perf_enabled(on ? 1 : 0)
        return on
    }

    /// `pthread_self()` is stable for a thread and identical in form to the Rust
    /// side id, so a Swift span and a Rust span on the same thread sort into one
    /// order.
    static var threadId: UInt64 { UInt64(UInt(bitPattern: pthread_self())) }

    /// Monotonic nanoseconds. `DispatchTime` is uptime-based and never jumps.
    @inline(__always)
    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func nowUs() -> UInt64 { nowNs() / 1_000 }

    private static func wallMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Sanitize a string for use as a `data=` token: keep `[A-Za-z0-9._-]`,
    /// replace everything else with `_`, cap at 48 bytes. Mirrors
    /// `perf::sanitize_token` so both languages produce the same shape.
    static func sanitize(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(min(raw.utf8.count, 48))
        for ch in raw.unicodeScalars {
            if out.utf8.count >= 48 { break }
            let v = ch.value
            let isSafe = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                || (v >= 0x30 && v <= 0x39) || v == 0x2E || v == 0x5F || v == 0x2D
            out.unicodeScalars.append(isSafe ? ch : Unicode.Scalar(0x5F)!)
        }
        return out.isEmpty ? "-" : out
    }

    /// Render one record. Pure so the self-check can assert its shape.
    @inline(__always)
    static func format(kind: String, cat: String, name: String, t: UInt64,
                       durUs: UInt64?, src: String?, scen: String?,
                       data: String?, val: Int64?) -> String {
        var s = magic
        s += " v=\(version) pid=\(ProcessInfo.processInfo.processIdentifier)"
        s += " tid=\(String(threadId, radix: 16))"
        s += " t=\(t) wall=\(wallMs())"
        s += " kind=\(kind) cat=\(cat) name=\(name)"
        if let durUs { s += " dur_us=\(durUs)" }
        if let val { s += " val=\(val)" }
        if let src { s += " src=\(src)" }
        if let scen { s += " scen=\(scen)" }
        if let data { s += " data=\(sanitize(data))" }
        return s
    }

    /// Append a raw line to the shared log. Same open/append/close pattern as
    /// `debugLog`, so tracing never depends on the stderr redirect.
    private static func appendLine(_ line: String) {
        let payload = line + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = payload.data(using: .utf8) { try? handle.write(contentsOf: data) }
        } else {
            try? payload.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Append a gated record.
    static func emit(_ line: String) {
        guard isEnabled else { return }
        appendLine(line)
    }

    /// Append a probe record regardless of the enabled gate. The self-check
    /// uses this to prove the observation channel itself works even when
    /// tracing is otherwise off (the "validate the instrument" requirement).
    static func emitProbe(_ name: String, data: String) {
        appendLine(format(kind: "i", cat: "probe", name: name, t: nowNs(),
                          durUs: nil, src: nil, scen: nil, data: data, val: nil))
    }

    /// Append a counter record regardless of the enabled gate. Reserved for
    /// the self-check verdict, which must be observable even when a
    /// misconfiguration left tracing off.
    static func emitUnconditional(_ cat: String, _ name: String, _ value: Int64,
                                  data: String? = nil) {
        appendLine(format(kind: "c", cat: cat, name: name, t: nowNs(),
                          durUs: nil, src: nil, scen: nil, data: data, val: value))
    }

    /// Absolute path of the shared observation channel, for the self-check's
    /// read-back.
    static var observationLogPath: String { logPath }

    /// Instantaneous marker.
    @inline(__always)
    static func instant(_ cat: String, _ name: String, data: String? = nil) {
        guard isEnabled else { return }
        emit(format(kind: "i", cat: cat, name: name, t: nowNs(),
                    durUs: nil, src: nil, scen: nil, data: data, val: nil))
    }

    /// Counter sample.
    @inline(__always)
    static func counter(_ cat: String, _ name: String, _ value: Int64) {
        guard isEnabled else { return }
        emit(format(kind: "c", cat: cat, name: name, t: nowNs(),
                    durUs: nil, src: nil, scen: nil, data: nil, val: value))
    }

    /// Measure the per-call cost of the DISABLED hot path (one atomic load plus
    /// a nil return). Temporarily clears the flag, times plain PerfSpan.start
    /// calls, and restores it. This is what turns "inert when off" from an
    /// assertion into a number.
    static func measureDisabledStartCostNs(iterations: Int) -> Int64 {
        let saved = enabledFlag.load(ordering: .relaxed)
        enabledFlag.store(0, ordering: .relaxed)
        defer { enabledFlag.store(saved, ordering: .relaxed) }

        var sink = 0
        let t0 = nowNs()
        for i in 0..<iterations {
            if PerfSpan.start("swift", "disabled") != nil {
                sink &+= i
            } else {
                sink &+= 1
            }
        }
        let dt = nowNs() - t0
        _ = sink
        return Int64(dt / UInt64(max(iterations, 1)))
    }

    /// Self-check of the Swift-side instrument primitives. Returns a bitmask:
    /// bit 0 - the monotonic clock advances;
    /// bit 1 - `format` produces a well-formed single line;
    /// bit 2 - the sanitizer strips separators;
    /// bit 3 - the sanitizer caps at 48 bytes.
    /// 15 == all pass. The observation half (does a record actually land in the
    /// file) is proven separately by the probe round-trip in `PerfSelfCheck`.
    static func selfCheck() -> Int32 {
        var mask: Int32 = 0
        let t0 = nowNs()
        usleep(250)
        let t1 = nowNs()
        if t1 > t0 { mask |= 1 }

        let rec = format(kind: "e", cat: "swift", name: "selfcheck", t: t0,
                         durUs: (t1 - t0) / 1_000, src: nil, scen: nil,
                         data: nil, val: nil)
        if rec.hasPrefix(magic), !rec.contains("\n"), rec.contains(" cat=swift"),
           rec.contains(" name=selfcheck"), rec.contains(" dur_us=") {
            mask |= 2
        }

        let clean = sanitize("a b\tc\nd=%")
        if !clean.contains(" "), !clean.contains("\t"), !clean.contains("\n"),
           !clean.contains("="), !clean.isEmpty {
            mask |= 4
        }
        if sanitize(String(repeating: "x", count: 200)).utf8.count == 48 { mask |= 8 }

        return mask
    }
}

/// A completed span. Created only while tracing is enabled, so the disabled
/// path is one atomic load plus a nil optional.
///
/// end() is explicit and idempotent, and deinit also ends an un-ended span, so
/// an early return can never silently drop a duration.
///
/// @unchecked Sendable: a span is created and ended by one sequential flow, but
/// that flow may hop isolation domains (Task, DispatchQueue). No span is ever
/// touched by two threads concurrently, so capturing it across a hop is safe;
/// the annotation is what lets Swift 6 accept Task captures.
final class PerfSpan: @unchecked Sendable {
    private let cat: String
    private let name: String
    private let t0: UInt64
    private var src: String?
    private var scen: String?
    private var ended = false
    /// Optional value attached at end (e.g. result count).
    var val: Int64?
    /// Optional sanitized context token attached at end.
    var data: String?

    private init(cat: String, name: String) {
        self.cat = cat
        self.name = name
        self.t0 = Perf.nowNs()
    }

    /// Begin a span, or nil when tracing is off.
    static func start(_ cat: String, _ name: String) -> PerfSpan? {
        guard Perf.isEnabled else { return nil }
        return PerfSpan(cat: cat, name: name)
    }

    /// Begin a span carrying its correlation context (source id, scenario id).
    static func start(_ cat: String, _ name: String, src: String?, scen: String?) -> PerfSpan? {
        guard let span = start(cat, name) else { return nil }
        span.src = src
        span.scen = scen
        return span
    }

    func end() {
        guard !ended else { return }
        ended = true
        let t1 = Perf.nowNs()
        let dur = t1 >= t0 ? (t1 - t0) / 1_000 : 0
        Perf.emit(Perf.format(kind: "e", cat: cat, name: name, t: t0, durUs: dur,
                              src: src, scen: scen, data: data, val: val))
    }

    deinit { if !ended { end() } }
}
