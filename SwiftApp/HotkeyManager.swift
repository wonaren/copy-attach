import AppKit
import Foundation
import Carbon

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
