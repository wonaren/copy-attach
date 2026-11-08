import AppKit
import Foundation
import Observation
import os

private let thumbnailDecodeSlots = DispatchSemaphore(value: 4)

struct RowThumbnailBox: Sendable, Equatable {
    let widthPx: Int
    let heightPx: Int

    static func current(scale: CGFloat) -> RowThumbnailBox {
        let s = max(scale, 1)
        return RowThumbnailBox(widthPx: Int((460 * s).rounded()),
                               heightPx: Int((46 * s).rounded()))
    }

    func makeThumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: bound(for: source)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func bound(for source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else {
            return max(widthPx, heightPx)
        }
        let scale = min(Double(widthPx) / w, Double(heightPx) / h, 1.0)
        return max(1, Int((max(w, h) * scale).rounded()))
    }
}

@MainActor
@Observable
class ClipboardBackend {
    static let shared = ClipboardBackend()

    nonisolated static let maxCustomLabelScalars = 200

    var count: Int = 0
    var items: [ClipboardItem] = []
    var permissionGranted: Bool = false

    private(set) var itemsGeneration: Int = 0

    private struct WaiterState {
        var generation = 0
        var active = false
    }
    private let waiterState = OSAllocatedUnfairLock(initialState: WaiterState())
    nonisolated private static let refreshLifelineMs: UInt64 = 3_000
    private var sourceAppObserver: NSObjectProtocol?
    private let reloadQueue = DispatchQueue(label: "com.copyattach.reload", qos: .userInitiated)
    private let reloadGeneration = OSAllocatedUnfairLock(initialState: 0)
    private var pasteTargetPID: pid_t?
    private(set) var sourceAppBundleID: String?
    private var lastImageEncodingCounter: UInt64 = 0
    private var lastHistoryRevision: UInt64 = 0
    private var popupOpenPerfUs: UInt64 = 0
    private var popupOpenPerfPending = false
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = 120
        c.totalCostLimit = 8 * 1024 * 1024
        return c
    }()
    var favoriteIds: Set<Int> = []
    var slotByEntryId: [Int: Int] = [:]
    private var pendingQuickSlots: [Int] = []
    private var quickSlotDrainScheduled = false

    private let legacyFavoritesKey = "FavoriteIds"

    @discardableResult
    func toggleFavorite(_ entryId: Int) -> Bool {
        let wantFavorite = !favoriteIds.contains(entryId)
        guard clipboard_set_favorite(UInt64(entryId), wantFavorite ? 1 : 0) != 0 else {
            errorLog("toggleFavorite: backend rejected favorite state for entry \(entryId) — see Rust log")
            return false
        }
        if wantFavorite {
            favoriteIds.insert(entryId)
        } else {
            favoriteIds.remove(entryId)
        }
        reloadGeneration.withLock { $0 &+= 1 }
        itemsGeneration &+= 1
        OnboardingGuide.shared.record(.favorited)
        return true
    }

    private init() {
        permissionGranted = checkPermission()
    }

    enum StartResult {
        case started
        case retryable
        case corruptDatabase
        case permanentEnvironment
    }

    func start() -> StartResult {
        Self.syncDebugLogging()
        let savedThreshold = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        let initThreshold = savedThreshold >= 100 ? Int32(savedThreshold) : 0
        let legacyFavorites = legacyFavoriteCSV()
        let result = legacyFavorites.csv.withCString { csv in
            clipboard_init_with_threshold_and_favorites(initThreshold, csv)
        }
        if result == -1 {
            print("[ClipboardBackend] init failed: database corrupt")
            return .corruptDatabase
        }
        if result == -2 {
            print("[ClipboardBackend] init failed: database unusable in this environment")
            return .permanentEnvironment
        }
        guard result != 0 else {
            print("[ClipboardBackend] init failed (result: \(result)) — Rust backend not available")
            return .retryable
        }
        print("[ClipboardBackend] init result: \(result)")
        permissionGranted = checkPermission()
        if legacyFavorites.hadKey {
            UserDefaults.standard.removeObject(forKey: legacyFavoritesKey)
            debugLog("legacy favorites: handed \(legacyFavorites.count) id(s) to the engine before the startup trim")
        }

        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        if saved >= 100 {
            clipboard_set_cleanup_threshold(Int32(saved))
        }
        syncIgnoreRules()

        sourceAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.updateSourceApp() }
        }
        updateSourceApp()

        refreshPermission()
        refresh()
        syncQuickSlotTap()

        return .started
    }

    func stop() {
        stopHistoryWaiter()
        clearThumbnailCache()
        if let observer = sourceAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sourceAppObserver = nil
        }
        clipboard_cleanup()
    }

    @MainActor
    func setPopupVisible(_ visible: Bool) {
        QuickSlotEventTap.shared.popupOpen = visible
        if visible {
            let perfOpen = PerfSpan.start("swift", "popup.visible_setup")
            popupOpenPerfUs = Perf.nowUs()
            popupOpenPerfPending = items.isEmpty
            refreshPermission()
            refresh()
            startHistoryWaiter()
            perfOpen?.end()
        } else {
            stopHistoryWaiter()
            DispatchQueue.global(qos: .utility).async {
                if clipboard_shrink_db_memory() == 0 {
                    debugLog("shrink_db_memory failed (see Rust log)")
                }
            }
        }
    }

    @MainActor
    private func startHistoryWaiter() {
        let already = waiterState.withLock { state -> Bool in
            if state.active { return true }
            state.active = true
            state.generation &+= 1
            return false
        }
        guard !already else { return }
        let generation = waiterState.withLock { $0.generation }
        scheduleWait(generation: generation)
    }

    @MainActor
    private func stopHistoryWaiter() {
        _ = waiterState.withLock { state -> Int in
            state.active = false
            state.generation &+= 1
            return state.generation
        }
    }

    @MainActor
    private func scheduleWait(generation: Int) {
        var revision: UInt64 = 0
        var encoding: UInt64 = 0
        _ = clipboard_history_counters(&revision, &encoding)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let perfWait = PerfSpan.start("swift", "reload.wait")
            let observed = clipboard_wait_for_history_change(revision, Self.refreshLifelineMs)
            perfWait?.val = Int64(observed &- revision)
            perfWait?.end()

            await MainActor.run { [weak self] in
                guard let self else { return }
                let stillActive = self.waiterState.withLock { $0.generation == generation && $0.active }
                guard stillActive else { return }
                if observed != revision {
                    Perf.instant("swift", "reload.event_wake")
                    self.refresh()
                }
                self.scheduleWait(generation: generation)
            }
        }
    }

    func syncIgnoreRules() {
        let appIDs = UserDefaults.standard.stringArray(forKey: "IgnoredAppBundleIDs") ?? []
        let payload = appIDs.joined(separator: "\n")
        let ignoreText = UserDefaults.standard.bool(forKey: "IgnoreTextClipboardType")
        let ignoreImages = UserDefaults.standard.bool(forKey: "IgnoreImageClipboardType")
        let ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
        let rawThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold")
        let shortTextThreshold = rawThreshold > 0 ? rawThreshold : 3
        let minimum = ignoreShortText ? max(shortTextThreshold, 1) : 0
        let ignoreSensitive = UserDefaults.standard.object(forKey: "IgnoreSensitiveClipboard") as? Bool ?? true
        let result = payload.withCString {
            clipboard_set_ignore_rules($0, ignoreText ? 1 : 0, ignoreImages ? 1 : 0, Int32(minimum), ignoreSensitive ? 1 : 0)
        }
        if result == 0 {
            debugLog("Failed to apply clipboard ignore rules")
        }
    }

    private func legacyFavoriteCSV() -> (csv: String, hadKey: Bool, count: Int) {
        guard let data = UserDefaults.standard.data(forKey: legacyFavoritesKey) else {
            return ("", false, 0)
        }
        guard let ids = try? JSONDecoder().decode(Set<Int>.self, from: data) else {
            errorLog("legacy favorites: stored data is not a Set<Int>; leaving the key untouched")
            return ("", false, 0)
        }
        return (ids.map(String.init).joined(separator: ","), true, ids.count)
    }

    static func syncDebugLogging() {
        if UserDefaults.standard.object(forKey: "DebugLogging") != nil {
            clipboard_set_debug_logging(UserDefaults.standard.bool(forKey: "DebugLogging") ? 1 : 0)
        }
    }

    func setDebugLogging(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "DebugLogging")
        clipboard_set_debug_logging(enabled ? 1 : 0)
    }

    func recordFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return
            }
            let name = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? "unknown"
            let pid = Int32(app.processIdentifier)
            pasteTargetPID = app.processIdentifier
            sourceAppBundleID = bundleId
            clipboard_set_source_app(name, bundleId, pid)
        }
    }

    private func updateSourceApp() {
        if !permissionGranted {
            refreshPermission()
        }
        QuickSlotEventTap.shared.appIsFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        recordFrontmostApp()
    }

    static let richTextDragAppsDefaultsKey = "RichTextDragAppBundleIDs"

    static let defaultRichTextDragApps = ["org.b3log.siyuan", "abnerworks.Typora"]

    static var richTextDragAppBundleIDs: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: richTextDragAppsDefaultsKey)
                ?? defaultRichTextDragApps
        }
        set {
            UserDefaults.standard.set(newValue, forKey: richTextDragAppsDefaultsKey)
        }
    }

    var sourceAppNeedsRichTextDrag: Bool {
        guard let bundleId = sourceAppBundleID else { return false }
        return Self.richTextDragAppBundleIDs.contains(bundleId)
    }

    private func refresh() {
        let newCount = Int(clipboard_get_count())
        var newHistoryRevision: UInt64 = 0
        var newEncCounter: UInt64 = 0
        _ = clipboard_history_counters(&newHistoryRevision, &newEncCounter)
        if newCount != count || newEncCounter != lastImageEncodingCounter || newHistoryRevision != lastHistoryRevision {
            Perf.instant("swift", "capture.ui_observed")
            count = newCount
            lastImageEncodingCounter = newEncCounter
            lastHistoryRevision = newHistoryRevision
            reloadItems()
        }
    }

    func refreshPermission() {
        let wasGranted = permissionGranted
        permissionGranted = checkPermission()
        if !wasGranted && permissionGranted {
            HotkeyManager.shared.reregisterHotkeys()
            AppDelegate.shared?.focusSettingsWindow()
        }
        syncQuickSlotTap()
    }

    func syncQuickSlotTap() {
        QuickSlotEventTap.shared.sync(boundSlots: Set(slotByEntryId.values),
                                      permissionGranted: permissionGranted)
    }

    @discardableResult
    func toggleQuickSlot(entryId: Int, slot: Int) -> Bool {
        guard clipboard_toggle_quick_slot(UInt64(entryId), Int32(slot)) != 0 else {
            errorLog("toggleQuickSlot: backend rejected slot \(slot) for entry \(entryId) — see Rust log")
            return false
        }
        reloadItems()
        return true
    }

    @discardableResult
    func clearQuickSlots() -> Bool {
        guard clipboard_clear_quick_slots() != 0 else {
            errorLog("clearQuickSlots: backend rejected the clear — see Rust log")
            return false
        }
        reloadItems()
        return true
    }

    func pasteQuickSlot(_ slot: Int) {
        pendingQuickSlots.append(slot)
        guard !quickSlotDrainScheduled else { return }
        quickSlotDrainScheduled = true
        drainQuickSlotQueue()
    }

    private func drainQuickSlotQueue() {
        guard !pendingQuickSlots.isEmpty else {
            quickSlotDrainScheduled = false
            return
        }
        performQuickPaste(pendingQuickSlots.removeFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            self?.drainQuickSlotQueue()
        }
    }

    private func performQuickPaste(_ slot: Int) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else {
            debugLog("performQuickPaste: suppressed while CopyAttach is frontmost")
            return
        }
        recordFrontmostApp()
        let mode = PasteDeliveryMode.current
        let prepared = clipboard_prepare_quick_paste_by_slot(Int32(slot), Int32(mode.rawValue))
        guard prepared != 0 else {
            errorLog("performQuickPaste: slot \(slot) could not be prepared (unbound, missing payload, or no Accessibility permission)")
            return
        }
        if mode == .clipboardOnly {
            debugLog("performQuickPaste: slot \(slot) copied to the pasteboard (clipboard-only mode)")
            return
        }
        guard prepared > 0 else {
            errorLog("performQuickPaste: slot \(slot) written but no target pid — keystroke skipped")
            return
        }
        if clipboard_send_paste(prepared) == 0 {
            errorLog("performQuickPaste: ⌘V delivery failed for slot \(slot) (pid \(prepared))")
        }
    }

    func reloadItems() {
        let perfReload = PerfSpan.start("swift", "popup.reload")
        let gen = reloadGeneration.withLock { generation in
            generation &+= 1
            return generation
        }
        let generationLock = reloadGeneration
        reloadQueue.async { [gen, generationLock, weak self] in
            let stale = generationLock.withLock { $0 != gen }
            guard !stale else { return }

            var packedLength: Int32 = 0
            guard let packed = clipboard_snapshot_packed_acquire(&packedLength) else { return }
            guard packedLength > 0 else {
                clipboard_free_bytes(packed, packedLength)
                return
            }
            defer { clipboard_free_bytes(packed, packedLength) }

            let perfDecode = PerfSpan.start("swift", "snapshot.decode")
            guard let (newItems, favorites, slots) = PackedSnapshot.decodeItems(
                from: UnsafeRawPointer(packed),
                length: Int(packedLength)
            ) else {
                debugLog("Packed snapshot decode failed; skipping reload")
                return
            }
            if let span = perfDecode {
                span.val = Int64(newItems.count)
                span.end()
            }

            DispatchQueue.main.async { [gen, weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    guard gen == self.reloadGeneration.withLock({ $0 }) else { return }
                    self.items = newItems
                    self.favoriteIds = favorites
                    self.slotByEntryId = slots
                    self.syncQuickSlotTap()
                    self.itemsGeneration &+= 1
                    Perf.instant("swift", "list.published")
                    if let span = perfReload {
                        span.val = Int64(newItems.count)
                        span.end()
                    }
                    if self.popupOpenPerfPending {
                        self.popupOpenPerfPending = false
                        let delta = Perf.nowUs() &- self.popupOpenPerfUs
                        Perf.counter("swift", "popup.first_data_us", Int64(delta))
                        Perf.counter("swift", "popup.first_data_rows", Int64(newItems.count))
                    }
                }
            }
        }
    }

    nonisolated static func getTextByEntryId(_ entryId: Int) -> String? {
        guard let cStr = clipboard_get_text_by_id(UInt64(entryId)) else { return nil }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    nonisolated func searchIds(_ query: String) -> Set<Int> {
        guard !query.isEmpty else { return [] }
        var count: Int32 = 0
        let ptr = query.withCString { cQuery in
            clipboard_search_ids(cQuery, &count)
        }
        guard let ptr, count > 0 else { return [] }
        defer { clipboard_free_u64_array(ptr, count) }
        return (0..<Int(count)).reduce(into: Set<Int>()) { $0.insert(Int(ptr[$1])) }
    }

    nonisolated static func getImageFullByDbId(_ dbId: Int) -> Data? {
        var len: Int32 = 0
        guard let ptr = clipboard_get_image_full_by_db_id(Int64(dbId), &len) else { return nil }
        guard len > 0 else {
            clipboard_free_bytes(ptr, len)
            return nil
        }
        return Data(bytesNoCopy: ptr, count: Int(len), deallocator: .custom { raw, size in
            clipboard_free_bytes(raw.assumingMemoryBound(to: UInt8.self), Int32(size))
        })
    }

    func cachedThumbnail(dbId: Int) -> NSImage? {
        guard dbId != 0 else { return nil }
        return thumbnailCache.object(forKey: NSNumber(value: dbId))
    }

    private nonisolated static func decodeThumbnail(dbId: Int, box: RowThumbnailBox) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let perfQueue = PerfSpan.start("swift", "thumb.queue_wait")
                while thumbnailDecodeSlots.wait(timeout: .now() + 0.05) == .timedOut {
                    if Task.isCancelled {
                        perfQueue?.end()
                        continuation.resume(returning: nil)
                        return
                    }
                }
                perfQueue?.end()
                defer { thumbnailDecodeSlots.signal() }
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                autoreleasepool {
                    var len: Int32 = 0
                    let perfFfi = PerfSpan.start("swift", "thumb.ffi_read")
                    guard let ptr = clipboard_get_image_thumb_by_db_id(Int64(dbId), &len) else {
                        perfFfi?.end()
                        continuation.resume(returning: nil)
                        return
                    }
                    guard len > 0 else {
                        perfFfi?.end()
                        clipboard_free_bytes(ptr, len)
                        continuation.resume(returning: nil)
                        return
                    }
                    perfFfi?.val = Int64(len)
                    perfFfi?.end()
                    defer { clipboard_free_bytes(ptr, len) }
                    let data = Data(bytesNoCopy: ptr, count: Int(len), deallocator: .none)

                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let perfImageIO = PerfSpan.start("swift", "thumb.imageio")
                    let cgThumb = box.makeThumbnail(from: source)
                    perfImageIO?.end()
                    guard let cgThumb else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let size = NSSize(width: cgThumb.width, height: cgThumb.height)
                    let image = NSImage(cgImage: cgThumb, size: size)
                    continuation.resume(returning: image)
                }
            }
        }
    }

    func loadThumbnail(dbId: Int, box: RowThumbnailBox) async -> NSImage? {
        guard dbId != 0, !Task.isCancelled else { return nil }
        let key = NSNumber(value: dbId)
        if let cached = thumbnailCache.object(forKey: key) {
            Perf.counter("swift", "thumb.cache_hit", 1)
            return cached
        }
        Perf.counter("swift", "thumb.cache_miss", 1)
        let perfThumb = PerfSpan.start("swift", "thumb.decode_total")
        if let span = perfThumb { span.val = Int64(dbId) }
        guard let image = await Self.decodeThumbnail(dbId: dbId, box: box) else {
            perfThumb?.end()
            return nil
        }
        perfThumb?.end()
        guard !Task.isCancelled else { return nil }
        let px = image.size.width * image.size.height
        thumbnailCache.setObject(image, forKey: key, cost: Int(px) * 4)
        return image
    }

    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    func setCustomLabel(entryId: Int, label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= Self.maxCustomLabelScalars else {
            errorLog("setCustomLabel: remark for entry \(entryId) exceeds \(Self.maxCustomLabelScalars) scalars — rejected")
            return false
        }
        let ok = trimmed.withCString { cStr in
            clipboard_set_custom_label(UInt64(entryId), cStr) != 0
        }
        if ok {
            if let idx = items.firstIndex(where: { $0.id == entryId }) {
                items[idx] = items[idx].withUpdatedCustomLabel(trimmed)
                itemsGeneration &+= 1
                reloadGeneration.withLock { $0 &+= 1 }
            }
        } else {
            errorLog("setCustomLabel: backend rejected the remark for entry \(entryId) — see Rust log")
        }
        return ok
    }

    func deleteEntry(at index: Int) -> Bool {
        guard index < items.count else { return false }
        let entryId = items[index].id
        let result = clipboard_delete_by_id(UInt64(entryId)) != 0
        if result {
            favoriteIds.remove(entryId)
            if slotByEntryId.removeValue(forKey: entryId) != nil {
                syncQuickSlotTap()
            }
            PasteQueueManager.shared.remove(id: entryId)
            items.remove(at: index)
            count = items.count
            itemsGeneration &+= 1
            reloadGeneration.withLock { $0 &+= 1 }
        }
        return result
    }

    @discardableResult
    func selectAndPasteDismissingPopup(at index: Int, asPath: Bool = false, dismiss: () -> Void) -> Bool {
        guard index < items.count else { return false }
        let outcome = pasteEntryById(UInt64(items[index].id),
                                     asPath: asPath,
                                     dismiss: dismiss,
                                     perfName: "paste.menu_to_keystroke")
        return outcome != .entryUnavailable
    }

    enum PasteOutcome: Equatable {
        case pasted
        case copied
        case keystrokeNotDelivered
        case entryUnavailable
    }

    @discardableResult
    func pasteEntryById(_ entryId: UInt64,
                        asPath: Bool = false,
                        dismiss: () -> Void = {},
                        targetPID: Int32? = nil,
                        refreshAfter: Bool = true,
                        perfName: String = "paste.queue_keystroke") -> PasteOutcome {
        let perfPaste = PerfSpan.start("swift", perfName)
        let mode = PasteDeliveryMode.current
        let prepared = clipboard_prepare_paste_by_id(entryId, asPath, Int32(mode.rawValue))
        guard prepared != 0 else {
            errorLog("pasteEntryById: clipboard_prepare_paste_by_id failed for entry \(entryId)")
            perfPaste?.end()
            return .entryUnavailable
        }
        debugLog("[paste] entry \(entryId) prepared=\(prepared) mode=\(mode == .clipboardOnly ? "clipboard" : "keystroke")")

        dismiss()

        if mode == .clipboardOnly {
            perfPaste?.end()
            if refreshAfter {
                reloadItems()
            }
            return .copied
        }

        let pid: Int32
        if let targetPID {
            pid = targetPID
        } else if prepared > 0 {
            pid = prepared
        } else {
            errorLog("pasteEntryById: entry \(entryId) written but no target pid — keystroke skipped")
            perfPaste?.end()
            if refreshAfter {
                reloadItems()
            }
            return .keystrokeNotDelivered
        }

        let delivered = clipboard_send_paste(pid) != 0
        if !delivered {
            errorLog("pasteEntryById: ⌘V delivery failed for entry \(entryId) (pid \(pid))")
        }

        perfPaste?.end()

        if refreshAfter {
            reloadItems()
        }

        return delivered ? .pasted : .keystrokeNotDelivered
    }

    func undoDelete() -> Bool {
        guard clipboard_undo_delete() != 0 else { return false }

        let restoredId = Int(clipboard_last_restored_id())
        guard restoredId > 0 else {
            errorLog("undoDelete: clipboard_undo_delete succeeded but last_restored_id is invalid (\(restoredId))")
            return false
        }

        var packedLength: Int32 = 0
        guard let packed = clipboard_snapshot_packed_acquire(&packedLength) else {
            errorLog("undoDelete: packed snapshot unavailable after a successful undo")
            return false
        }
        guard packedLength > 0 else {
            clipboard_free_bytes(packed, packedLength)
            return false
        }
        defer { clipboard_free_bytes(packed, packedLength) }

        guard let (newItems, favorites, slots) = PackedSnapshot.decodeItems(
            from: UnsafeRawPointer(packed),
            length: Int(packedLength)
        ) else {
            errorLog("undoDelete: packed snapshot decode failed after a successful undo")
            return false
        }

        guard newItems.contains(where: { $0.id == restoredId }) else {
            errorLog("undoDelete: restored entry \(restoredId) not found in snapshot")
            return false
        }

        items = newItems
        favoriteIds = favorites
        slotByEntryId = slots
        count = newItems.count
        itemsGeneration &+= 1
        reloadGeneration.withLock { $0 &+= 1 }
        syncQuickSlotTap()
        return true
    }

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
        let customLabel: String = {
            guard let cStr = clipboard_snapshot_item_custom_label(snap, i) else { return "" }
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
            let preview: String = {
                guard let cStr = clipboard_snapshot_item_preview(snap, i) else { return label }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()
            let display = ClipboardItem.formatDisplayPreview(preview)
            return .text(
                entryId: id, timestamp: timestamp,
                customLabel: customLabel,
                label: label, sourceName: sourceName,
                sourceBundleId: sourceBundleId, preview: preview,
                displayPreview: display
            )
        case 1:
            let dbId = Int(clipboard_snapshot_get_image_db_id(snap, i))
            let w = Int(clipboard_snapshot_get_image_width(snap, i))
            let h = Int(clipboard_snapshot_get_image_height(snap, i))
            return .image(
                entryId: id, dbId: dbId, width: w, height: h,
                timestamp: timestamp, customLabel: customLabel,
                label: label, sourceName: sourceName, sourceBundleId: sourceBundleId
            )
        default:
            return nil
        }
    }

    func undoDepth() -> Int {
        Int(clipboard_undo_depth())
    }

    func undoEvictionPreview(entryId: Int) -> Int? {
        let n = Int(clipboard_undo_eviction_preview(UInt64(entryId)))
        return n < 0 ? nil : n
    }

    func undoLimit() -> Int64 {
        clipboard_get_undo_limit()
    }

    @discardableResult
    func setUndoLimit(_ limit: Int64) -> Bool {
        clipboard_set_undo_limit(limit) != 0
    }

    func checkPermission() -> Bool {
        return clipboard_check_permission() != 0
    }

    func openPreferences() {
        clipboard_open_preferences()
    }

    func restorePasteTargetFocus(force: Bool = false) {
        guard NSApp.isActive, let pid = pasteTargetPID else { return }
        if !force, let appDelegate = AppDelegate.shared,
           (appDelegate.hasVisibleAppWindow || appDelegate.isPresentingAppWindow) {
            debugLog("Suppressing focus restore: app has visible/presenting window")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        debugLog("Handing the foreground back to pid \(pid) after paste")
        app.activate()
    }

    func clearHistory() {
        guard clipboard_clear_history() != 0 else {
            debugLog("clearHistory: Rust-side clear failed (see Rust log); local state kept")
            return
        }
        clearThumbnailCache()
        count = 0
        items = []
        favoriteIds = []
        slotByEntryId = [:]
        syncQuickSlotTap()
        itemsGeneration &+= 1
        PasteQueueManager.shared.clear()
    }

    func trimOldestPercent(_ percent: Int) -> Int {
        let removed = Int(clipboard_trim_oldest_percent(Int32(percent)))
        if removed > 0 {
            DispatchQueue.main.async {
                self.refresh()
                PasteQueueManager.shared.pruneStaleEntries()
            }
        }
        return removed
    }

    func getCleanupThreshold() -> Int {
        Int(clipboard_get_cleanup_threshold())
    }

    func setCleanupThreshold(_ threshold: Int) {
        let clamped = max(100, min(10000, threshold))
        clipboard_set_cleanup_threshold(Int32(clamped))
        UserDefaults.standard.set(clamped, forKey: "CleanupThreshold")
        refresh()
    }

    func getStorageBreakdown() -> (text: Int64, image: Int64, undo: Int64)? {
        var text: Int64 = 0
        var image: Int64 = 0
        var undo: Int64 = 0
        guard clipboard_get_storage_breakdown(&text, &image, &undo) != 0 else { return nil }
        return (text, image, undo)
    }

    struct BackupInfo {
        let totalItems: Int
        let favoriteItems: Int
        let createdAt: Date
    }

    enum RestoreMode {
        case merge
        case overwrite
    }

    func exportBackup(to url: URL) throws -> Int {
        let count = url.path.withCString { path in
            clipboard_export_backup(path)
        }
        if count < 0 {
            throw NSError(domain: "CopyAttachBackup", code: Int(count), userInfo: [
                NSLocalizedDescriptionKey: "导出备份失败，请检查目标存储路径写入权限或可用空间。"
            ])
        }
        return Int(count)
    }

    func inspectBackup(at url: URL) throws -> BackupInfo {
        var totalItems: Int32 = 0
        var favItems: Int32 = 0
        var createdAtSec: UInt64 = 0

        let ret = url.path.withCString { path in
            clipboard_inspect_backup(path, &totalItems, &favItems, &createdAtSec)
        }
        if ret == 0 {
            throw NSError(domain: "CopyAttachBackup", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无法解析该备份文件，文件可能已损坏或非 CopyAttach 格式。"
            ])
        }

        let date = createdAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtSec)) : Date()
        return BackupInfo(
            totalItems: Int(totalItems),
            favoriteItems: Int(favItems),
            createdAt: date
        )
    }

    func restoreBackup(from url: URL, mode: RestoreMode) throws -> Int {
        var outFavCStr: UnsafeMutablePointer<CChar>? = nil
        let result: Int32

        switch mode {
        case .overwrite:
            result = url.path.withCString { path in
                clipboard_restore_backup_overwrite(path, &outFavCStr)
            }
        case .merge:
            result = url.path.withCString { path in
                clipboard_restore_backup_merge(path, &outFavCStr)
            }
        }

        if result < 0 {
            throw NSError(domain: "CopyAttachBackup", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "恢复备份失败，请检查备份文件是否完整有效。"
            ])
        }

        if let ptr = outFavCStr {
            let favStr = String(cString: ptr)
            clipboard_free_string(ptr)
            self.favoriteIds = Set(favStr.split(separator: ",").compactMap { Int($0) })
        }

        clearThumbnailCache()

        reloadItems()
        return Int(result)
    }
}
