import Foundation

func debugLog(_ message: String) {
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
