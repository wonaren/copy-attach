import AppKit
import CoreGraphics

/// Intercepts Cmd+V while the paste queue is dispensing.
///
/// Installed on-demand when the user confirms a queue of items with Return,
/// and uninstalled immediately when the queue empties or the user cancels with Esc.
/// Does NOT run in the background when no queue is active.
///
/// Thread-safety: the run loop source is installed on the main run loop, so the
/// callback executes on the main thread — the same thread that mutates
/// `isRunning` (start/stop are called from @MainActor PasteQueueManager). The
/// `@unchecked Sendable` conformance only covers handing `self` to the C
/// callback through the opaque refcon, which is safe because the instance is a
/// process-lifetime singleton that is never deallocated.
final class QueueEventTap: @unchecked Sendable {
    static let shared = QueueEventTap()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// Two Escapes inside this window cancel a dispensing queue (see the Esc
    /// branch in the tap callback). One Escape is always passed to the app.
    private static let escapeDoubleTapWindow: UInt64 = 700_000_000

    /// Uptime of the previous bare Escape, 0 when none is pending.
    private var lastEscapeUptime: UInt64 = 0

    private init() {}

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        // Mask for keyDown events
        let mask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            // Auto-reenable if macOS temporarily disabled the tap
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

            // Defensive guard: if tap is not marked active, never intercept any keypress
            guard tapInstance.isRunning else {
                return Unmanaged.passUnretained(event)
            }

            // Provenance guard: CopyAttach's own synthetic Cmd+V is posted with
            // CGEventPostToPid (see src/macos.rs::simulate_cmd_v), and events
            // posted that way never reach a session tap at all — measured: a
            // session tap sees zero keyDowns from postToPid, while the same event
            // posted via CGEventPost(.cghidEventTap) arrives with
            // eventSourceUnixProcessID == our pid. So this branch normally never
            // fires; it exists so that a future change to the posting strategy
            // can never make the tap swallow CopyAttach's own keystroke.
            //
            // It must NOT be a time window. A window cannot tell our event from a
            // user's fast repeat, so it would pass a real ⌘V (pressed within the
            // window) straight to the target app — that app then pastes the
            // current clipboard again while the queue fails to advance, visibly
            // duplicating an item.
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Modifier matching is exact. Any modifier combination we do not own
            // belongs to the target app (⌥⌘V "paste and match style", ⌃⌘V, fn⌘V,
            // ⌥⇧⌘V …) and must pass through untouched — the old
            // "contains(.command) && !contains(.control)" test swallowed all of
            // them and pasted a plain item instead.
            let relevantModifiers: CGEventFlags = [
                .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn,
            ]
            let modifiers = flags.intersection(relevantModifiers)

            // Esc handling: ONE Escape is never stolen — it always belongs to the
            // target app (IME candidate cancel, dismissing a sheet, leaving insert
            // mode in vim). Only a second Escape inside the double-tap window
            // exits the queue. Narrowing this by "frontmost app == paste target"
            // does nothing, because the paste target pid itself follows the
            // frontmost app (measured: switching apps and pressing Esc cancelled
            // the queue anyway).
            if keyCode == 53 && modifiers.isEmpty {
                let now = DispatchTime.now().uptimeNanoseconds
                if tapInstance.lastEscapeUptime != 0,
                   now &- tapInstance.lastEscapeUptime < QueueEventTap.escapeDoubleTapWindow {
                    tapInstance.lastEscapeUptime = 0
                    DispatchQueue.main.async {
                        PasteQueueManager.shared.cancel()
                    }
                    return nil // swallow the second Esc
                }
                tapInstance.lastEscapeUptime = now
                return Unmanaged.passUnretained(event)
            }

            // Shift + Cmd + V (keyCode 9): skip current item
            if keyCode == 9 && modifiers == [.maskCommand, .maskShift] {
                DispatchQueue.main.async {
                    PasteQueueManager.shared.skipCurrent()
                }
                return nil
            }

            // Normal Cmd+V: sequential paste
            if keyCode == 9 && modifiers == .maskCommand {
                DispatchQueue.main.async {
                    PasteQueueManager.shared.pasteCurrent()
                }
                return nil // swallow physical key press
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
            // Disabling is not enough: an un-invalidated port stays registered with
            // the window server, so repeated start/stop cycles leak taps (and can
            // eventually make tapCreate fail). Invalidate before dropping the refs.
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
