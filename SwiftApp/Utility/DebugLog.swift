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
    // emitted before `ClipboardBackend.start()` (startup/license gate) honor
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
    let logLine = line + "\n"
    // stderr is dup2'd onto the debug log file by AppDelegate at launch, so
    // Rust's eprintln interleaves here too; write to the file directly to
    // stay independent of that redirect (logging may run before it).
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLogPath)) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? logLine.write(toFile: debugLogPath, atomically: true, encoding: .utf8)
    }
}
