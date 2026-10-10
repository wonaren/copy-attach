import Foundation

private let debugLogPath = "/tmp/copyattach_debug.log"

private let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss +0800"
    f.timeZone = TimeZone(secondsFromGMT: 28800)
    return f
}()

func debugLog(_ message: String) {
    // Respect the same debug-logging switch as Rust: debug builds default on,
    // release/distribution builds default off, and the settings UI can enable
    // diagnostics explicitly. Prefer the persisted user preference so logs
    // emitted before `ClipboardBackend.start()` (startup diagnostics) honor
    // it too; fall back to Rust's current toggle when the user has no explicit
    // preference. This avoids disk writes from every debugLog call in production.
    if let preference = UserDefaults.standard.object(forKey: "DebugLogging") as? Bool {
        guard preference else { return }
    } else {
        guard clipboard_is_debug_logging() != 0 else { return }
    }
    appendLogLine("[ClipboardManager] \(logDateFormatter.string(from: Date())) \(message)")
}

/// Always-on counterpart of Rust's `error_log!`: real failures (hotkey lost,
/// backend refused to start) must be observable in release builds even when
/// the user has verbose logging off. Keep it rare — it is not rate limited.
func errorLog(_ message: String) {
    appendLogLine("[ClipboardManager] \(logDateFormatter.string(from: Date())) ERROR \(message)")
}

private func appendLogLine(_ line: String) {
    // Single O_APPEND write: seekToEnd+write is not atomic, so it can overwrite
    // a record the Rust side appended in between (measured as corrupted trace
    // lines / a lost capture record). O_APPEND makes the kernel place every
    // write at end-of-file atomically, so Swift, Rust stderr, and the trace
    // writer can all share this file safely.
    let payload = Array((line + "\n").utf8)
    let fd = open(debugLogPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
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
