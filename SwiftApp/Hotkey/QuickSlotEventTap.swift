import AppKit
import CoreGraphics

enum QuickSlotKeyMap {
    private static let topRow: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
    private static let keypad: [Int64: Int] = [
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    static func slot(forKeyCode keyCode: UInt16) -> Int? {
        topRow[Int64(keyCode)] ?? keypad[Int64(keyCode)]
    }

    static func slot(forKeyCode keyCode: Int64) -> Int? {
        topRow[keyCode] ?? keypad[keyCode]
    }

    static func commandSides(rawFlags: UInt64, allowingShift: Bool = false) -> (left: Bool, right: Bool) {
        let command = rawFlags & 0x0010_0000 != 0
        let blockedModifiers: UInt64 = allowingShift ? 0x008C_0000 : 0x008E_0000
        guard command, rawFlags & blockedModifiers == 0 else { return (false, false) }
        let left = rawFlags & 0x0000_0008 != 0
        let right = rawFlags & 0x0000_0010 != 0
        return (left && !right, right && !left)
    }

    static func commandSides(rawFlags: UInt, allowingShift: Bool = false) -> (left: Bool, right: Bool) {
        commandSides(rawFlags: UInt64(rawFlags), allowingShift: allowingShift)
    }

    static func shiftYieldsDigit(_ event: CGEvent) -> Bool {
        guard let event = NSEvent(cgEvent: event) else { return false }
        return shiftYieldsDigit(event)
    }

    static func shiftYieldsDigit(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }
}

final class QuickSlotEventTap: @unchecked Sendable {
    static let shared = QuickSlotEventTap()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    var boundSlots: Set<Int> = []
    var popupOpen = false
    var isRecording = false
    var appIsFrontmost = false

    private var swallowedKeyCodes: Set<Int64> = []

    private init() {}

    func sync(boundSlots: Set<Int>, permissionGranted: Bool) {
        self.boundSlots = boundSlots
        if boundSlots.isEmpty || !permissionGranted {
            stop()
        } else {
            _ = start()
        }
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon = refcon {
                    Unmanaged<QuickSlotEventTap>.fromOpaque(refcon)
                        .takeUnretainedValue()
                        .reEnable()
                }
                return Unmanaged.passUnretained(event)
            }

            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let tapInstance = Unmanaged<QuickSlotEventTap>.fromOpaque(refcon).takeUnretainedValue()
            guard tapInstance.isRunning else {
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown || type == .keyUp else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if type == .keyUp {
                if tapInstance.swallowedKeyCodes.remove(keyCode) != nil {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }

            guard let slot = QuickSlotKeyMap.slot(forKeyCode: keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            let shiftHeld = event.flags.contains(.maskShift)
            if shiftHeld, !QuickSlotKeyMap.shiftYieldsDigit(event) {
                return Unmanaged.passUnretained(event)
            }
            let sides = QuickSlotKeyMap.commandSides(rawFlags: event.flags.rawValue, allowingShift: shiftHeld)
            guard sides.right else {
                return Unmanaged.passUnretained(event)
            }
            if tapInstance.popupOpen || tapInstance.isRecording || tapInstance.appIsFrontmost {
                return Unmanaged.passUnretained(event)
            }
            guard tapInstance.boundSlots.contains(slot) else {
                return Unmanaged.passUnretained(event)
            }

            tapInstance.swallowedKeyCodes.insert(keyCode)
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClipboardBackend.shared.pasteQuickSlot(slot)
                }
            }
            return nil
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
            errorLog("QuickSlotEventTap: CGEvent.tapCreate failed (check Accessibility permission)")
            return false
        }

        eventTap = tap
        swallowedKeyCodes.removeAll()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        debugLog("QuickSlotEventTap: started with slots \(boundSlots.sorted())")
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        swallowedKeyCodes.removeAll()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        debugLog("QuickSlotEventTap: stopped")
    }

    private func reEnable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            debugLog("QuickSlotEventTap: re-enabled after system throttle")
        }
    }
}
