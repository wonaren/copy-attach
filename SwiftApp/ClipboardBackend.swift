import AppKit
import Foundation
import Observation
import os

private let thumbnailDecodeSlots = DispatchSemaphore(value: 4)

/// The pixel rectangle a list-row thumbnail must fill to be drawn without
/// upscaling — mirrored from Rust's `THUMB_BOX_W_PT`/`THUMB_BOX_H_PT`
/// (`src/image.rs`), which size the *stored* blob; this sizes the *decode*.
/// Both describe the same row geometry: `.resizable().aspectRatio(.fit)` with
/// `.frame(maxHeight: 100)` inside the 500pt popup, so an image may span ~460pt
/// of width and 100pt of height. Changing one side without the other
/// reintroduces the upscale blur this exists to prevent.
struct RowThumbnailBox: Sendable, Equatable {
    /// The box's own width/height axes, **not** the source's long/short sides:
    /// a portrait source is bounded by the box height, not by a longer side.
    let widthPx: Int
    let heightPx: Int

    /// Box at a given display scale (1×/2×), resolved once per popup session.
    static func current(scale: CGFloat) -> RowThumbnailBox {
        let s = max(scale, 1)
        return RowThumbnailBox(widthPx: Int((460 * s).rounded()),
                               heightPx: Int((100 * s).rounded()))
    }

    /// Downsample `source` into the box, preserving aspect ratio and never
    /// upscaling.
    func makeThumbnail(from source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            // ImageIO takes a single "longest edge" bound, so the box fit has to
            // be expressed as whichever source dimension actually limits it
            // (see `bound`).
            kCGImageSourceThumbnailMaxPixelSize: bound(for: source)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Largest decoded long edge that still fits the box for `source`'s aspect
    /// ratio. Never exceeds the source's own long edge, so ImageIO cannot upscale.
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

    /// Upper bound on a user-authored remark, in Unicode scalars. Mirrors Rust's
    /// `MAX_CUSTOM_LABEL_SCALARS` (the FFI rejects anything longer); the remark
    /// travels in every packed snapshot, so it must stay a bounded payload.
    /// `nonisolated` so AppKit text-field delegates can read it off the actor.
    nonisolated static let maxCustomLabelScalars = 200

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
    /// The app the user was working in before our panels took over.
    private var pasteTargetPID: pid_t?
    /// Bundle identifier of that same app, kept in lockstep with
    /// `pasteTargetPID`. The popup decides the drag flavour from it: rich-text
    /// editors (思源笔记, Typora) only accept a drop carrying `text/html`, while
    /// VS Code's chat input only inserts text when `text/html` is absent. One
    /// pasteboard cannot satisfy both, so the frontmost app at popup time picks
    /// the representation set.
    private(set) var sourceAppBundleID: String?
    private var lastImageEncodingCounter: UInt64 = 0
    private var lastHistoryRevision: UInt64 = 0
    private let thumbnailCache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        // Cost is the real decoded size (~2 KB to ~700 KB, median ~255 KB).
        // The old code charged a flat 160×160×4 = 100 KB, so 4 MB held ~40
        // thumbnails. Charging real pixels dropped that to ~13 images — and the
        // live corpus packs 13 images into a single 20-row window (4.08 MB), so
        // every decode evicted a thumbnail still on screen. Arrow-key scrolling
        // then re-decoded and re-flashed the placeholder row — whose "photo" /
        // "desktopcomputer" glyphs are exactly the icons seen blinking. Measured
        // with NSCache's own eviction over the real corpus (not a model), one
        // traversal costs 442-5416 decodes at 4 MB (the range is how far
        // LazyVStack pre-materializes) vs 141 at 8 MB — i.e. ~one per image.
        // (NSCache does honor totalCostLimit — measured 4 MB/300 KB retained
        // exactly 13 objects — so this is a hard bound, not a soft hint.)
        //
        // 8 MB is the measured knee: it clears the densest live window (a
        // 40-row span peaks at 5.85 MB, a 20-row one at 4.08 MB), so arrow-key
        // scrolling never evicts an image still on screen. Going to 12/16 MB
        // buys only ~5% more hits for a higher ceiling, so it stops here and
        // stays well below the 41 MB full corpus — a bound, not "cache
        // everything".
        c.countLimit = 120
        c.totalCostLimit = 8 * 1024 * 1024  // 8 MB
        return c
    }()
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
        // Single choke point for every favorite path (shortcut, context menu).
        OnboardingGuide.shared.record(.favorited)
    }

    private init() {
        permissionGranted = checkPermission()
        loadFavorites()
    }

    enum StartResult { case started, retryable, corruptDatabase }

    func start() -> StartResult {
        // Apply the debug-logging preference BEFORE init: init-time diagnostics
        // (DB open, schema ensure, migration) are the ones most needed in a
        // release build; syncing afterwards would silently drop them.
        Self.syncDebugLogging()
        let result = clipboard_init()
        if result == -1 {
            print("[ClipboardBackend] init failed: database corrupt")
            return .corruptDatabase
        }
        guard result != 0 else {
            print("[ClipboardBackend] init failed (result: \(result)) — Rust backend not available")
            return .retryable
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

        return .started
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        clearThumbnailCache()
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
            // Keep decoded thumbnails warm for the duration of this popup session.
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
                if clipboard_shrink_db_memory() == 0 {
                    debugLog("shrink_db_memory failed (see Rust log)")
                }
            }
            clearThumbnailCache()
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
        let ignoreSensitive = UserDefaults.standard.object(forKey: "IgnoreSensitiveClipboard") as? Bool ?? true
        let result = payload.withCString {
            clipboard_set_ignore_rules($0, ignoreText ? 1 : 0, ignoreImages ? 1 : 0, Int32(minimum), ignoreSensitive ? 1 : 0)
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
            pasteTargetPID = app.processIdentifier
            sourceAppBundleID = bundleId
            clipboard_set_source_app(name, bundleId, pid)
        }
    }

    // MARK: - Drag flavour (plain vs rich text)

    /// UserDefaults key for the apps that need the rich-text drag set.
    static let richTextDragAppsDefaultsKey = "RichTextDragAppBundleIDs"

    /// Apps known to reject a plain-text drop and require `text/html`.
    /// Applied only until the user edits the list (the edit then persists an
    /// explicit array, including an empty one).
    static let defaultRichTextDragApps = ["org.b3log.siyuan", "abnerworks.Typora"]

    /// Bundle identifiers whose drags must carry HTML/RTF instead of plain text.
    static var richTextDragAppBundleIDs: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: richTextDragAppsDefaultsKey)
                ?? defaultRichTextDragApps
        }
        set {
            UserDefaults.standard.set(newValue, forKey: richTextDragAppsDefaultsKey)
        }
    }

    /// Whether the app the popup was opened over needs the rich-text drag set.
    var sourceAppNeedsRichTextDrag: Bool {
        guard let bundleId = sourceAppBundleID else { return false }
        return Self.richTextDragAppBundleIDs.contains(bundleId)
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
            // Permission newly granted:
            // 1. Re-register global hotkeys so shortcuts work immediately
            HotkeyManager.shared.reregisterHotkeys()
            // 2. Bring settings window to front so the user sees the updated "已授权" state
            // without having to manually switch back after closing System Settings.
            AppDelegate.shared?.focusSettingsWindow()
        }
    }

    private func reloadItems() {
        let gen = reloadGeneration.withLock { generation in
            generation &+= 1
            return generation
        }
        // Local copy of the lock struct: it wraps a shared underlying lock,
        // so the background queue can race the main actor without reaching
        // back through `self` for the generation. `self` is captured weakly
        // (matching the inner hop to main) so a queued reload never keeps the
        // backend alive, and the outer/inner captures agree in ownership.
        let generationLock = reloadGeneration
        reloadQueue.async { [gen, generationLock, weak self] in
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

    /// Decode off the main actor with a hard concurrency bound, resizing the
    /// stored blob down to the row's **display box** at the live screen scale.
    ///
    /// The box is a rectangle, not a single "longest edge" cap. The row renders
    /// an image with `.resizable().aspectRatio(.fit).frame(maxHeight: 100)` in a
    /// 500pt popup, so a flat image spans ~460pt of width while a screenshot is
    /// bounded by the 100pt height. A fixed 160px longest-edge crop used to
    /// satisfy neither: a 3000×100 panorama decoded to 160×5 and was then drawn
    /// ~5× larger, which is the "the flatter, the blurrier" artifact. Sizing both
    /// sides against the box means the decoded pixels match what is drawn.
    ///
    /// Off-main and cached-independent (same dbId, same box) for the popup's
    /// lifetime. ImageIO's resident cache stays disabled so no unmapped dirty
    /// pages accumulate.
    private nonisolated static func decodeThumbnail(dbId: Int, box: RowThumbnailBox) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                while thumbnailDecodeSlots.wait(timeout: .now() + 0.05) == .timedOut {
                    if Task.isCancelled {
                        continuation.resume(returning: nil)
                        return
                    }
                }
                defer { thumbnailDecodeSlots.signal() }
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                autoreleasepool {
                    var len: Int32 = 0
                    guard let ptr = clipboard_get_image_thumb_by_db_id(Int64(dbId), &len), len > 0 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    defer { clipboard_free_bytes(ptr, len) }
                    let data = Data(bytesNoCopy: ptr, count: Int(len), deallocator: .none)

                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let cgThumb = box.makeThumbnail(from: source)
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

    /// Async full thumbnail load: NSCache hit, else the FFI read + PNG decode
    /// run off the main thread, and the result is cached before returning.
    /// The main thread never performs DB access or image decoding for rows.
    func loadThumbnail(dbId: Int, box: RowThumbnailBox) async -> NSImage? {
        guard dbId != 0, !Task.isCancelled else { return nil }
        let key = NSNumber(value: dbId)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = await Self.decodeThumbnail(dbId: dbId, box: box) else { return nil }
        guard !Task.isCancelled else { return nil }
        // Cost is the real decoded size, not a fixed point-value guess: a flat
        // image in the box is 920×20 (~74 KB) while a screenshot is 356×200
        // (~285 KB). Charging them the same made the 4 MB cap meaningless.
        let px = image.size.width * image.size.height
        thumbnailCache.setObject(image, forKey: key, cost: Int(px) * 4)
        return image
    }

    /// Immediately release all cached thumbnails.
    func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
    }

    func setCustomLabel(entryId: Int, label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mirrors Rust's MAX_CUSTOM_LABEL_SCALARS. The input field already caps
        // typing/pasting; this guard turns any bypass into an explicit failure
        // instead of a silent one.
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
            // Rust logs the concrete reason (unknown id, missing row, DB error).
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

    /// Two-phase paste used by the popup: write the pasteboard, run
    /// `dismiss`, then post the paste keystroke.
    ///
    /// The ordering is load-bearing. `dismiss` closes the popup, and only
    /// `close()` resigns its key status; posting the keystroke before that
    /// leaves the panel as the key window, which made WeChat intermittently
    /// drop short-text pastes (measured via PASTEDIAG: `popupKey=true` on
    /// every paste). Returns true when the pasteboard was written — the
    /// keystroke is best-effort on top.
    @discardableResult
    func selectAndPasteDismissingPopup(at index: Int, asPath: Bool = false, dismiss: () -> Void) -> Bool {
        guard index < items.count else { return false }
        let entryId = UInt64(items[index].id)
        let pid = clipboard_prepare_paste_by_id(entryId, asPath)
        guard pid > 0 else { return false }
        // History order changed (selected item moved to top) — force UI refresh
        reloadItems()
        // The popup must stop being key before the keystroke is posted.
        dismiss()
        _ = clipboard_send_paste(pid)
        return true
    }

    func selectAndPaste(at index: Int, asPath: Bool = false) -> Bool {
        guard index < items.count else { return false }
        let entryId = UInt64(items[index].id)
        let result = (asPath
            ? clipboard_select_and_paste_as_path_by_id(entryId)
            : clipboard_select_and_paste_by_id(entryId)) != 0
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

    /// Hand the foreground back to the app the user was working in.
    ///
    /// Opening the preview forces a real `NSApp.activate` — pinch gestures are
    /// only delivered to the frontmost app — and the system never hands that
    /// back on its own. Without this the paste still lands (Cmd+V is posted to
    /// the target's pid) but the app stays in the background, so the content
    /// arrives while the caret does not return to the field being edited.
    ///
    /// No-op unless this app actually took the foreground: the normal path uses
    /// non-activating panels and never becomes active, so nothing is stolen.
    func restorePasteTargetFocus() {
        guard NSApp.isActive, let pid = pasteTargetPID else { return }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        debugLog("Handing the foreground back to pid \(pid) after paste")
        app.activate()
    }

    func clearHistory() {
        guard clipboard_clear_history() != 0 else {
            debugLog("clearHistory: Rust-side clear failed (see Rust log); local state kept")
            return
        }
        // Rust also cleared the undo stack (full-content payload) during a
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

