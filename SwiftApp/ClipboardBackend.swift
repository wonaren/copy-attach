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
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.totalCostLimit = 30 * 1024 * 1024  // 30 MB
        return c
    }()

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

        // Restore saved cleanup threshold from UserDefaults
        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        if saved >= 100 {
            clipboard_set_cleanup_threshold(Int32(saved))
        }

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
        // Acquire a consistent snapshot under a single Rust-side lock,
        // then read all items from the snapshot (no further locking).
        guard let snap = clipboard_snapshot_acquire() else { return }
        defer { clipboard_snapshot_release(snap) }

        let c = Int(clipboard_snapshot_count(snap))
        var newItems: [ClipboardItem] = []

        for i in 0..<c {
            let type = Int(clipboard_snapshot_item_type(snap, Int32(i)))
            let id = Int(clipboard_snapshot_item_id(snap, Int32(i)))
            let timestamp = UInt64(clipboard_snapshot_item_timestamp(snap, Int32(i)))

            let label: String = {
                guard let cStr = clipboard_snapshot_item_label(snap, Int32(i)) else { return "" }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()

            let sourceName: String = {
                guard let cStr = clipboard_snapshot_item_source_name(snap, Int32(i)) else { return "" }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()

            let sourceBundleId: String = {
                guard let cStr = clipboard_snapshot_item_source_bundle_id(snap, Int32(i)) else { return "" }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()

            switch type {
            case 0: // Text
                let text: String = {
                    guard let cStr = clipboard_snapshot_item_text(snap, Int32(i)) else { return "" }
                    let s = String(cString: cStr)
                    clipboard_free_string(cStr)
                    return s
                }()
                newItems.append(.text(
                    entryId: id,
                    text: text,
                    timestamp: timestamp,
                    label: label,
                    sourceName: sourceName,
                    sourceBundleId: sourceBundleId
                ))
            case 1: // Image
                let dbId = Int(clipboard_snapshot_get_image_db_id(snap, Int32(i)))
                let w = Int(clipboard_snapshot_get_image_width(snap, Int32(i)))
                let h = Int(clipboard_snapshot_get_image_height(snap, Int32(i)))
                newItems.append(.image(
                    entryId: id,
                    dbId: dbId,
                    width: w,
                    height: h,
                    timestamp: timestamp,
                    label: label,
                    sourceName: sourceName,
                    sourceBundleId: sourceBundleId
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

    func getImageFullByDbId(_ dbId: Int) -> Data? {
        var len: Int32 = 0
        guard let ptr = clipboard_get_image_full_by_db_id(Int64(dbId), &len) else { return nil }
        let data = Data(bytes: ptr, count: Int(len))
        clipboard_free_bytes(ptr, len)
        return data
    }

    func getCachedThumbnail(dbId: Int) -> NSImage? {
        guard dbId != 0 else { return nil }
        let key = NSNumber(value: dbId)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        var len: Int32 = 0
        guard let ptr = clipboard_get_image_thumb_by_db_id(Int64(dbId), &len) else { return nil }
        let data = Data(bytes: ptr, count: Int(len))
        clipboard_free_bytes(ptr, len)
        guard let image = NSImage(data: data) else {
            print("[ClipboardBackend] failed to decode thumbnail for dbId=\(dbId): PNG data is \(data.count) bytes but NSImage(data:) returned nil")
            return nil
        }
        // cost = decoded RGBA upper bound for a 300px-max-dimension thumbnail
        thumbnailCache.setObject(image, forKey: key, cost: 300 * 300 * 4)
        return image
    }

    /// Immediately release all cached thumbnails.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
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

    func deleteEntry(at index: Int) -> Bool {
        guard index < items.count else { return false }
        let entryId = UInt64(items[index].id)
        let result = clipboard_delete_by_id(entryId) != 0
        if result {
            items.remove(at: index)
            count = items.count
        }
        return result
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

    /// Trim the oldest N percent of entries from history and DB.
    /// Returns the number of entries removed.
    func trimOldestPercent(_ percent: Int) -> Int {
        let removed = Int(clipboard_trim_oldest_percent(Int32(percent)))
        if removed > 0 {
            DispatchQueue.main.async {
                self.refresh()
            }
        }
        return removed
    }

    /// Get the current cleanup threshold from Rust.
    func getCleanupThreshold() -> Int {
        Int(clipboard_get_cleanup_threshold())
    }

    /// Set the cleanup threshold. Persists to UserDefaults and syncs to Rust.
    func setCleanupThreshold(_ threshold: Int) {
        let clamped = max(100, min(10000, threshold))
        clipboard_set_cleanup_threshold(Int32(clamped))
        UserDefaults.standard.set(clamped, forKey: "CleanupThreshold")
    }

    /// Returns total storage size in bytes of all clipboard entries in the database.
    func getStorageSize() -> Int64 {
        clipboard_get_storage_size()
    }
}

// MARK: - Item Types

enum ClipboardItem: Identifiable {
    case text(entryId: Int, text: String, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)
    case image(entryId: Int, dbId: Int, width: Int, height: Int, timestamp: UInt64, label: String, sourceName: String, sourceBundleId: String)

    var id: Int {
        switch self {
        case .text(let entryId, _, _, _, _, _): return entryId
        case .image(let entryId, _, _, _, _, _, _, _): return entryId
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
