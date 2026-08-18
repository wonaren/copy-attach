import Foundation

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
    let logLine = "[ClipboardManager] \(Date()) \(message)\n"
    // stderr is dup2'd onto the debug log file by AppDelegate at launch, so
    // Rust's eprintln interleaves here too; write to the file directly to
    // stay independent of that redirect (debugLog may run before it).
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/copyattach_debug.log")) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? logLine.write(toFile: "/tmp/copyattach_debug.log", atomically: true, encoding: .utf8)
    }
}
