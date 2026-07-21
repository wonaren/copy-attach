import Foundation

func debugLog(_ message: String) {
    let logLine = "[ClipboardManager] \(Date()) \(message)\n"
    fputs(logLine, stderr)

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
