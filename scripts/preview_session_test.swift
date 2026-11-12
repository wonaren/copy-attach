import AppKit

private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<Int64> = []
    private var counts: [Int64: Int] = [:]
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)

    func block(_ ids: Int64...) {
        lock.withLock { blocked.formUnion(ids) }
    }

    func decode(_ id: Int64) {
        let shouldWait = lock.withLock {
            counts[id, default: 0] += 1
            return blocked.remove(id) != nil
        }
        if shouldWait {
            started.signal()
            precondition(finish.wait(timeout: .now() + 5) == .success)
        }
    }

    func count(_ id: Int64) -> Int {
        lock.withLock { counts[id, default: 0] }
    }

    func waitForStart() async {
        let result = await Task.detached { self.waitUntilStarted() }.value
        precondition(result == .success)
    }

    private func waitUntilStarted() -> DispatchTimeoutResult {
        started.wait(timeout: .now() + 5)
    }
}

private let probe = DecodeProbe()

func clipboard_decode_preview_by_db_id(_ id: Int64, _ maxPixel: Int32,
                                      _ length: UnsafeMutablePointer<Int32>,
                                      _ width: UnsafeMutablePointer<Int32>,
                                      _ height: UnsafeMutablePointer<Int32>,
                                      _ isGif: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer? {
    probe.decode(id)
    length.pointee = 4
    width.pointee = 1
    height.pointee = 1
    isGif.pointee = 0
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 16)
    ptr.initializeMemory(as: UInt8.self, repeating: 255, count: 4)
    return ptr
}

func clipboard_preview_buffer_release(_ ptr: UnsafeMutableRawPointer, _ length: Int32) {
    ptr.deallocate()
}

enum ClipboardBackend {
    static func getImageFullByDbId(_ id: Int) -> Data? { nil }
}

@main
struct PreviewSessionTest {
    @MainActor
    static func load(_ id: Int) async -> DecodedImage? {
        await ImageDecode.previewImageAsync(dbId: id, maxPixel: 800)
    }

    @MainActor
    static func main() async {
        for round in 0..<8 {
            let id = 100 + round * 10
            ImageDecode.beginPreviewSession()
            let first = await load(id)
            let cached = await load(id)
            precondition(first != nil && first === cached)
            precondition(probe.count(Int64(id)) == 1)
            ImageDecode.endPreviewSession()
            let closed = await load(id)
            precondition(closed == nil && probe.count(Int64(id)) == 1)
            ImageDecode.beginPreviewSession()
            let reopened = await load(id)
            precondition(reopened != nil && reopened !== first)
            precondition(probe.count(Int64(id)) == 2)
            ImageDecode.endPreviewSession()

            ImageDecode.beginPreviewSession()
            probe.block(Int64(id + 1), Int64(id + 2))
            let oldA = Task { await load(id + 1) }
            let oldB = Task { await load(id + 2) }
            await probe.waitForStart()
            await probe.waitForStart()
            var queuedStarted = false
            let queued = Task {
                queuedStarted = true
                return await load(id + 3)
            }
            while !queuedStarted { await Task.yield() }
            ImageDecode.endPreviewSession()
            ImageDecode.beginPreviewSession()
            probe.finish.signal()
            probe.finish.signal()
            let staleA = await oldA.value
            let staleB = await oldB.value
            let staleQueued = await queued.value
            precondition(staleA == nil && staleB == nil && staleQueued == nil)
            precondition(probe.count(Int64(id + 3)) == 0)
            let current = await load(id + 1)
            precondition(current != nil && probe.count(Int64(id + 1)) == 2)
            ImageDecode.endPreviewSession()

            ImageDecode.beginPreviewSession()
            probe.block(Int64(id + 4))
            let cancelled = Task { await load(id + 4) }
            await probe.waitForStart()
            cancelled.cancel()
            probe.finish.signal()
            let discarded = await cancelled.value
            precondition(discarded == nil)
            let retried = await load(id + 4)
            precondition(retried != nil && probe.count(Int64(id + 4)) == 2)
            ImageDecode.endPreviewSession()
        }
        print("PASS: 8 rounds of session eviction, stale completion, queued work and cancellation")
    }
}
