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
    private let reloadQueue = DispatchQueue(label: "com.copyattach.reload", qos: .userInitiated)
    private var reloadGeneration = 0
    private var lastImageEncodingCounter: UInt64 = 0
    private var lastHistoryRevision: UInt64 = 0
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.totalCostLimit = 30 * 1024 * 1024  // 30 MB
        return c
    }()

    @Published var favoriteIds: Set<Int> = []

    private let favoritesKey = "FavoriteIds"

    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) {
            favoriteIds = ids
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoriteIds) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }

    func toggleFavorite(_ entryId: Int) {
        if favoriteIds.contains(entryId) {
            favoriteIds.remove(entryId)
        } else {
            favoriteIds.insert(entryId)
        }
        saveFavorites()
    }

    func isFavorite(_ entryId: Int) -> Bool {
        favoriteIds.contains(entryId)
    }

    private init() {
        permissionGranted = checkPermission()
        loadFavorites()
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
        syncIgnoreRules()
        syncImagePasteModifier()

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

    /// Pushes the persisted capture policy to Rust. The monitor evaluates it
    /// before creating history entries or reading image payloads.
    func syncIgnoreRules() {
        let appIDs = UserDefaults.standard.stringArray(forKey: "IgnoredAppBundleIDs") ?? []
        let payload = appIDs.joined(separator: "\n")
        let ignoreText = UserDefaults.standard.bool(forKey: "IgnoreTextClipboardType")
        let ignoreImages = UserDefaults.standard.bool(forKey: "IgnoreImageClipboardType")
        let ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
        let shortTextThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold")
        let minimum = ignoreShortText ? max(shortTextThreshold, 1) : 0
        let result = payload.withCString {
            clipboard_set_ignore_rules($0, ignoreText ? 1 : 0, ignoreImages ? 1 : 0, Int32(minimum))
        }
        if result == 0 {
            debugLog("Failed to apply clipboard ignore rules")
        }
    }

    /// Push the image paste modifier preference to Rust.
    func syncImagePasteModifier() {
        let useCtrl = UserDefaults.standard.bool(forKey: "ImagePasteUseCtrlV")
        clipboard_set_paste_image_with_ctrl_v(useCtrl ? 1 : 0)
    }

    /// Detect the current frontmost app and tell Rust about it
    private func updateSourceApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? "unknown"
            let pid = Int32(app.processIdentifier)
            clipboard_set_source_app(name, bundleId, pid)
        }
    }

    private func refresh() {
        let newCount = Int(clipboard_get_count())
        let newEncCounter = clipboard_get_image_encoding_counter()
        let newHistoryRevision = clipboard_get_history_revision()
        // A duplicate re-copy changes ordering/timestamp but not count. Observe
        // the backend revision as well so the Popup reloads in that case.
        if newCount != count || newEncCounter != lastImageEncodingCounter || newHistoryRevision != lastHistoryRevision {
            count = newCount
            lastImageEncodingCounter = newEncCounter
            lastHistoryRevision = newHistoryRevision
            reloadItems()
        }
        let wasGranted = permissionGranted
        permissionGranted = checkPermission()
        if !wasGranted && permissionGranted {
            // Permission newly granted — bring settings window to front
            // so the user sees the updated "已授权" state without
            // having to manually switch back after closing System Settings.
            AppDelegate.shared?.focusSettingsWindow()
        }
    }

    private func reloadItems() {
        let gen = reloadGeneration &+ 1
        reloadGeneration = gen
        reloadQueue.async { [gen] in
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
                    let fullText: String = {
                        guard let cStr = clipboard_snapshot_item_text(snap, Int32(i)) else { return label }
                        let s = String(cString: cStr)
                        clipboard_free_string(cStr)
                        return s
                    }()
                    newItems.append(.text(
                        entryId: id,
                        text: label,
                        timestamp: timestamp,
                        label: label,
                        sourceName: sourceName,
                        sourceBundleId: sourceBundleId,
                        fullText: fullText
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
            DispatchQueue.main.async { [gen] in
                guard gen == self.reloadGeneration else { return }
                self.items = newItems
            }
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

    func getTextByEntryId(_ entryId: Int) -> String? {
        guard let cStr = clipboard_get_text_by_id(UInt64(entryId)) else { return nil }
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
        let entryId = items[index].id
        let result = clipboard_delete_by_id(UInt64(entryId)) != 0
        if result {
            favoriteIds.remove(entryId)
            saveFavorites()
            items.remove(at: index)
            count = items.count
            // Bump generation to discard any stale in-flight snapshot
            // that might still include the deleted item.
            reloadGeneration &+= 1
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

    // MARK: - Undo Delete

    /// Undo the most recent deletion. Performs a synchronous reload from snapshot
    /// so the caller can wrap this in `withAnimation` for a smooth transition.
    func undoDelete() -> Bool {
        guard clipboard_undo_delete() != 0 else { return false }

        // Clear thumbnail cache: restored images get new db_ids, old keys are orphans.
        clearThumbnailCache()

        // Lightweight synchronous prepend: find the restored entry in the snapshot
        // by its entry_id (set by Rust after undo). Avoids TOCTOU races where the
        // monitor thread inserts new content at index 0 between undo and snapshot.
        guard let snap = clipboard_snapshot_acquire() else {
            return false
        }
        defer { clipboard_snapshot_release(snap) }

        // Sync count to suppress redundant timer refresh.
        count = Int(clipboard_snapshot_count(snap))

        let restoredId = Int(clipboard_last_restored_id())
        guard restoredId > 0 else {
            // Rust didn't record a restored ID — use first-snapshot fallback.
            guard let restoredItem = readFirstSnapshotItem(snap) else { return false }
            items.insert(restoredItem, at: 0)
            reloadGeneration &+= 1
            return true
        }

        // Scan the snapshot for the entry matching the restored ID.
        let c = Int(clipboard_snapshot_count(snap))
        for i in 0..<c {
            let sid = Int(clipboard_snapshot_item_id(snap, Int32(i)))
            if sid == restoredId {
                if let restoredItem = readSnapshotItem(snap, at: Int32(i)) {
                    items.insert(restoredItem, at: 0)
                }
                break
            }
        }

        reloadGeneration &+= 1
        return true
    }

    /// Read the first entry from a snapshot and build a ClipboardItem (O(1)).
    private func readFirstSnapshotItem(_ snap: UnsafeMutableRawPointer) -> ClipboardItem? {
        return readSnapshotItem(snap, at: 0)
    }

    /// Read the entry at index `i` from a snapshot and build a ClipboardItem.
    private func readSnapshotItem(_ snap: UnsafeMutableRawPointer, at i: Int32) -> ClipboardItem? {
        guard Int(clipboard_snapshot_count(snap)) > Int(i) else { return nil }
        let type = Int(clipboard_snapshot_item_type(snap, i))
        let id = Int(clipboard_snapshot_item_id(snap, i))
        let timestamp = UInt64(clipboard_snapshot_item_timestamp(snap, i))

        let label: String = {
            guard let cStr = clipboard_snapshot_item_label(snap, i) else { return "" }
            let s = String(cString: cStr)
            clipboard_free_string(cStr)
            return s
        }()
        let sourceName: String = {
            guard let cStr = clipboard_snapshot_item_source_name(snap, i) else { return "" }
            let s = String(cString: cStr)
            clipboard_free_string(cStr)
            return s
        }()
        let sourceBundleId: String = {
            guard let cStr = clipboard_snapshot_item_source_bundle_id(snap, i) else { return "" }
            let s = String(cString: cStr)
            clipboard_free_string(cStr)
            return s
        }()

        switch type {
        case 0:
            let fullText: String = {
                guard let cStr = clipboard_snapshot_item_text(snap, i) else { return label }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()
            return .text(
                entryId: id, text: label, timestamp: timestamp,
                label: label, sourceName: sourceName,
                sourceBundleId: sourceBundleId, fullText: fullText
            )
        case 1:
            let dbId = Int(clipboard_snapshot_get_image_db_id(snap, i))
            let w = Int(clipboard_snapshot_get_image_width(snap, i))
            let h = Int(clipboard_snapshot_get_image_height(snap, i))
            return .image(
                entryId: id, dbId: dbId, width: w, height: h,
                timestamp: timestamp, label: label,
                sourceName: sourceName, sourceBundleId: sourceBundleId
            )
        default:
            return nil
        }
    }

    /// Returns true if there is at least one deleted entry that can be undone.
    func canUndo() -> Bool {
        clipboard_can_undo() != 0
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

