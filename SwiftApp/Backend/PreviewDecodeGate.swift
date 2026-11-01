import Foundation

actor PreviewDecodeGate {
    private let limit: Int
    private var holders = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0, "a gate with no permits would deadlock every caller")
        self.limit = limit
    }

    func acquire() async -> Ticket? {
        if Task.isCancelled { return nil }
        if holders < limit {
            holders += 1
            return Ticket(gate: self)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        if Task.isCancelled {
            release()
            return nil
        }
        return Ticket(gate: self)
    }

    func release() {
        if waiters.isEmpty {
            holders -= 1
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }

    var heldCount: Int { holders }

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
