import Foundation

/// A bounded async permit pool for expensive decodes.
///
/// Why not `DispatchSemaphore`: Swift 6 rejects `wait()` from an async context,
/// because blocking a cooperative thread while awaiting a slot can starve the
/// pool that the awaited work needs. This gate suspends the caller instead, so a
/// queued decode costs no thread, and a task cancelled while queued does not
/// occupy a slot.
///
/// Accounting, stated so it can be checked by reading: `holders` counts permits
/// that some Ticket is responsible for releasing. Waiters are NOT counted — they
/// hold nothing until a release hands one over. `release()` therefore either
/// transfers its permit to the head waiter (count unchanged, exactly one Ticket
/// exists on either side of the handover) or, with no waiter, decrements. A
/// waiter that wakes up has necessarily been handed a permit by a `release()`,
/// because that is the only thing that resumes one — so the cancelled-while-
/// queued path must (and does) give it straight back.
actor PreviewDecodeGate {
    private let limit: Int
    /// Permits owned by a live `Ticket`.
    private var holders = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0, "a gate with no permits would deadlock every caller")
        self.limit = limit
    }

    /// Acquire a permit, or return nil when this task was cancelled while queued
    /// (the caller must then skip the work).
    func acquire() async -> Ticket? {
        if Task.isCancelled { return nil }
        if holders < limit {
            holders += 1
            return Ticket(gate: self)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // Waking means a release() handed us its permit.
        if Task.isCancelled {
            release()
            return nil
        }
        return Ticket(gate: self)
    }

    /// Return a permit: hand it to the next waiter, else drop the count.
    func release() {
        if waiters.isEmpty {
            holders -= 1
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }

    /// Permits currently owned by a Ticket. Exposed for the unit test that proves
    /// the count cannot drift.
    var heldCount: Int { holders }

    /// Opaque permit. A second release must not return the permit twice.
    final class Ticket: @unchecked Sendable {
        private let gate: PreviewDecodeGate
        private let lock = NSLock()
        private var isReleased = false
        init(gate: PreviewDecodeGate) { self.gate = gate }
        func release() {
            lock.lock()
            if isReleased {
                lock.unlock()
                return
            }
            isReleased = true
            lock.unlock()
            let gate = self.gate
            Task { await gate.release() }
        }
    }
}
