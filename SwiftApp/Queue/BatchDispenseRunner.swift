import AppKit
import Foundation
import Observation

/// Drives the "rest of the batch" after a batch drag has landed its first item.
///
/// Why keystrokes instead of more pasteboard items: a multi-item text drop is
/// only honoured by *some* receivers, and the ones that take just the first
/// item fail silently — the user cannot tell which of their N entries arrived.
/// A paced keystroke either lands (and `pasteEntryById` says so) or is reported.
///
/// Pacing is not cosmetic. The drop's own insertion is performed by the
/// receiving app while the mouse-up is being processed; a synthesized ⌘V that
/// arrives first gets inserted ahead of it and the batch lands out of order.
/// `dropSettleNanos` covers that window, `interItemGapNanos` keeps two pastes
/// from collapsing into one.
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

    /// Time from the drop to the first synthesized ⌘V. Starting value, not a
    /// measured optimum: the ordering gate (10 consecutive runs) decides
    /// whether it has to grow.
    private static let dropSettleNanos: UInt64 = 250_000_000

    /// Gap between two synthesized pastes.
    private static let interItemGapNanos: UInt64 = 150_000_000

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    /// Set by `cancel()`. A user cancel discards the remainder (the popup that
    /// caused it is about to clear the queue anyway); a failure keeps it for a
    /// one-shot retry.
    @ObservationIgnored private var userCancelled = false

    private init() {}

    /// `items` is everything to send; the drag payload itself carries no content.
    func start(items: [ClipboardItem], targetPID: Int32, batchSize: Int) {
        guard !items.isEmpty, targetPID > 0, batchSize > 1 else { return }
        // A batch owns the queue while it runs. The UI cannot start a second one
        // (only the popup starts a batch, and opening it cancels this one), so an
        // overlapping start is a programming error, not a race to win.
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

    /// Stop at the next step boundary. Delivered items still leave the queue
    /// (see `finish`); the user cancel does not preserve the remainder.
    func cancel() {
        userCancelled = true
        debugLog("BatchDispense: cancel requested")
        task?.cancel()
    }

    /// True from the first scheduled paste until `finish`. Callers use this
    /// rather than `phase != .idle`: the `.finished` phase still holds a visible
    /// HUD but has no work left to cancel.
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
                case .keystrokeNotDelivered:
                    // The payload is on the pasteboard but never arrived. The
                    // remaining items would hit the same wall; stop and report
                    // instead of marching on and losing track of what landed.
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

    /// Sleep that reports whether it ran to completion (false when cancelled).
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
        // The queue *is* the selection: whatever has been sent leaves it, so a
        // retry sends exactly the remainder. A full batch empties the queue.
        PasteQueueManager.shared.removeDelivered(sent)
        let remaining = PasteQueueManager.shared.totalCount
        var finalNotice = notice
        if !userCancelled, sent < total, remaining > 0 {
            // Keep the staged remainder for one retry; the next popup open
            // consumes the flag instead of clearing the queue.
            PasteQueueManager.shared.markPendingBatchRetry()
            finalNotice = "\(notice ?? "已中止") · 剩余 \(remaining) 条"
        }
        // Each item refreshed the list on its own in the single-paste path;
        // one refresh at the end avoids N packed-snapshot decodes (6–15 ms
        // each on a 478-row list) inside a keystroke sequence.
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

/// Transient HUD messages for a batch that never started (no permission, drop
/// target not frontmost). Kept apart from the runner's `phase` because there is
/// no progress to report in those cases — only a reason.
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
