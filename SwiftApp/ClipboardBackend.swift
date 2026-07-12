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
        // Batch-read all items under a SINGLE Rust-side lock — eliminates the
        // race condition where the monitor thread could shift array indices
        // between successive per-index FFI calls.
        guard let jsonStr = clipboard_get_all_items_json() else {
            return
        }
        let jsonString = String(cString: jsonStr)
        clipboard_free_string(jsonStr)

        guard let data = jsonString.data(using: .utf8),
              let rawItems = try? JSONDecoder().decode([ClipItemJSON].self, from: data) else {
            print("[ClipboardBackend] failed to parse items JSON")
            return
        }

        var newItems: [ClipboardItem] = []
        for raw in rawItems {
            switch raw.ty {
            case 0: // Text
                let text = raw.tx ?? ""
                newItems.append(.text(
                    entryId: raw.id,
                    text: text,
                    timestamp: raw.ts,
                    label: raw.lb,
                    sourceName: raw.sn,
                    sourceBundleId: raw.sb
                ))
            case 1: // Image
                // Load thumbnail by db_id — no history lock needed
                let dbId = raw.di ?? 0
                var thumbData = Data()
                if dbId != 0 {
                    var len: Int32 = 0
                    if let ptr = clipboard_get_image_thumb_by_db_id(Int64(dbId), &len) {
                        thumbData = Data(bytes: ptr, count: Int(len))
                        clipboard_free_bytes(ptr, len)
                    }
                }
                newItems.append(.image(
                    entryId: raw.id,
                    dbId: dbId,
                    thumbData: thumbData,
                    width: raw.w ?? 0,
                    height: raw.h ?? 0,
                    timestamp: raw.ts,
                    label: raw.lb,
                    sourceName: raw.sn,
                    sourceBundleId: raw.sb
                ))
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
        guard index < items.count else { return false }
        let entryId = UInt64(items[index].id)
        let result = clipboard_select_and_paste_by_id(entryId) != 0
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

/// JSON-decoded item from the Rust batch-read API.
private struct ClipItemJSON: Codable {
    let ty: Int       // 0 = text, 1 = image
    let id: Int        // stable entry id
    let tx: String?    // text content (ty=0)
    let di: Int?       // db_id for image (ty=1)
    let w: Int?        // width (ty=1)
    let h: Int?        // height (ty=1)
    let tw: Int?       // thumb_width (ty=1)
    let th: Int?       // thumb_height (ty=1)
    let ts: UInt64     // timestamp
    let lb: String     // label
    let sn: String     // source_name
    let sb: String     // source_bundle_id
}

enum ClipboardItem: Identifiable {
    case text(entryId: Int, text: String, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)
    case image(entryId: Int, dbId: Int, thumbData: Data, width: Int, height: Int, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)

    var id: Int {
        switch self {
        case .text(let entryId, _, _, _, _, _): return entryId
        case .image(let entryId, _, _, _, _, _, _, _, _): return entryId
        }
    }

    var label: String {
        switch self {
        case .text(_, _, _, let label, _, _): return label
        case .image(_, _, _, _, _, _, let label, _, _): return label
        }
    }

    var timestamp: UInt64 {
        switch self {
        case .text(_, _, let ts, _, _, _): return ts
        case .image(_, _, _, _, _, let ts, _, _, _): return ts
        }
    }

    var sourceName: String {
        switch self {
        case .text(_, _, _, _, let sn, _): return sn
        case .image(_, _, _, _, _, _, _, let sn, _): return sn
        }
    }

    var sourceBundleId: String {
        switch self {
        case .text(_, _, _, _, _, let sbid): return sbid
        case .image(_, _, _, _, _, _, _, _, let sbid): return sbid
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
