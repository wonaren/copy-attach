import AppKit
import Foundation

/// Swift wrapper around the Rust copy_attach C FFI.
class ClipboardBackend: ObservableObject {
    static let shared = ClipboardBackend()

    @Published var count: Int = 0
    @Published var items: [ClipboardItem] = []
    @Published var permissionGranted: Bool = false

    private var timer: Timer?
    private var sourceAppTimer: Timer?

    private init() {
        permissionGranted = checkPermission()
    }

    func start() -> Bool {
        let result = clipboard_init()
        guard result != 0 else {
            print("[ClipboardBackend] init failed (result: \(result)) — Rust backend not available")
            return false
        }
        print("[ClipboardBackend] init result: \(result)")
        permissionGranted = checkPermission()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Periodically update the frontmost app info for Rust's clipboard monitor
        sourceAppTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateSourceApp()
        }

        // Trigger an immediate refresh so the UI isn't stale for 0.5s
        refresh()

        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sourceAppTimer?.invalidate()
        sourceAppTimer = nil
        clipboard_cleanup()
    }

    /// Detect the current frontmost app and tell Rust about it
    private func updateSourceApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? "unknown"
            clipboard_set_source_app(name, bundleId)
        }
    }

    private func refresh() {
        let newCount = Int(clipboard_get_count())
        if newCount != count {
            count = newCount
            reloadItems()
        }
        permissionGranted = checkPermission()
    }

    private func reloadItems() {
        let c = Int(clipboard_get_count())
        var newItems: [ClipboardItem] = []
        for i in 0..<c {
            let type = Int(clipboard_get_item_type(Int32(i)))
            let timestamp = clipboard_get_item_timestamp(Int32(i))
            let sourceName = getSourceName(at: i)
            let sourceBundleId = getSourceBundleId(at: i)

            switch type {
            case 0: // Text
                if let text = getText(at: i) {
                    newItems.append(.text(
                        id: i, text: text, timestamp: UInt64(timestamp),
                        label: getLabel(at: i),
                        sourceName: sourceName, sourceBundleId: sourceBundleId
                    ))
                }
            case 1: // Image
                let (w, h) = getImageSize(at: i)
                if let thumbData = getImageThumb(at: i) {
                    newItems.append(.image(
                        id: i, thumbData: thumbData, width: w, height: h,
                        timestamp: UInt64(timestamp), label: getLabel(at: i),
                        sourceName: sourceName, sourceBundleId: sourceBundleId
                    ))
                }
            default:
                break
            }
        }
        DispatchQueue.main.async {
            self.items = newItems
        }
    }

    // MARK: - Getters

    func getLabel(at index: Int) -> String {
        guard let cStr = clipboard_get_item_label(Int32(index)) else { return "" }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    func getText(at index: Int) -> String? {
        guard let cStr = clipboard_get_item_text(Int32(index)) else { return nil }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    func getSourceName(at index: Int) -> String {
        guard let cStr = clipboard_get_item_source_name(Int32(index)) else { return "" }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    func getSourceBundleId(at index: Int) -> String {
        guard let cStr = clipboard_get_item_source_bundle_id(Int32(index)) else { return "" }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    func getImageThumb(at index: Int) -> Data? {
        var len: Int32 = 0
        guard let ptr = clipboard_get_image_thumb(Int32(index), &len) else { return nil }
        let data = Data(bytes: ptr, count: Int(len))
        clipboard_free_bytes(ptr, len)
        return data
    }

    func getImageFull(at index: Int) -> Data? {
        var len: Int32 = 0
        guard let ptr = clipboard_get_image_full(Int32(index), &len) else { return nil }
        let data = Data(bytes: ptr, count: Int(len))
        clipboard_free_bytes(ptr, len)
        return data
    }

    func getImageSize(at index: Int) -> (Int, Int) {
        var w: Int32 = 0, h: Int32 = 0
        clipboard_get_image_size(Int32(index), &w, &h)
        return (Int(w), Int(h))
    }

    func selectAndPaste(at index: Int) -> Bool {
        let result = clipboard_select_and_paste(Int32(index)) != 0
        if result {
            // History order changed (selected item moved to top) — force UI refresh
            reloadItems()
        }
        return result
    }

    func checkPermission() -> Bool {
        return clipboard_check_permission() != 0
    }

    func openPreferences() {
        clipboard_open_preferences()
    }

    func clearHistory() {
        clipboard_clear_history()
        // Immediately update local state
        DispatchQueue.main.async {
            self.count = 0
            self.items = []
        }
    }
}

// MARK: - Item Types

enum ClipboardItem: Identifiable {
    case text(id: Int, text: String, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)
    case image(id: Int, thumbData: Data, width: Int, height: Int, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)

    var id: Int {
        switch self {
        case .text(let id, _, _, _, _, _): return id
        case .image(let id, _, _, _, _, _, _, _): return id
        }
    }

    var label: String {
        switch self {
        case .text(_, _, _, let label, _, _): return label
        case .image(_, _, _, _, _, let label, _, _): return label
        }
    }

    var timestamp: UInt64 {
        switch self {
        case .text(_, _, let ts, _, _, _): return ts
        case .image(_, _, _, _, let ts, _, _, _): return ts
        }
    }

    var sourceName: String {
        switch self {
        case .text(_, _, _, _, let sn, _): return sn
        case .image(_, _, _, _, _, _, let sn, _): return sn
        }
    }

    var sourceBundleId: String {
        switch self {
        case .text(_, _, _, _, _, let sbid): return sbid
        case .image(_, _, _, _, _, _, _, let sbid): return sbid
        }
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

// MARK: - App Icon

/// Returns the app's own icon as an NSImage
extension NSImage {
    static var appIcon: NSImage {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let image = NSImage(contentsOfFile: path) {
            return image
        }
        return NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Cache app icons by bundle ID to avoid repeated lookups
private var appIconCache: [String: NSImage] = [:]

func getAppIcon(for bundleId: String) -> NSImage? {
    if bundleId.isEmpty { return nil }
    if let cached = appIconCache[bundleId] { return cached }

    // Try to get icon from the running application
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
       let icon = app.icon {
        appIconCache[bundleId] = icon
        return icon
    }

    // Fallback: try to get icon from the app bundle path
    if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
        let icon = NSWorkspace.shared.icon(forFile: path.path)
        appIconCache[bundleId] = icon
        return icon
    }

    return nil
}
