import AppKit
import Foundation
import Carbon
import Observation

@MainActor
@Observable
class HotkeyManager {
    static let shared = HotkeyManager()

    private let defaultsKey = "CustomHotkey"

    var config: HotkeyConfig {
        didSet {
            saveConfig()
            reregisterHotkeys()
        }
    }

    var isRecording: Bool = false

    var onHotkeyPressed: (() -> Void)?

    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonRetryAttempts = 0
    private var carbonRetryTask: Task<Void, Never>?
    private static let carbonRetryMax = 5

    private var nsEventMonitor: Any?

    private var localEventMonitor: Any?

    private static var eventHandlerRef: EventHandlerRef?

    private init() {
        debugLog("HotkeyManager init started")
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.config = saved
            debugLog("Loaded saved hotkey config: \(config.displayString)")
        } else {
            self.config = .default
            debugLog("Using default hotkey config: \(config.displayString)")
        }

        Self.installCarbonEventHandler()

        registerBoth()
        debugLog("HotkeyManager init completed")
    }

    deinit {
        MainActor.assumeIsolated {
            unregisterBoth()
            removeLocalMonitor()
        }
    }

    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            debugLog("Failed to save config: \(error)")
        }
    }

    private static func installCarbonEventHandler() {
        guard eventHandlerRef == nil else { return }

        let eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

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
                    MainActor.assumeIsolated {
                        HotkeyManager.shared.onHotkeyPressed?()
                    }
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
            carbonRetryAttempts = 0
            debugLog("Carbon hotkey registered: '\(config.displayString)'")
            return
        }
        carbonHotKeyRef = nil
        errorLog("Carbon RegisterEventHotKey failed: \(status) for '\(config.displayString)'")

        guard status == OSStatus(eventHotKeyExistsErr) else { return }
        guard carbonRetryAttempts < Self.carbonRetryMax else {
            carbonRetryAttempts = 0
            let axTrusted = AXIsProcessTrusted()
            errorLog("Carbon hotkey '\(config.displayString)' is held by another app; NSEvent fallback active=\(axTrusted)")
            if !axTrusted { presentHotkeyConflictAlert() }
            return
        }
        carbonRetryAttempts += 1
        let delay = Double(carbonRetryAttempts) * 0.5
        debugLog("Carbon hotkey busy; retry \(carbonRetryAttempts)/\(Self.carbonRetryMax) in \(delay)s")
        carbonRetryTask?.cancel()
        carbonRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.carbonHotKeyRef == nil else { return }
            self.registerCarbon()
        }
    }

    private func presentHotkeyConflictAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "快捷键 \(config.displayString) 被其他应用占用"
        alert.informativeText = "另一个应用已注册相同的全局快捷键，CopyAttach 无法响应。请在偏好设置中更换快捷键，或退出占用该快捷键的应用后重新打开 CopyAttach。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开偏好设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            AppDelegate.shared?.openSettings()
        }
    }

    private func unregisterCarbon() {
        carbonRetryTask?.cancel()
        carbonRetryTask = nil
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
    }

    private func registerNSEvent() {
        unregisterNSEvent()

        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }

            let keyCode = event.keyCode
            let allFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let sigFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let pressedFlags = allFlags.intersection(sigFlags)

            let configFlags = NSEvent.ModifierFlags(rawValue: self.config.flags)
                .intersection(.deviceIndependentFlagsMask)
                .intersection(sigFlags)

            if keyCode == self.config.keyCode && pressedFlags == configFlags {
                debugLog("NSEvent hotkey match! keyCode=\(keyCode) flags=\(pressedFlags.rawValue)")
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.onHotkeyPressed?()
                    }
                }
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

    private func registerBoth() {
        registerCarbon()
        registerNSEvent()
    }

    private func unregisterBoth() {
        unregisterCarbon()
        unregisterNSEvent()
    }

    func reregisterHotkeys() {
        unregisterBoth()
        registerBoth()
    }

    func startRecording() {
        isRecording = true

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captureKeyEvent(event)
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

    func captureKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }

        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let hasModifier = flags.contains(.command) || flags.contains(.option) ||
                          flags.contains(.control) || flags.contains(.shift)

        if keyCode == 53 && !hasModifier {
            debugLog("Hotkey recording cancelled by user pressing Escape")
            stopRecording()
            return
        }

        guard hasModifier else { return }

        let newConfig = HotkeyConfig(keyCode: keyCode, flags: flags.rawValue)
        if newConfig != config {
            config = newConfig
        }
        stopRecording()
    }

    func resetToDefault() {
        config = .default
    }
}
