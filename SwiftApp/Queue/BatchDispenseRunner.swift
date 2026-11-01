import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class BatchDispenseRunner {
    static let shared = BatchDispenseRunner()

    enum Phase: Equatable {
        case idle
        case running(sent: Int, total: Int)
        case finished(sent: Int, total: Int, notice: String?)
    }

    private(set) var phase: Phase = .idle

    private static let dropSettleNanos: UInt64 = 250_000_000

    private static let interItemGapNanos: UInt64 = 150_000_000

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    @ObservationIgnored private var userCancelled = false

    private init() {}

    func start(items: [ClipboardItem], targetPID: Int32, batchSize: Int) {
        guard !items.isEmpty, targetPID > 0, batchSize > 1 else { return }
        guard !isRunning else {
            errorLog("BatchDispense: start ignored; a batch is already running")
            return
        }
        teardownTask?.cancel()
        userCancelled = false
        phase = .running(sent: 0, total: batchSize)
        BatchDispenseHUDWindow.shared.show()
        task = Task { @MainActor [weak self] in
            await self?.run(items: items, targetPID: targetPID, batchSize: batchSize)
        }
    }

    func cancel() {
        userCancelled = true
        debugLog("BatchDispense: cancel requested")
        task?.cancel()
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private func run(items: [ClipboardItem], targetPID: Int32, batchSize: Int) async {
        var sent = 0
        var notice: String?

        if await wait(Self.dropSettleNanos) {
            for item in items {
                if Task.isCancelled {
                    notice = "已取消"
                    break
                }
                switch ClipboardBackend.shared.pasteEntryById(
                    UInt64(item.id),
                    targetPID: targetPID,
                    refreshAfter: false,
                    perfName: "paste.batch_item"
                ) {
                case .pasted:
                    sent += 1
                    phase = .running(sent: sent, total: batchSize)
                case .copied:
                    notice = "当前为仅复制模式，无法批量发送"
                case .keystrokeNotDelivered:
                    notice = "第 \(sent + 1) 条未送达"
                case .entryUnavailable:
                    notice = "第 \(sent + 1) 条已失效"
                }
                if notice != nil { break }
                if sent < batchSize, !(await wait(Self.interItemGapNanos)) {
                    notice = "已取消"
                    break
                }
            }
        } else {
            notice = "已取消"
        }

        finish(sent: sent, total: batchSize, notice: notice)
    }

    private func wait(_ nanos: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanos)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func finish(sent: Int, total: Int, notice: String?) {
        task = nil
        PasteQueueManager.shared.removeDelivered(sent)
        let remaining = PasteQueueManager.shared.totalCount
        var finalNotice = notice
        if !userCancelled, sent < total, remaining > 0 {
            PasteQueueManager.shared.markPendingBatchRetry()
            finalNotice = "\(notice ?? "已中止") · 剩余 \(remaining) 条"
        }
        ClipboardBackend.shared.reloadItems()
        phase = .finished(sent: sent, total: total, notice: finalNotice)
        debugLog("BatchDispense: finished sent=\(sent)/\(total) remaining=\(remaining) notice=\(finalNotice ?? "none")")

        let hold: UInt64 = finalNotice == nil ? 900_000_000 : 2_500_000_000
        teardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: hold)
            guard let self, !Task.isCancelled else { return }
            self.phase = .idle
            BatchDispenseHUDWindow.shared.dismiss()
        }
    }
}

@Observable
@MainActor
final class BatchHUDNotice {
    static let shared = BatchHUDNotice()
    private(set) var text: String?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String) {
        debugLog("BatchHUDNotice: \(text)")
        self.text = text
        BatchDispenseHUDWindow.shared.show()
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.text = nil
            if BatchDispenseRunner.shared.phase == .idle {
                BatchDispenseHUDWindow.shared.dismiss()
            }
        }
    }
}
