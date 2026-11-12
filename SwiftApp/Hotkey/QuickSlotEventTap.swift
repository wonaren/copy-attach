import AppKit
import Carbon
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

    static var digitKeyCodes: [Int64] { Array(topRow.keys) + Array(keypad.keys) }

    static func shiftYieldsDigit(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }
}

final class QuickSlotEventTap: @unchecked Sendable {
    static let shared = QuickSlotEventTap()

    private let lock = NSLock()

    private var boundSlotsStorage: Set<Int> = []
    private var popupOpenStorage = false
    private var isRecordingStorage = false
    private var appIsFrontmostStorage = false
    private var swallowedKeyCodes: Set<Int64> = []
    private var shiftDigitKeys: [Int64: Bool] = [:]
    private var layoutObserver: NSObjectProtocol?

    private var eventTap: CFMachPort?
    private var activity: NSObjectProtocol?
    private var wanted = false

    var boundSlots: Set<Int> {
        get { lock.withLock { boundSlotsStorage } }
        set { lock.withLock { boundSlotsStorage = newValue } }
    }

    var popupOpen: Bool {
        get { lock.withLock { popupOpenStorage } }
        set { lock.withLock { popupOpenStorage = newValue } }
    }

    var isRecording: Bool {
        get { lock.withLock { isRecordingStorage } }
        set { lock.withLock { isRecordingStorage = newValue } }
    }

    var appIsFrontmost: Bool {
        get { lock.withLock { appIsFrontmostStorage } }
        set { lock.withLock { appIsFrontmostStorage = newValue } }
    }

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
        if let tap = lock.withLock({ eventTap }) {
            let newlyWanted = lock.withLock { () -> Bool in
                defer { wanted = true }
                return !wanted
            }
            if newlyWanted {
                beginActivity()
                debugLog("QuickSlotEventTap: enabled with slots \(boundSlots.sorted())")
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let instance = Unmanaged<QuickSlotEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return instance.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            errorLog("QuickSlotEventTap: CGEvent.tapCreate failed (check Accessibility permission)")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            errorLog("QuickSlotEventTap: failed to create run loop source")
            return false
        }

        lock.withLock {
            eventTap = tap
            wanted = true
            swallowedKeyCodes.removeAll()
        }
        lock.withLock { shiftDigitKeys = Self.shiftDigitKeyMap() }
        if layoutObserver == nil {
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.shiftDigitKeys = Self.shiftDigitKeyMap() }
            }
        }
        beginActivity()

        let thread = Thread { [self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            applyEnabledState()
            CFRunLoopRun()
        }
        thread.name = "QuickSlotEventTap"
        thread.qualityOfService = .userInteractive
        thread.start()

        debugLog("QuickSlotEventTap: started with slots \(boundSlots.sorted())")
        return true
    }

    func stop() {
        let tap = lock.withLock { () -> CFMachPort? in
            guard wanted else { return nil }
            wanted = false
            swallowedKeyCodes.removeAll()
            return eventTap
        }
        guard let tap else { return }
        if let layoutObserver {
            DistributedNotificationCenter.default().removeObserver(layoutObserver)
            self.layoutObserver = nil
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        endActivity()
        debugLog("QuickSlotEventTap: disabled")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            debugLog("QuickSlotEventTap: re-enabled after timeout")
            applyEnabledState()
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            scheduleReenableAfterSecureInput()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            let swallowed = lock.withLock { swallowedKeyCodes.remove(keyCode) != nil }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }

        guard let slot = QuickSlotKeyMap.slot(forKeyCode: keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        let shiftHeld = event.flags.contains(.maskShift)
        if shiftHeld, !(lock.withLock { shiftDigitKeys[keyCode] == true }) {
            return Unmanaged.passUnretained(event)
        }
        let sides = QuickSlotKeyMap.commandSides(rawFlags: event.flags.rawValue, allowingShift: shiftHeld)
        guard sides.right else {
            return Unmanaged.passUnretained(event)
        }

        let shouldHandle = lock.withLock { () -> Bool in
            guard !popupOpenStorage, !isRecordingStorage, !appIsFrontmostStorage,
                  boundSlotsStorage.contains(slot) else { return false }
            swallowedKeyCodes.insert(keyCode)
            return true
        }
        guard shouldHandle else {
            return Unmanaged.passUnretained(event)
        }

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

    private static func shiftDigitKeyMap() -> [Int64: Bool] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> [Int64: Bool] in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return [:]
            }
            var map: [Int64: Bool] = [:]
            for keyCode in QuickSlotKeyMap.digitKeyCodes {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    UInt32(shiftKey) >> 8,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                map[keyCode] = status == noErr && length == 1
                    && CharacterSet.decimalDigits.contains(UnicodeScalar(characters[0]) ?? " ")
            }
            return map
        }
    }

    private func applyEnabledState() {
        let (tap, enabled) = lock.withLock { (eventTap, wanted) }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    private func scheduleReenableAfterSecureInput() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.lock.withLock({ self.wanted }) else { return }
            if IsSecureEventInputEnabled() {
                self.scheduleReenableAfterSecureInput()
            } else {
                self.applyEnabledState()
                debugLog("QuickSlotEventTap: re-enabled after secure input ended")
            }
        }
    }

    private func beginActivity() {
        lock.withLock {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Global quick slot hotkeys"
            )
        }
    }

    private func endActivity() {
        let token = lock.withLock { () -> NSObjectProtocol? in
            defer { activity = nil }
            return activity
        }
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
    }
}
