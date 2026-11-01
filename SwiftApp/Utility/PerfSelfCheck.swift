import Foundation

enum PerfSelfCheck {
    private static let maxClockSkewNs: UInt64 = 2_000_000

    @discardableResult
    static func run() -> Bool {
        let swiftMask = Perf.selfCheck()
        let rustMask = clipboard_perf_selfcheck()

        let token = "tok-\(ProcessInfo.processInfo.processIdentifier)-\(Perf.nowNs())"

        let swiftStamp = Perf.nowNs()
        Perf.emitProbe("swift_probe", data: token)
        let rustStamp = token.withCString { clipboard_perf_emit_probe($0) }
        let clockOK = rustStamp > 0 && rustStamp >= swiftStamp
            && (rustStamp - swiftStamp) <= maxClockSkewNs
        let skewUs = rustStamp > swiftStamp ? (rustStamp - swiftStamp) / 1_000 : 0

        let text = (try? String(contentsOfFile: Perf.observationLogPath,
                                encoding: .utf8)) ?? ""
        let safe = Perf.sanitize(token)
        let swiftSeen = text.contains("name=swift_probe data=\(safe)")
        let rustSeen = text.contains("name=rust_probe data=\(safe)")

        let swiftOK = swiftMask == 15
        let rustOK = rustMask == 7
        let channelOK = swiftSeen && rustSeen

        var sink = 0
        let fmtStart = Perf.nowNs()
        for _ in 0..<1_000 {
            sink &+= Perf.format(kind: "e", cat: "swift", name: "x", t: fmtStart, wall: 0,
                                 durUs: 1, src: nil, scen: nil, data: nil, val: nil).utf8.count
        }
        let fmtNs = (Perf.nowNs() - fmtStart) / 1_000
        Perf.emitUnconditional("perfcheck", "format_cost_ns", Int64(fmtNs),
                               data: "sink\(sink)")

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
