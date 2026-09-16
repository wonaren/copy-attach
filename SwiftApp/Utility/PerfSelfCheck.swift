import Foundation

/// Validates the instrument itself before any measurement is trusted.
///
/// A measurement system is only useful if it is shown to work. This runs four
/// independent checks and records a single verdict:
///
/// 1. **Swift primitives** - monotonic clock advances, the record formatter
///    emits a well-formed single line, the sanitizer strips separators and caps
///    length (Perf.selfCheck() == 15).
/// 2. **Rust primitives** - same three properties on the Rust side
///    (clipboard_perf_selfcheck() == 7).
/// 3. **The observation channel** - a token is written by Swift and by Rust,
///    then read back from the shared log file. This proves the write -> file ->
///    read chain on both sides of the FFI boundary; a formatter that looks
///    correct but never reaches the file would be caught here.
/// 4. **Cross-language clock alignment** - a Swift stamp and the immediately
///    following Rust stamp must be close and ordered. The two halves run on the
///    *same* monotonic clock (mach_absolute_time), so a difference of more than
///    a few milliseconds means the clocks, or the code that stamps them,
///    diverged - in which case every cross-boundary chain would be meaningless.
///    Measured: typically tens of microseconds.
///
/// The verdict is recorded in the trace (cat=perfcheck name=verdict) and
/// mirrored into UserDefaults["PerfSelfCheckVerdict"] so a launch that cannot be
/// watched interactively still leaves evidence.
enum PerfSelfCheck {
    /// Maximum tolerated Swift->Rust stamp skew, in NANOSECONDS (the unit of
    /// the underlying stamps). Generous: this catches clock-domain divergence,
    /// not normal scheduling jitter. Measured skew is tens of microseconds.
    private static let maxClockSkewNs: UInt64 = 2_000_000

    /// Run all checks. Returns true only when every check passes.
    @discardableResult
    static func run() -> Bool {
        let swiftMask = Perf.selfCheck()
        let rustMask = clipboard_perf_selfcheck()

        // Observation round-trip. The token is unique per run so a stale line
        // from a previous session cannot satisfy the check.
        let token = "tok-\(ProcessInfo.processInfo.processIdentifier)-\(Perf.nowNs())"

        // Clock alignment: stamp on both sides back-to-back. Swift first, then
        // Rust, so a shared clock implies rustStamp >= swiftStamp.
        let swiftStamp = Perf.nowNs()
        Perf.emitProbe("swift_probe", data: token)
        let rustStamp = token.withCString { clipboard_perf_emit_probe($0) }
        let clockOK = rustStamp > 0 && rustStamp >= swiftStamp
            && (rustStamp - swiftStamp) <= maxClockSkewNs
        let skewUs = rustStamp > swiftStamp ? (rustStamp - swiftStamp) / 1_000 : 0

        // Read the channel back. The FileHandle writes above are flushed on
        // close; reading whole-file is fine at this volume.
        let text = (try? String(contentsOfFile: Perf.observationLogPath,
                                encoding: .utf8)) ?? ""
        let safe = Perf.sanitize(token)
        let swiftSeen = text.contains("name=swift_probe data=\(safe)")
        let rustSeen = text.contains("name=rust_probe data=\(safe)")

        let swiftOK = swiftMask == 15
        let rustOK = rustMask == 7
        let channelOK = swiftSeen && rustSeen

        // Overhead of the enabled hot path's CPU half: the record formatting.
        // The IO half is one file append per completed span. Measured here with
        // the file write excluded so the number is the instrument's own cost,
        // not the log device's. 1000 iterations, reported as ns/record.
        var sink = 0
        let fmtStart = Perf.nowNs()
        for _ in 0..<1_000 {
            sink &+= Perf.format(kind: "e", cat: "swift", name: "x", t: fmtStart, wall: 0,
                                 durUs: 1, src: nil, scen: nil, data: nil, val: nil).utf8.count
        }
        let fmtNs = (Perf.nowNs() - fmtStart) / 1_000
        Perf.emitUnconditional("perfcheck", "format_cost_ns", Int64(fmtNs),
                               data: "sink\(sink)")

        // Cost of the disabled path, measured rather than assumed.
        let disabledNs = Perf.measureDisabledStartCostNs(iterations: 1_000_000)
        Perf.emitUnconditional("perfcheck", "disabled_start_cost_ns", disabledNs)

        let ok = swiftOK && rustOK && channelOK && clockOK
        UserDefaults.standard.set(ok, forKey: "PerfSelfCheckVerdict")
        Perf.emitUnconditional(
            "perfcheck", "verdict", ok ? 1 : 0,
            data: "swift\(swiftMask)_rust\(rustMask)_seen\(swiftSeen ? 1 : 0)\(rustSeen ? 1 : 0)_clk\(clockOK ? 1 : 0)_skew\(skewUs)us"
        )
        return ok
    }
}
