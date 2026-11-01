import Foundation

private let debugLogPath = "/tmp/copyattach_debug.log"

private let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss +0800"
    f.timeZone = TimeZone(secondsFromGMT: 28800)
    return f
}()

func debugLog(_ message: String) {
    if let preference = UserDefaults.standard.object(forKey: "DebugLogging") as? Bool {
        guard preference else { return }
    } else {
        guard clipboard_is_debug_logging() != 0 else { return }
    }
    appendLogLine("[ClipboardManager] \(logDateFormatter.string(from: Date())) \(message)")
}

func errorLog(_ message: String) {
    appendLogLine("[ClipboardManager] \(logDateFormatter.string(from: Date())) ERROR \(message)")
}

private func appendLogLine(_ line: String) {
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
