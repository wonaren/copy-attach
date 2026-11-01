import Foundation
import Darwin
import Synchronization

enum Perf {
    static let magic = "__CA_PERF__"
    static let version = 1

    private static let logPath = "/tmp/copyattach_debug.log"
    private static let logURL = URL(fileURLWithPath: logPath)

    private static let enabledFlag = Atomic<UInt8>(0)

    private static func resolveEnabled() -> Bool {
        if let explicit = UserDefaults.standard.object(forKey: "PerfTracing") as? Bool {
            return explicit
        }
        let env = ProcessInfo.processInfo.environment["COPYATTACH_PERF"]
        return env == "1" || env == "true" || env == "YES"
    }

    @discardableResult
    static func refreshEnabled() -> Bool {
        let on = resolveEnabled()
        enabledFlag.store(on ? 1 : 0, ordering: .relaxed)
        return on
    }

    @inline(__always)
    static var isEnabled: Bool { enabledFlag.load(ordering: .relaxed) == 1 }

    @discardableResult
    static func bootstrap() -> Bool {
        let on = refreshEnabled()
        _ = clipboard_set_perf_enabled(on ? 1 : 0)
        return on
    }

    static var threadId: UInt64 { UInt64(UInt(bitPattern: pthread_self())) }

    @inline(__always)
    static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func nowUs() -> UInt64 { nowNs() / 1_000 }

    private static func wallMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

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

    @inline(__always)
    static func format(kind: String, cat: String, name: String, t: UInt64,
                       wall: UInt64, durUs: UInt64?, src: String?, scen: String?,
                       data: String?, val: Int64?) -> String {
        var s = magic
        s += " v=\(version) pid=\(ProcessInfo.processInfo.processIdentifier)"
        s += " tid=\(String(threadId, radix: 16))"
        s += " t=\(t) wall=\(wall)"
        s += " kind=\(kind) cat=\(cat) name=\(name)"
        if let durUs { s += " dur_us=\(durUs)" }
        if let val { s += " val=\(val)" }
        if let src { s += " src=\(src)" }
        if let scen { s += " scen=\(scen)" }
        if let data { s += " data=\(sanitize(data))" }
        return s
    }

    private static func appendLine(_ line: String) {
        let payload = Array((line + "\n").utf8)
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        payload.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { break }
                remaining -= n
                ptr += n
            }
        }
    }

    static func emit(_ line: String) {
        guard isEnabled else { return }
        appendLine(line)
    }

    static func emitProbe(_ name: String, data: String) {
        appendLine(format(kind: "i", cat: "probe", name: name, t: nowNs(), wall: wallMs(),
                          durUs: nil, src: nil, scen: nil, data: data, val: nil))
    }

    static func emitUnconditional(_ cat: String, _ name: String, _ value: Int64,
                                  data: String? = nil) {
        appendLine(format(kind: "c", cat: cat, name: name, t: nowNs(), wall: wallMs(),
                          durUs: nil, src: nil, scen: nil, data: data, val: value))
    }

    static var observationLogPath: String { logPath }

    static func emitSpan(_ cat: String, _ name: String, durNs: UInt64,
                         val: Int64? = nil, data: String? = nil) {
        guard isEnabled else { return }
        let t0 = nowNs() &- durNs
        emit(format(kind: "e", cat: cat, name: name, t: t0, wall: wallMs(), durUs: durNs / 1_000,
                    src: nil, scen: nil, data: data, val: val))
    }

    @inline(__always)
    static func instant(_ cat: String, _ name: String, data: String? = nil) {
        guard isEnabled else { return }
        emit(format(kind: "i", cat: cat, name: name, t: nowNs(), wall: wallMs(),
                    durUs: nil, src: nil, scen: nil, data: data, val: nil))
    }

    @inline(__always)
    static func counter(_ cat: String, _ name: String, _ value: Int64) {
        guard isEnabled else { return }
        emit(format(kind: "c", cat: cat, name: name, t: nowNs(), wall: wallMs(),
                    durUs: nil, src: nil, scen: nil, data: nil, val: value))
    }

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

    static func selfCheck() -> Int32 {
        var mask: Int32 = 0
        let t0 = nowNs()
        usleep(250)
        let t1 = nowNs()
        if t1 > t0 { mask |= 1 }

        let rec = format(kind: "e", cat: "swift", name: "selfcheck", t: t0, wall: wallMs(),
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

final class PerfSpan: @unchecked Sendable {
    private let cat: String
    private let name: String
    private let t0: UInt64
    private let wall0: UInt64
    private var src: String?
    private var scen: String?
    private var ended = false
    var val: Int64?
    var data: String?

    private init(cat: String, name: String) {
        self.cat = cat
        self.name = name
        self.t0 = Perf.nowNs()
        self.wall0 = UInt64(Date().timeIntervalSince1970 * 1000)
    }

    static func start(_ cat: String, _ name: String) -> PerfSpan? {
        guard Perf.isEnabled else { return nil }
        return PerfSpan(cat: cat, name: name)
    }

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
        Perf.emit(Perf.format(kind: "e", cat: cat, name: name, t: t0, wall: wall0,
                              durUs: dur, src: src, scen: scen, data: data, val: val))
    }

    deinit { if !ended { end() } }
}
