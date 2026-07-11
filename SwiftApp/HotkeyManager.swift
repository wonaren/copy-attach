import AppKit
import Foundation
import Carbon

// MARK: - Hotkey Configuration

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt16
    var flags: UInt

    static var `default`: HotkeyConfig {
        // Default: ⌥⌘V (Option+Command+V)
        HotkeyConfig(keyCode: UInt16(kVK_ANSI_V),
                     flags: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue)
    }

    var displayString: String {
        var parts: [String] = []
        if flags & NSEvent.ModifierFlags.control.rawValue != 0 { parts.append("⌃") }
        if flags & NSEvent.ModifierFlags.option.rawValue != 0 { parts.append("⌥") }
        if flags & NSEvent.ModifierFlags.shift.rawValue != 0 { parts.append("⇧") }
        if flags & NSEvent.ModifierFlags.command.rawValue != 0 { parts.append("⌘") }

        if let char = keyCodeToCharacter(keyCode) {
            parts.append(char.uppercased())
        } else {
            parts.append("?")
        }
        return parts.joined()
    }

    /// Convert NSEvent modifier flags to Carbon modifier flags
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if flags & NSEvent.ModifierFlags.command.rawValue != 0 { mods |= UInt32(cmdKey) }
        if flags & NSEvent.ModifierFlags.option.rawValue != 0 { mods |= UInt32(optionKey) }
        if flags & NSEvent.ModifierFlags.control.rawValue != 0 { mods |= UInt32(controlKey) }
        if flags & NSEvent.ModifierFlags.shift.rawValue != 0 { mods |= UInt32(shiftKey) }
        return mods
    }

    private func keyCodeToCharacter(_ code: UInt16) -> String? {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_F): "f",
            UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_X): "x",
            UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_Q): "q",
            UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_R): "r",
            UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_6): "6",
            UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_7): "7",
            UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_8): "8", UInt16(kVK_ANSI_0): "0",
            UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_O): "o", UInt16(kVK_ANSI_U): "u",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_P): "p",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_ANSI_L): "l", UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_K): "k",
            UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Comma): ",",
            UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_Period): ".",
            UInt16(kVK_Tab): "Tab", UInt16(kVK_Space): "Space",
            UInt16(kVK_ANSI_Grave): "`", UInt16(kVK_Delete): "⌫", UInt16(kVK_Escape): "Esc",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
            UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
            UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_DownArrow): "↓", UInt16(kVK_UpArrow): "↑",
        ]
        return map[code]
    }
}

// MARK: - Global Hotkey Manager
//
// Uses two mechanisms for reliability:
// 1. Carbon RegisterEventHotKey (primary) - works with Accessibility permissions
// 2. NSEvent global monitor (fallback) - also needs Accessibility permissions
//
// Both require Accessibility permissions on modern macOS. If neither works,
// the app will prompt the user to grant permissions.

class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    private let defaultsKey = "CustomHotkey"

    @Published var config: HotkeyConfig {
        didSet {
            saveConfig()
            reregisterHotkeys()
        }
    }

    @Published var isRecording: Bool = false

    /// Callback triggered when the hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    // Carbon hotkey reference
    private var carbonHotKeyRef: EventHotKeyRef?

    // NSEvent global monitor
    private var nsEventMonitor: Any?

    // Local event monitor for recording hotkeys
    private var localEventMonitor: Any?

    // Carbon event handler ref (installed once)
    private static var eventHandlerRef: EventHandlerRef?

    private init() {
        debugLog("HotkeyManager init started")
        // Load saved config or use default
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.config = saved
            debugLog("Loaded saved hotkey config: \(config.displayString)")
        } else {
            self.config = .default
            debugLog("Using default hotkey config: \(config.displayString)")
        }

        // Install the Carbon event handler once
        Self.installCarbonEventHandler()

        // Register both hotkey mechanisms
        registerBoth()
        debugLog("HotkeyManager init completed")
    }

    deinit {
        unregisterBoth()
        removeLocalMonitor()
    }

    // MARK: - Persistence

    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            debugLog("Failed to save config: \(error)")
        }
    }

    // MARK: - Carbon Event Handler Setup (one-time)

    /// Install the Carbon event handler for hotkey events.
    private static func installCarbonEventHandler() {
        guard eventHandlerRef == nil else { return }

        let eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Create the C callback
        let callback: @convention(c) (
            EventHandlerCallRef?,
            EventRef?,
            UnsafeMutableRawPointer?
        ) -> OSStatus = { _, eventRef, _ in
            guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }

            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if err == noErr && hotKeyID.id == 1 {
                debugLog("Carbon hotkey pressed!")
                DispatchQueue.main.async {
                    debugLog("Carbon hotkey callback fired on main queue")
                    HotkeyManager.shared.onHotkeyPressed?()
                }
                return noErr
            }
            debugLog("Carbon hotkey event not matched: err=\(err) id=\(hotKeyID.id)")
            return OSStatus(eventNotHandledErr)
        }

        var spec = eventSpec
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            debugLog("InstallEventHandler failed: \(status)")
        } else {
            debugLog("Carbon event handler installed")
        }
    }

    // MARK: - Carbon Hotkey Registration

    private func registerCarbon() {
        unregisterCarbon()

        var id = EventHotKeyID()
        id.signature = OSType("CMgr".utf8.reduce(0) { ($0 << 8) | UInt32($1) })
        id.id = 1

        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            config.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            OptionBits(kEventPriorityStandard),
            &carbonHotKeyRef
        )

        if status == noErr {
            debugLog("Carbon hotkey registered: '\(config.displayString)'")
        } else {
            debugLog("Carbon RegisterEventHotKey failed: \(status)")
            carbonHotKeyRef = nil
        }
    }

    private func unregisterCarbon() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
    }

    // MARK: - NSEvent Monitor Registration

    private func registerNSEvent() {
        unregisterNSEvent()

        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }

            let keyCode = event.keyCode
            let allFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Only check the standard modifier keys
            let sigFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let pressedFlags = allFlags.intersection(sigFlags)

            let configFlags = NSEvent.ModifierFlags(rawValue: self.config.flags)
                .intersection(.deviceIndependentFlagsMask)
                .intersection(sigFlags)

            if keyCode == self.config.keyCode && pressedFlags == configFlags {
                debugLog("NSEvent hotkey match! keyCode=\(keyCode) flags=\(pressedFlags.rawValue)")
                DispatchQueue.main.async {
                    self.onHotkeyPressed?()
                }
            } else if keyCode == self.config.keyCode {
                debugLog("NSEvent keyCode matched but flags differed: eventFlags=\(pressedFlags.rawValue) configFlags=\(configFlags.rawValue)")
            }
        }

        if nsEventMonitor != nil {
            debugLog("NSEvent monitor registered")
        } else {
            debugLog("NSEvent monitor registration returned nil")
        }
    }

    private func unregisterNSEvent() {
        if let monitor = nsEventMonitor {
            NSEvent.removeMonitor(monitor)
            nsEventMonitor = nil
        }
    }

    // MARK: - Combined Registration

    private func registerBoth() {
        registerCarbon()
        registerNSEvent()
    }

    private func unregisterBoth() {
        unregisterCarbon()
        unregisterNSEvent()
    }

    private func reregisterHotkeys() {
        unregisterBoth()
        registerBoth()
    }

    // MARK: - Recording

    func startRecording() {
        isRecording = true

        // Install a local event monitor to capture key events while recording
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureKeyEvent(event)
            // Return nil to swallow the event during recording (prevent beep)
            return nil
        }
    }

    func stopRecording() {
        isRecording = false
        removeLocalMonitor()
    }

    private func removeLocalMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    /// Call this when a key event is captured during recording
    func captureKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }

        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let hasModifier = flags.contains(.command) || flags.contains(.option) ||
                          flags.contains(.control) || flags.contains(.shift)
        guard hasModifier else { return }

        let newConfig = HotkeyConfig(keyCode: keyCode, flags: flags.rawValue)
        if newConfig != config {
            config = newConfig
        }
        stopRecording()
    }

    /// Reset to default hotkey (⌥⌘V)
    func resetToDefault() {
        config = .default
    }
}

// MARK: - Debug Logging

func debugLog(_ message: String) {
    // Write to both stderr and a temp file for debugging
    let logLine = "[ClipboardManager] \(Date()) \(message)\n"
    fputs(logLine, stderr)
    
    // Also write to a file for easier access
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/copyattach_debug.log")) {
        handle.seekToEndOfFile()
        if let data = logLine.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        // Create the file
        try? logLine.write(toFile: "/tmp/copyattach_debug.log", atomically: true, encoding: .utf8)
    }
}
