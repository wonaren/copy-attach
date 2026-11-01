import AppKit
import CoreGraphics

final class QueueEventTap: @unchecked Sendable {
    static let shared = QueueEventTap()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    private static let escapeDoubleTapWindow: UInt64 = 700_000_000

    private var lastEscapeUptime: UInt64 = 0

    private init() {}

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    let tapInstance = Unmanaged<QueueEventTap>.fromOpaque(refcon).takeUnretainedValue()
                    tapInstance.reEnable()
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let tapInstance = Unmanaged<QueueEventTap>.fromOpaque(refcon).takeUnretainedValue()

            guard tapInstance.isRunning else {
                return Unmanaged.passUnretained(event)
            }

            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            let relevantModifiers: CGEventFlags = [
                .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
            ]
            let modifiers = flags.intersection(relevantModifiers)

            if keyCode == 53 && modifiers.isEmpty {
                let now = DispatchTime.now().uptimeNanoseconds
                if tapInstance.lastEscapeUptime != 0,
                   now &- tapInstance.lastEscapeUptime < QueueEventTap.escapeDoubleTapWindow {
                    tapInstance.lastEscapeUptime = 0
                    DispatchQueue.main.async {
                        PasteQueueManager.shared.cancel()
                    }
                    return nil
                }
                tapInstance.lastEscapeUptime = now
                return Unmanaged.passUnretained(event)
            }

            if keyCode == 9 && modifiers == [.maskCommand, .maskShift] {
                DispatchQueue.main.async {
                    PasteQueueManager.shared.skipCurrent()
                }
                return nil
            }

            if keyCode == 9 && modifiers == .maskCommand {
                DispatchQueue.main.async {
                    PasteQueueManager.shared.pasteCurrent()
                }
                return nil
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else {
            errorLog("QueueEventTap: CGEvent.tapCreate failed (check Accessibility permission)")
            return false
        }

        eventTap = tap
        lastEscapeUptime = 0
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        debugLog("QueueEventTap: started successfully")
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        debugLog("QueueEventTap: stopped")
    }

    private func reEnable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            debugLog("QueueEventTap: re-enabled after system throttle")
        }
    }
}
