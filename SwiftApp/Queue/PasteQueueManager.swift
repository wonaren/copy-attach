import AppKit
import Foundation
import Observation
import SwiftUI

/// Manages the sequential paste queue.
///
/// Workflow:
/// 1. Staging: In the history popup, user presses Cmd+C on rows to enqueue/toggle items.
/// 2. Launch: User presses Return, popup closes, queue starts dispensing via HUD.
/// 3. Dispensing: User repeatedly presses Cmd+V in target apps, items are pasted in sequence.
/// 4. Termination: Queue empties, Esc is pressed, or 15-minute inactivity watchdog triggers.
@Observable
@MainActor
final class PasteQueueManager {
    static let shared = PasteQueueManager()

    enum QueueStatus: Equatable {
        case idle
        case dispensing
    }

    /// Outcome of a `startDispensing` attempt. The caller owns the user-facing
    /// message (the popup can toast, the HUD cannot), so this type stays data.
    enum StartOutcome: Equatable {
        /// Dispensing began. `pruned` entries were dropped because they no
        /// longer exist in the history snapshot the popup was showing.
        case started(pruned: Int)
        /// The queue was already empty when Return was pressed.
        case emptyQueue
        /// Every queued entry had gone stale; the queue was emptied.
        case allEntriesStale
        /// `QueueEventTap` could not be created (Accessibility/Input Monitoring).
        case eventTapUnavailable
    }

    private(set) var status: QueueStatus = .idle
    private(set) var queueItems: [ClipboardItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var isFinished: Bool = false

    /// Transient HUD message shown when an item could not be pasted. Nil in the
    /// steady state.
    private(set) var skippedNotice: String?

    /// How many items were dropped because their entry id no longer resolved.
    /// Distinguishes "all pasted" from "all skipped as stale" in the HUD.
    private(set) var failedSkipCount: Int = 0

    /// Set when a batch dispatch stopped with items still queued. The next popup
    /// open consumes it and keeps the queue visible for one retry instead of
    /// applying the normal "a queue never outlives its list" clear.
    private(set) var pendingBatchRetry = false

    /// Delayed teardown task token to avoid race conditions
    @ObservationIgnored
    private var finishTask: Task<Void, Never>?

    /// Auto-clear token for `skippedNotice`
    @ObservationIgnored
    private var noticeTask: Task<Void, Never>?

    /// Auto-cancel watchdog timer (see `watchdogInterval`)
    @ObservationIgnored
    private var watchdogTimer: Timer?

    private init() {}

    // MARK: - Query Properties

    var hasItems: Bool {
        !queueItems.isEmpty
    }

    var totalCount: Int {
        queueItems.count
    }

    var currentItem: ClipboardItem? {
        guard currentIndex < queueItems.count else { return nil }
        return queueItems[currentIndex]
    }

    /// 1-based order of every queued item, derived from `queueItems` on demand.
    ///
    /// Deliberately NOT stored: a second copy of the ordering has to be rebuilt
    /// on every insert/remove/prune, and a missed rebuild silently mislabels the
    /// badges. The queue is a handful of items, so deriving it costs nothing —
    /// the list view derives it once per body pass.
    var orderMap: [Int: Int] {
        var map = [Int: Int](minimumCapacity: queueItems.count)
        for (idx, item) in queueItems.enumerated() {
            map[item.id] = idx + 1
        }
        return map
    }

    /// 1-based order index of an item in the queue (1 for the first queued item).
    func order(of item: ClipboardItem) -> Int? {
        guard !queueItems.isEmpty else { return nil }
        return queueItems.firstIndex { $0.id == item.id }.map { $0 + 1 }
    }

    /// Whether `item` is part of the staged set. Used by the drag path: dragging
    /// a queued row out of the popup sends the whole set, dragging anything else
    /// keeps the single-item behaviour.
    func isQueued(_ item: ClipboardItem) -> Bool {
        queueItems.contains { $0.id == item.id }
    }

    /// Drop the first `count` items after a batch dispatch has sent them, so the
    /// queue holds exactly what has NOT been delivered and a retry cannot paste
    /// the same entry twice.
    func removeDelivered(_ count: Int) {
        guard count > 0, !queueItems.isEmpty else { return }
        let n = min(count, queueItems.count)
        queueItems.removeFirst(n)
        debugLog("PasteQueueManager: batch removed \(n) delivered items, remaining=\(queueItems.count)")
    }

    /// Keep the staged remainder for one retry. Called when a dispatch stopped
    /// before delivering everything (target died, entry vanished, activation
    /// failed) so the next popup open does not silently clear the queue.
    func markPendingBatchRetry() {
        guard !queueItems.isEmpty else { return }
        pendingBatchRetry = true
        debugLog("PasteQueueManager: pending batch retry, remaining=\(queueItems.count)")
    }

    /// Consume the one-shot preserve flag when the popup mounts.
    func consumePendingBatchRetryOnOpen() -> Bool {
        guard pendingBatchRetry else { return false }
        pendingBatchRetry = false
        debugLog("PasteQueueManager: preserving \(queueItems.count) item(s) for retry")
        return true
    }

    // MARK: - Staging (Popup List)

    /// Toggle an item in or out of the queue (ordered by keypress sequence)
    func toggle(_ item: ClipboardItem) {
        if let existingIdx = queueItems.firstIndex(where: { $0.id == item.id }) {
            queueItems.remove(at: existingIdx)
            debugLog("PasteQueueManager: removed item \(item.id), remaining=\(queueItems.count)")
        } else {
            queueItems.append(item)
            debugLog("PasteQueueManager: enqueued item \(item.id), total=\(queueItems.count)")
        }
    }

    /// Remove an item by its entry ID from the queue if present.
    ///
    /// Automatically compacts the queue so that remaining items' 1-based order
    /// sequence (`orderMap`) is strictly consecutive without gaps, and the recycled
    /// numbers become available for newly marked items.
    func remove(id: Int) {
        guard let existingIdx = queueItems.firstIndex(where: { $0.id == id }) else { return }
        queueItems.remove(at: existingIdx)
        if currentIndex > existingIdx {
            currentIndex = max(0, currentIndex - 1)
        }
        debugLog("PasteQueueManager: removed item \(id), remaining=\(queueItems.count)")
    }

    /// User-level "end this queue" intent (Esc double-tap, the HUD's ✕, the
    /// hotkey summoning history). Same teardown as `clear()`; named separately so
    /// call sites read as intent rather than as state surgery.
    func cancel() {
        clear()
    }

    /// Full teardown of all queue state, event taps, and windows.
    func clear() {
        finishTask?.cancel()
        finishTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        resetWatchdog(active: false)
        QueueEventTap.shared.stop()
        PasteQueueHUDWindow.shared.dismiss()
        pendingBatchRetry = false

        guard !queueItems.isEmpty || status != .idle || isFinished else { return }
        queueItems.removeAll(keepingCapacity: true)
        currentIndex = 0
        isFinished = false
        skippedNotice = nil
        failedSkipCount = 0
        status = .idle
    }


    // MARK: - Dispensing (Target App Sequential Pasting)

    /// Commit the queue and start dispensing mode.
    ///
    /// Re-validates every queued entry against the snapshot the popup is showing
    /// before committing. Entry ids live in the mutable in-memory history
    /// (`src/backend.rs::new_entry_id`), so an id can stop resolving while the
    /// popup was closed — deleted entry, trimmed history, restored backup. The
    /// popup has a fresh snapshot at this moment (it is open and was reloaded on
    /// show), so pruning here is both accurate and cheap, and the user learns
    /// about the loss up front instead of mid-flow.
    @discardableResult
    func startDispensing(dismiss: () -> Void) -> StartOutcome {
        guard !queueItems.isEmpty else { return .emptyQueue }

        let pruned = pruneStaleEntries()
        guard !queueItems.isEmpty else {
            // Nothing survived validation: make the popup say so rather than
            // starting an empty HUD that can never paste anything.
            clear()
            return .allEntriesStale
        }

        finishTask?.cancel()
        finishTask = nil

        // Start event tap FIRST before dismissing popup
        guard QueueEventTap.shared.start() else {
            errorLog("PasteQueueManager: failed to start QueueEventTap — aborting dispensing")
            return .eventTapUnavailable
        }

        currentIndex = 0
        isFinished = false
        skippedNotice = nil
        failedSkipCount = 0
        status = .dispensing

        if pruned > 0 {
            failedSkipCount = pruned
            debugLog("PasteQueueManager: pruned \(pruned) stale entries at dispensing start")
        }

        // Dismiss popup first so it gives up Key Window status
        dismiss()

        // Show HUD
        PasteQueueHUDWindow.shared.show()
        if pruned > 0 {
            showSkippedNotice("已跳过 \(pruned) 个失效项")
        }
        resetWatchdog(active: true)
        debugLog("PasteQueueManager: started dispensing \(queueItems.count) items")
        return .started(pruned: pruned)
    }

    /// Drop queue entries whose id is absent from the current history snapshot.
    /// Returns how many were dropped.
    ///
    /// Never prunes against an empty snapshot: an unloaded list must not read as
    /// "everything vanished" and silently discard a queue the user built.
    @discardableResult
    func pruneStaleEntries() -> Int {
        let live = Set(ClipboardBackend.shared.items.map(\.id))
        guard !live.isEmpty else { return 0 }

        let before = queueItems.count
        queueItems.removeAll { !live.contains($0.id) }
        let dropped = before - queueItems.count
        if dropped > 0 {
            currentIndex = min(currentIndex, max(0, queueItems.count - 1))
        }
        return dropped
    }

    /// Paste the current item and advance the pointer.
    func pasteCurrent() {
        guard status == .dispensing, currentIndex < queueItems.count else { return }
        resetWatchdog(active: true)

        let item = queueItems[currentIndex]
        let entryId = UInt64(item.id)

        switch ClipboardBackend.shared.pasteEntryById(entryId) {
        case .pasted:
            advance()
            OnboardingGuide.shared.record(.queuePasted)
        case .keystrokeNotDelivered:
            // The payload IS on the pasteboard — retrying would paste the same
            // item twice, so advance and tell the user the keystroke did not
            // land (they can paste it by hand).
            errorLog("PasteQueueManager: keystroke not delivered for \(entryId) — advancing")
            showSkippedNotice("⌘V 未送达，该项已留在剪贴板")
            advance()
            OnboardingGuide.shared.record(.queuePasted)
        case .entryUnavailable:
            // A stall here is unrecoverable: the tap swallows ⌘V, so retrying can
            // never succeed and only Esc or the watchdog ends it. Skip and say so.
            errorLog("PasteQueueManager: entry \(entryId) unavailable — skipping stale item")
            withAnimation(AppleMotion.snappy) {
                failedSkipCount += 1
            }
            showSkippedNotice("该项已失效，已跳过")
            advance()
        }
    }

    /// Move the pointer forward, finishing the queue when it runs out.
    private func advance() {
        withAnimation(AppleMotion.smooth) {
            currentIndex += 1
        }

        if currentIndex >= queueItems.count {
            finish()
        }
    }

    /// Skip the current item without pasting it.
    func skipCurrent() {
        guard status == .dispensing, currentIndex < queueItems.count else { return }
        resetWatchdog(active: true)
        advance()
    }

    /// Briefly show a HUD note for an item that could not be pasted.
    private func showSkippedNotice(_ text: String) {
        withAnimation(AppleMotion.snappy) {
            skippedNotice = text
        }
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(AppleMotion.snappy) {
                self.skippedNotice = nil
            }
        }
    }

    /// Complete queue.
    ///
    /// The three fields around the finished phase are easy to confuse, so:
    /// `status` is the dispensing MODE (`.dispensing` only while the tap may
    /// still swallow ⌘V), `isFinished` is the 900 ms "done" banner phase, and
    /// `currentIndex` is the cursor. Finishing drops the mode as well — leaving
    /// `status == .dispensing` with a stopped tap was a lie the state machine
    /// could not tell apart from "still busy".
    private func finish() {
        isFinished = true
        status = .idle
        QueueEventTap.shared.stop()
        resetWatchdog(active: false)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, !Task.isCancelled, self.isFinished else { return }
            self.clear()
        }
    }

    /// Idle lifetime of a dispensing queue. The tap swallows ⌘V for as long as
    /// it runs, so this is a blast-radius bound, not a nicety: 15 minutes left a
    /// global keyboard trap alive long after the user moved on.
    private static let watchdogInterval: TimeInterval = 180

    private func resetWatchdog(active: Bool) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if active {
            // `Timer.scheduledTimer` only fires in .default mode: a menu or a
            // drag puts the run loop in .eventTracking, where the watchdog would
            // silently be skipped for exactly as long as the user holds it.
            // .common covers both (same pattern as HistoryPopupWindow's
            // closeGuaranteeTimer).
            let timer = Timer(timeInterval: Self.watchdogInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancel()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdogTimer = timer
        }
    }
}
