import AppKit
import SwiftUI

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var stressWindowController: StressTestWindowController?
    private var firstLaunchDone = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        debugLog("Starting initialization...")

        // Get HotkeyManager setup first (doesn't require Rust backend)
        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.onHotkeyPressed = { [weak self] in
            debugLog("Hotkey pressed callback triggered")
            self?.togglePopup()
        }
        debugLog("Hotkey callback set up")

        // Initialize Rust backend
        debugLog("Starting Rust backend...")
        let started = ClipboardBackend.shared.start()
        if !started {
            debugLog("Rust backend failed to initialize — app may not function correctly")
        }
        debugLog("Rust backend started")

        // Register local ⌘+, monitor for when app windows are active (popup, settings, etc.)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 43 && event.modifierFlags.contains(.command) { // kVK_ANSI_Comma = 43
                self?.openSettings()
                return nil
            }
            // ⌥⌘S opens stress-test panel (debug/benchmark use)
            if event.keyCode == 1 && event.modifierFlags.contains(.command) && event.modifierFlags.contains(.option) {
                self?.toggleStressPanel()
                return nil
            }
            return event
        }

        // Silent launch: only show settings on first-ever launch so the user
        // can configure hotkeys and permissions. Subsequent launches stay
        // quietly in the menu bar.
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
            openSettingsWindow()
        }

        firstLaunchDone = true
        debugLog("Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardBackend.shared.stop()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow else { return }
        settingsWindow = nil

        // When "Run in background" is off, closing the settings window quits
        // the app (conventional single-window app behavior). When on, the app
        // stays alive in the menu bar.
        let runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
        if !runInBackground {
            NSApp.terminate(nil)
        }
    }

    /// Bring the settings window to front and activate the app.
    /// Called automatically when accessibility permission is newly granted.
    func focusSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Popup

    @objc func togglePopup() {
        let popup = HistoryPopupWindow.shared
        if popup.isVisible {
            popup.close()
        } else {
            popup.show()
        }
    }

    // MARK: - Stress Test Panel

    @objc func toggleStressPanel() {
        // Check if stress-test feature is compiled in
        guard clipboard_stress_available() == 1 else {
            let alert = NSAlert()
            alert.messageText = "Stress-Test 功能未启用"
            alert.informativeText = "当前构建未包含 stress-test feature。\n请使用 STRESS=1 ./build.sh 重新构建。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        if let wc = stressWindowController, let window = wc.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let wc = StressTestWindowController()
            stressWindowController = wc
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Settings

    @objc func openSettings() {
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        // If we already have a settings window, bring it to front
        if let existing = settingsWindow, existing.isVisible {
            debugLog("Reusing existing settings window")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsWindow = nil

        // Look for the window by title — skip NSPanel instances (popup,
        // preview) which coincidentally use the same title "CopyAttach",
        // to avoid falsely "reusing" the popup when no settings window exists.
        for window in NSApp.windows {
            if !(window is NSPanel) && window.title == "CopyAttach" {
                debugLog("Found existing settings window by title")
                settingsWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        // No window found - create one using NSWindow with NSHostingView
        debugLog("Creating new settings window")
        createSettingsWindow()
    }

    private func createSettingsWindow() {
        debugLog("Creating settings window...")
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CopyAttach"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let content = NSHostingController(rootView: InlineSettingsView().withAppTheme())
        content.view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        content.view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        window.contentViewController = content

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
        debugLog("Created settings window with redesigned InlineSettingsView")
    }
}
