import AppKit
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class PasteQueueManager {
    static let shared = PasteQueueManager()

    enum QueueStatus: Equatable {
        case idle
        case dispensing
    }

    enum StartOutcome: Equatable {
        case started(pruned: Int)
        case emptyQueue
        case allEntriesStale
        case eventTapUnavailable
    }

    private(set) var status: QueueStatus = .idle
    private(set) var queueItems: [ClipboardItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var isFinished: Bool = false

    private(set) var skippedNotice: String?

    private(set) var failedSkipCount: Int = 0

    private(set) var pendingBatchRetry = false

    @ObservationIgnored
    private var finishTask: Task<Void, Never>?

    @ObservationIgnored
    private var noticeTask: Task<Void, Never>?

    @ObservationIgnored
    private var watchdogTimer: Timer?

    private init() {}

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

    var orderMap: [Int: Int] {
        var map = [Int: Int](minimumCapacity: queueItems.count)
        for (idx, item) in queueItems.enumerated() {
            map[item.id] = idx + 1
        }
        return map
    }

    func order(of item: ClipboardItem) -> Int? {
        guard !queueItems.isEmpty else { return nil }
        return queueItems.firstIndex { $0.id == item.id }.map { $0 + 1 }
    }

    func isQueued(_ item: ClipboardItem) -> Bool {
        queueItems.contains { $0.id == item.id }
    }

    func removeDelivered(_ count: Int) {
        guard count > 0, !queueItems.isEmpty else { return }
        let n = min(count, queueItems.count)
        queueItems.removeFirst(n)
        debugLog("PasteQueueManager: batch removed \(n) delivered items, remaining=\(queueItems.count)")
    }

    func markPendingBatchRetry() {
        guard !queueItems.isEmpty else { return }
        pendingBatchRetry = true
        debugLog("PasteQueueManager: pending batch retry, remaining=\(queueItems.count)")
    }

    func consumePendingBatchRetryOnOpen() -> Bool {
        guard pendingBatchRetry else { return false }
        pendingBatchRetry = false
        debugLog("PasteQueueManager: preserving \(queueItems.count) item(s) for retry")
        return true
    }

    func toggle(_ item: ClipboardItem) {
        if let existingIdx = queueItems.firstIndex(where: { $0.id == item.id }) {
            queueItems.remove(at: existingIdx)
            debugLog("PasteQueueManager: removed item \(item.id), remaining=\(queueItems.count)")
        } else {
            queueItems.append(item)
            debugLog("PasteQueueManager: enqueued item \(item.id), total=\(queueItems.count)")
        }
    }

    func remove(id: Int) {
        guard let existingIdx = queueItems.firstIndex(where: { $0.id == id }) else { return }
        queueItems.remove(at: existingIdx)
        if currentIndex > existingIdx {
            currentIndex = max(0, currentIndex - 1)
        }
        debugLog("PasteQueueManager: removed item \(id), remaining=\(queueItems.count)")
    }

    func cancel() {
        clear()
    }

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

    @discardableResult
    func startDispensing(dismiss: () -> Void) -> StartOutcome {
        guard !queueItems.isEmpty else { return .emptyQueue }

        let pruned = pruneStaleEntries()
        guard !queueItems.isEmpty else {
            clear()
            return .allEntriesStale
        }

        finishTask?.cancel()
        finishTask = nil

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

        dismiss()

        PasteQueueHUDWindow.shared.show()
        if pruned > 0 {
            showSkippedNotice("已跳过 \(pruned) 个失效项")
        }
        resetWatchdog(active: true)
        debugLog("PasteQueueManager: started dispensing \(queueItems.count) items")
        return .started(pruned: pruned)
    }

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

    func pasteCurrent() {
        guard status == .dispensing, currentIndex < queueItems.count else { return }
        resetWatchdog(active: true)

        let item = queueItems[currentIndex]
        let entryId = UInt64(item.id)

        switch ClipboardBackend.shared.pasteEntryById(entryId) {
        case .pasted:
            advance()
            OnboardingGuide.shared.record(.queuePasted)
        case .copied:
            errorLog("PasteQueueManager: ClipboardOnly mode reached dispensing — stopping")
            showSkippedNotice("当前为仅复制模式，队列已停止")
            finish()
        case .keystrokeNotDelivered:
            errorLog("PasteQueueManager: keystroke not delivered for \(entryId) — advancing")
            showSkippedNotice("⌘V 未送达，该项已留在剪贴板")
            advance()
            OnboardingGuide.shared.record(.queuePasted)
        case .entryUnavailable:
            errorLog("PasteQueueManager: entry \(entryId) unavailable — skipping stale item")
            withAnimation(AppleMotion.snappy) {
                failedSkipCount += 1
            }
            showSkippedNotice("该项已失效，已跳过")
            advance()
        }
    }

    private func advance() {
        withAnimation(AppleMotion.smooth) {
            currentIndex += 1
        }

        if currentIndex >= queueItems.count {
            finish()
        }
    }

    func skipCurrent() {
        guard status == .dispensing, currentIndex < queueItems.count else { return }
        resetWatchdog(active: true)
        advance()
    }

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

    private static let watchdogInterval: TimeInterval = 180

    private func resetWatchdog(active: Bool) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if active {
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
