import AppKit
import Foundation
import Observation
import os

/// Swift wrapper around the Rust copy_attach C FFI.
@MainActor
@Observable
class ClipboardBackend {
    static let shared = ClipboardBackend()

    var count: Int = 0
    var items: [ClipboardItem] = []
    var permissionGranted: Bool = false

    /// Monotonic generation of the visible data set (`items` + `favoriteIds`).
    /// Views memoize derived lists (filter + sort + day grouping) against it:
    /// recomputing those passes over up to 3000 rows on every body evaluation
    /// (selection moves, hover, scroll) is the popup's hottest transient
    /// allocation path. Every mutation site below bumps this counter, so a
    /// memo keyed on it can never serve stale data.
    private(set) var itemsGeneration: Int = 0

    private var timer: Timer?
    private var sourceAppObserver: NSObjectProtocol?
    private let reloadQueue = DispatchQueue(label: "com.copyattach.reload", qos: .userInitiated)
    /// Monotonic generation of reload requests. Read on the background
    /// reload queue (to skip stale snapshot builds) and bumped on the main
    /// actor — a lock keeps the two sides race-free.
    private let reloadGeneration = OSAllocatedUnfairLock(initialState: 0)
    private var lastImageEncodingCounter: UInt64 = 0
    private var lastHistoryRevision: UInt64 = 0
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        // Decoded thumbnails are ~360 KB each (300px RGBA). 10 MB keeps ~2-3
        // screens of rows cached for smooth scrolling without letting a large
        // image history pin tens of MB of decoded bitmaps; a re-decode on
        // scroll-back is a <300px PNG read + fast decode.
        c.totalCostLimit = 10 * 1024 * 1024  // 10 MB
        return c
    }()
    /// Delayed thumbnail-cache release after the popup closes. While the
    /// popup is open the cache makes scrolling smooth; once it has been closed
    /// for a while the decoded bitmaps are no longer visible and are released
    /// so they don't sit in physical memory across a long idle session.
    private var thumbnailCacheClearTask: Task<Void, Never>?

    var favoriteIds: Set<Int> = []

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
        // The favorites filter tab derives its list from `favoriteIds` —
        // invalidate any memoized display list.
        itemsGeneration &+= 1
    }

    private init() {
        permissionGranted = checkPermission()
        loadFavorites()
    }

    func start() -> Bool {
        // Apply the debug-logging preference BEFORE init: init-time diagnostics
        // (DB open, schema ensure, migration) are the ones most needed in a
        // release build; syncing afterwards would silently drop them.
        Self.syncDebugLogging()
        let result = clipboard_init()
        guard result != 0 else {
            print("[ClipboardBackend] init failed (result: \(result)) — Rust backend not available")
            return false
        }
        print("[ClipboardBackend] init result: \(result)")
        permissionGranted = checkPermission()

        // Restore saved cleanup threshold from UserDefaults.
        // Note: in stress-test builds, clipboard_init() already loads
        // with a higher limit, so no explicit reload is needed here.
        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        if saved >= 100 {
            clipboard_set_cleanup_threshold(Int32(saved))
        }
        syncIgnoreRules()

        // UI polling is driven by the popup lifecycle (setPopupVisible) — the
        // history list is only visible while the popup is open, so polling
        // with it closed is pure waste. Nothing is scheduled here.

        // Frontmost-app info for Rust's clipboard monitor (source attribution
        // + paste target pid). Event-driven via NSWorkspace activation
        // notifications instead of a 0.3s poll: each NSRunningApplication
        // property access goes through LaunchServices and a synchronous XPC
        // round-trip to launchservicesd — polling it 3×/s for hours left a
        // ~115 MB process-side LS cache accumulation (measured: 12万 XPC
        // calls over 10h, ~2KB nodes × 51k). App switches are rare; the
        // notification fires exactly when the source changes.
        sourceAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.updateSourceApp() }
        }
        // Seed with the current frontmost app (no notification on launch).
        updateSourceApp()

        refreshPermission()
        // One-time initial sync; live updates resume when the popup opens.
        refresh()

        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        thumbnailCacheClearTask?.cancel()
        thumbnailCacheClearTask = nil
        if let observer = sourceAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sourceAppObserver = nil
        }
        clipboard_cleanup()
    }

    /// Popup lifecycle hook: while the popup is visible its list must track
    /// new captures (0.5s poll of pure FFI atomics); with it closed there is
    /// nothing to refresh, so the poll is stopped entirely — the background
    /// app performs no UI polling at all.
    @MainActor
    func setPopupVisible(_ visible: Bool) {
        if visible {
            // Popup is visible again: keep the thumbnail cache warm and cancel
            // any pending delayed release scheduled by the previous close.
            thumbnailCacheClearTask?.cancel()
            thumbnailCacheClearTask = nil
            refreshPermission()
            refresh()
            guard timer == nil else { return }
            let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                MainActor.assumeIsolated { self.refresh() }
            }
            // Allow AppKit to coalesce this timer with other system timers /
            // display refresh work. A 100ms slack on a 500ms UI poll is
            // imperceptible but reduces idle wakeups while the popup is open.
            t.tolerance = 0.1
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            // Release unused SQLite page-cache memory back to the OS now that
            // the monitor is the only DB user and the popup will not search or
            // load thumbnails again until the next open. Run off the main
            // actor: the DB lock may briefly wait for a capture transaction.
            DispatchQueue.global(qos: .utility).async {
                _ = clipboard_shrink_db_memory()
            }
            scheduleThumbnailCacheClear()
        }
    }

    /// Release decoded thumbnails 60s after the popup closes. Re-opening the
    /// popup within that window cancels the release, so a quick toggle never
    /// pays a re-decode; after 60s the next open re-decodes <300px PNGs
    /// asynchronously (the same path as a cache miss today).
    private func scheduleThumbnailCacheClear() {
        thumbnailCacheClearTask?.cancel()
        thumbnailCacheClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearThumbnailCache()
        }
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

    /// Apply the persisted debug-logging preference as early as possible.
    /// If the user has never touched the setting, keep Rust's build-profile
    /// default (debug builds log, release builds do not).
    static func syncDebugLogging() {
        if UserDefaults.standard.object(forKey: "DebugLogging") != nil {
            clipboard_set_debug_logging(UserDefaults.standard.bool(forKey: "DebugLogging") ? 1 : 0)
        }
    }

    /// Persist and apply the debug-logging switch.
    func setDebugLogging(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "DebugLogging")
        clipboard_set_debug_logging(enabled ? 1 : 0)
    }

    /// Detect the current frontmost app and tell Rust about it. The pid is
    /// also the paste target for CGEventPostToPid, so it must stay the app
    /// the user was using before the popup opened — never this app itself.
    private func updateSourceApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            // When the preview window activates this agent app (so pinch
            // gestures are delivered), the frontmost app IS CopyAttach.
            // Overwriting the stored pid with our own would redirect paste
            // into this app, which has no paste target — keep the user's
            // previous app as the source/paste target instead.
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                return
            }
            let name = app.localizedName ?? "Unknown"
            let bundleId = app.bundleIdentifier ?? "unknown"
            let pid = Int32(app.processIdentifier)
            clipboard_set_source_app(name, bundleId, pid)
        }
    }

    /// Data poll: three pure FFI atomic reads + revision-gated reload. No
    /// system-framework calls, so the 0.5s popup-open poll is structurally
    /// allocation-free and cannot accumulate anything over time.
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
    }

    /// Explicit accessibility-permission check point (startup, popup open,
    /// settings open). Not polled in the background: AXIsProcessTrusted is a
    /// system call, and permission changes are rare user actions.
    func refreshPermission() {
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
        let gen = reloadGeneration.withLock { generation in
            generation &+= 1
            return generation
        }
        // Local copy of the lock struct: it wraps a shared underlying lock,
        // so the background queue can race the main actor without capturing
        // `self` into the @Sendable closure.
        let generationLock = reloadGeneration
        reloadQueue.async { [gen, generationLock] in
            // Several changes can queue reloads in a burst (e.g. consecutive
            // image Phase-2 completions). Skip building a full snapshot when
            // a newer request has already superseded this one; the result
            // would be discarded anyway.
            let stale = generationLock.withLock { $0 != gen }
            guard !stale else { return }

            // Packed path: Rust serializes the whole snapshot into one
            // allocation; the old per-row API allocated + freed one CString
            // per string field (9k-12k tiny allocations per 3000-row refresh).
            var packedLength: Int32 = 0
            guard let packed = clipboard_snapshot_packed_acquire(&packedLength),
                  packedLength > 0 else { return }
            defer { clipboard_free_bytes(packed, packedLength) }

            guard let newItems = PackedSnapshot.decodeItems(
                from: UnsafeRawPointer(packed),
                length: Int(packedLength)
            ) else {
                debugLog("Packed snapshot decode failed; skipping reload")
                return
            }

            DispatchQueue.main.async { [gen, weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    guard gen == self.reloadGeneration.withLock({ $0 }) else { return }
                    self.items = newItems
                    // New base data — invalidate memoized display lists.
                    self.itemsGeneration &+= 1
                }
            }
        }
    }

    // MARK: - Getters

    nonisolated static func getTextByEntryId(_ entryId: Int) -> String? {
        guard let cStr = clipboard_get_text_by_id(UInt64(entryId)) else { return nil }
        let str = String(cString: cStr)
        clipboard_free_string(cStr)
        return str
    }

    /// Case-insensitive substring search over label, source name, and full text
    /// (fields Swift no longer keeps for text entries). Returns the matched
    /// entry_ids; the caller unions these with its own date-label matches.
    /// Pure FFI, so the offline search thread can call it directly.
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

    /// Pure FFI fetch (no instance or main-actor state), so preview windows can
    /// load full images off the main thread via `Task.detached`.
    ///
    /// The Rust side hands over a buffer allocated by its global (system)
    /// allocator — i.e. `malloc` — with capacity pinned to `len`. `Data`
    /// takes ownership of that exact pointer with a custom deallocator that
    /// routes through `clipboard_free_bytes`, which marks the pages reusable
    /// before freeing (macOS otherwise leaves freed large malloc blocks in the
    /// process footprint). This is zero-copy, so a multi-MB full PNG is never
    /// duplicated across the FFI boundary. The len==0 case is routed through
    /// the same FFI free helper because `bytesNoCopy` with count 0 is not
    /// guaranteed to invoke the deallocator.
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

    /// Synchronous NSCache-only lookup — no IO, safe in body evaluation.
    /// Rows render already-decoded thumbnails instantly; cache misses go
    /// through `loadThumbnail`, which never blocks the main thread.
    func cachedThumbnail(dbId: Int) -> NSImage? {
        guard dbId != 0 else { return nil }
        return thumbnailCache.object(forKey: NSNumber(value: dbId))
    }

    /// Async full thumbnail load: NSCache hit, else the FFI read + PNG decode
    /// run off the main thread, and the result is cached before returning.
    /// The main thread never performs DB access or image decoding for rows.
    func loadThumbnail(dbId: Int) async -> NSImage? {
        guard dbId != 0 else { return nil }
        let key = NSNumber(value: dbId)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
            // Rust decode pipeline (see ImageDecode): every intermediate is
            // marked reusable and the delivered RGBA buffer is released via
            // `clipboard_preview_buffer_release` when the CGImage dies. The
            // old NSImage(data:) path used ImageIO, whose freed decode
            // buffers linger in the malloc footprint forever (measured: a
            // 180-image history session pinned ~40 MB of small-zone dirty
            // pages after one popup open, never reclaimed by closing the
            // popup or clearing the cache).
            ImageDecode.previewImage(dbId: dbId, maxPixel: 300)
        }.value
        guard let decoded else { return nil }
        // cost = decoded RGBA upper bound for a 300px-max-dimension thumbnail
        thumbnailCache.setObject(decoded.image, forKey: key, cost: 300 * 300 * 4)
        return decoded.image
    }

    /// Immediately release all cached thumbnails.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
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
            itemsGeneration &+= 1
            // Bump generation to discard any stale in-flight snapshot
            // that might still include the deleted item.
            reloadGeneration.withLock { $0 &+= 1 }
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
            itemsGeneration &+= 1
            reloadGeneration.withLock { $0 &+= 1 }
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

        itemsGeneration &+= 1
        reloadGeneration.withLock { $0 &+= 1 }
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
            let preview: String = {
                guard let cStr = clipboard_snapshot_item_preview(snap, i) else { return label }
                let s = String(cString: cStr)
                clipboard_free_string(cStr)
                return s
            }()
            return .text(
                entryId: id, text: label, timestamp: timestamp,
                label: label, sourceName: sourceName,
                sourceBundleId: sourceBundleId, preview: preview
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
        // Rust now also clears the undo stack (full-content payload) during a
        // clear, so release the Swift-side caches too: every thumbnail key is
        // an old db_id and is invalid after the DB rows are gone.
        clearThumbnailCache()
        // This method runs on the MainActor — update local state synchronously
        // so the UI never sees a stale list between the clear and the next
        // popup-open refresh.
        count = 0
        items = []
        itemsGeneration &+= 1
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

