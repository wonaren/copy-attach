import AppKit
import SwiftUI

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var licenseGateWindow: NSWindow?
    private var entitlementTimer: Timer?
    private var stressWindowController: StressTestWindowController?
    private var firstLaunchDone = false
    private var backendStarted = false
    /// Set when clipboard_init returned -1; blocks the retry loop until the
    /// user recovers via the dialog.
    private var databaseCorrupt = false
    private var corruptDialogShowing = false
    /// Last backend start attempt, for retry cooldown.
    private var lastBackendStartAttempt: Date?
    /// True while a maintenance tick's async body is running.
    private var maintenanceTickInFlight = false
    /// Retained token for the app-level local key monitor.
    private var localKeyDownMonitor: Any?

    /// Single-instance enforcement. Must run before anything else in the
    /// process: SwiftUI evaluates the MenuBarExtra body (and thus
    /// `HotkeyManager.shared`, which registers the Carbon hotkey) before any
    /// NSApplicationDelegate callback fires, so it is called from `App.init`.
    /// A duplicate that registered first would steal the combo from the
    /// surviving instance (-9878).
    static func terminateIfDuplicateInstance() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.copyattach"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        guard let existing = others.first else { return }
        errorLog("Another CopyAttach instance (pid \(existing.processIdentifier)) is running; activating it and terminating duplicate")
        existing.activate()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Route Rust stderr into the debug log (the agent has no terminal).
        redirectStderrToDebugLog()

        // Apply persisted debug-logging preference before startup diagnostics.
        ClipboardBackend.syncDebugLogging()

        // Clean up any stale disk images or temporary folders left by previous updates.
        UpdateDownloader.cleanupLegacyArtifacts()

        debugLog("Starting initialization...")

        // Get HotkeyManager setup first (doesn't require Rust backend)
        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.onHotkeyPressed = { [weak self] in
            debugLog("Hotkey pressed callback triggered")
            self?.togglePopup()
        }
        debugLog("Hotkey callback set up")

        // Licensing runs before the clipboard core; backend stays gated on entitlement.
        Task { @MainActor in
            await LicenseManager.shared.initialize()
            entitlementDidChange()
            startEntitlementTimer()
        }

        // Register local ⌘+, monitor for when app windows are active (popup, settings, etc.)
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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

        firstLaunchDone = true
        debugLog("Initialization complete")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Trigger popup when launched from Spotlight, Launchpad, or Finder while already running.
        togglePopup()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
        }
        entitlementTimer?.invalidate()
        if backendStarted { ClipboardBackend.shared.stop() }
    }

    /// Redirect stderr to the debug log so Rust diagnostics land in the same file.
    private func redirectStderrToDebugLog() {
        let path = "/tmp/copyattach_debug.log"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    @MainActor
    func entitlementDidChange() {
        if LicenseManager.shared.state.permitsCoreFeatures {
            closeLicenseGate()
            startBackendIfNeeded()
        } else {
            _ = clipboard_set_runtime_entitlement(0)
            lastBackendStartAttempt = nil
            if backendStarted {
                debugLog("License no longer permits core features; stopping Rust backend")
                ClipboardBackend.shared.stop()
                backendStarted = false
            }
            showLicenseGate()
        }
        scheduleMaintenanceTick()
    }

    @MainActor
    private func startBackendIfNeeded() {
        guard !backendStarted else { return }
        guard LicenseManager.shared.state.permitsCoreFeatures else { return }
        let runtimeState: Int32
        switch LicenseManager.shared.state {
        case .trialActive: runtimeState = 1
        case .licensed, .subscriptionActive: runtimeState = 2
        default: return
        }
        guard clipboard_set_runtime_entitlement(runtimeState) == 1 else {
            debugLog("Rust rejected runtime entitlement state")
            return
        }
        lastBackendStartAttempt = Date()
        debugLog("License permits core features; starting Rust backend")
        switch ClipboardBackend.shared.start() {
        case .started:
            backendStarted = true
        case .retryable:
            debugLog("Rust backend failed to initialize; will retry")
        case .corruptDatabase:
            // Permanent: retrying is pointless and silently showing an empty
            // popup hides the failure. Stop the retry loop and ask the user.
            databaseCorrupt = true
            lastBackendStartAttempt = nil
            debugLog("Rust backend refused to start: database corrupt")
            presentCorruptDatabaseDialog()
        }
    }

    /// Corrupt-DB recovery dialog. Runs modally; re-entrancy guarded so a
    /// hotkey press while the sheet is up cannot stack a second one.
    @MainActor
    private func presentCorruptDatabaseDialog() {
        guard !corruptDialogShowing else { return }
        corruptDialogShowing = true
        defer { corruptDialogShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "剪贴板历史数据库已损坏"
        alert.informativeText = "CopyAttach 无法读取历史记录数据库，剪贴板监控已停止。\n\n选择「备份并重建」会把损坏的文件保留为 history.db.corrupt-… 并新建空数据库；选择「退出」可先手动处理该文件。\n\n位置：~/Library/Application Support/CopyAttach/"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "备份并重建")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertFirstButtonReturn {
            if clipboard_recover_corrupt_db() == 1 {
                databaseCorrupt = false
                // If the fresh DB still fails, startBackendIfNeeded re-arms
                // either the retry loop (retryable) or `databaseCorrupt`
                // (next hotkey press re-presents this dialog).
                startBackendIfNeeded()
            } else {
                let fail = NSAlert()
                fail.messageText = "无法移动损坏的数据库文件"
                fail.informativeText = "请退出 CopyAttach 后手动删除或移走 ~/Library/Application Support/CopyAttach/history.db。"
                fail.alertStyle = .critical
                fail.addButton(withTitle: "退出")
                fail.runModal()
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Retry a failed backend start on a 5s cooldown.
    @MainActor
    private func retryBackendStartIfNeeded() {
        guard !backendStarted, !databaseCorrupt,
              LicenseManager.shared.state.permitsCoreFeatures else { return }
        if let last = lastBackendStartAttempt,
           Date().timeIntervalSince(last) < 5 { return }
        startBackendIfNeeded()
    }

    /// The activation celebration finished; start the backend and re-arm maintenance.
    @MainActor
    func licenseCelebrationFinished() {
        startBackendIfNeeded()
        scheduleMaintenanceTick()
    }

    @MainActor
    private func startEntitlementTimer() {
        scheduleMaintenanceTick()
    }

    /// Arm one one-shot maintenance timer for the earliest pending deadline.
    @MainActor
    private func scheduleMaintenanceTick() {
        entitlementTimer?.invalidate()
        entitlementTimer = nil

        guard LicenseManager.shared.state.permitsCoreFeatures else { return }

        // Defer while the activation celebration is playing.
        if LicenseManager.shared.celebration != nil {
            armMaintenanceTimer(at: Date().addingTimeInterval(1))
            return
        }

        // Include backend-start retry cooldown in the candidate deadlines.
        let retryAt: Date? = {
            guard !backendStarted, let last = lastBackendStartAttempt else { return nil }
            return last.addingTimeInterval(5)
        }()

        var candidates: [Date] = []
        if let d = LicenseManager.shared.nextMaintenanceAt { candidates.append(d) }
        if let d = retryAt { candidates.append(d) }
        guard let next = candidates.min() else { return }

        if next.timeIntervalSinceNow <= 0.5 {
            runMaintenanceTick()
        } else {
            armMaintenanceTimer(at: next)
        }
    }

    @MainActor
    private func armMaintenanceTimer(at fireDate: Date) {
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.entitlementTimer = nil
                self.runMaintenanceTick()
            }
        }
        entitlementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One maintenance pass: retry backend, run license maintenance, re-arm.
    @MainActor
    private func runMaintenanceTick() {
        guard !maintenanceTickInFlight else { return }
        if LicenseManager.shared.celebration != nil {
            armMaintenanceTimer(at: Date().addingTimeInterval(1))
            return
        }
        maintenanceTickInFlight = true
        retryBackendStartIfNeeded()
        Task { @MainActor in
            if await LicenseManager.shared.maintainEntitlement() {
                AppDelegate.shared?.entitlementDidChange()
            }
            AppDelegate.shared?.maintenanceTickInFlight = false
            AppDelegate.shared?.scheduleMaintenanceTick()
        }
    }

    /// Called when the activation celebration is about to play.
    @MainActor
    func licenseCelebrationDidStart() {
        debugLog("License celebration started; gate stays open until animation finishes")
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        ClipboardBackend.shared.refreshPermission()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ClipboardBackend.shared.refreshPermission()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === licenseGateWindow {
            licenseGateWindow = nil
            // Closing the gate mid-celebration cancels the celebration view's
            // `.task`, so finishCelebration() would never run — leaving
            // `celebration` non-nil forever, which freezes license maintenance
            // and spins a 1Hz re-arm loop in scheduleMaintenanceTick(). The
            // activation already succeeded, so finish the celebration here.
            if LicenseManager.shared.celebration != nil {
                LicenseManager.shared.finishCelebration()
            }
            if !LicenseManager.shared.state.permitsCoreFeatures { NSApp.terminate(nil) }
            return
        }
        guard window === settingsWindow else { return }
        settingsWindow = nil

        // Quit unless background mode is enabled (or no entitlement to run it).
        if !LicenseManager.shared.state.permitsCoreFeatures {
            NSApp.terminate(nil)
            return
        }
        let runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
        if !runInBackground { NSApp.terminate(nil) }
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

    @MainActor @objc func togglePopup() {
        guard LicenseManager.shared.state.permitsCoreFeatures else {
            showLicenseGate()
            return
        }
        let popup = HistoryPopupWindow.shared
        if databaseCorrupt {
            presentCorruptDatabaseDialog()
            return
        }
        if popup.isVisible {
            popup.close()
        } else {
            popup.show()
        }
    }

    // MARK: - Stress Test Panel

    @objc func toggleStressPanel() {
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

    @MainActor @objc func openSettings() {
        if LicenseManager.shared.state.permitsCoreFeatures { openSettingsWindow() }
        else { showLicenseGate() }
    }

    @MainActor
    func openLicenseWindow() {
        if LicenseManager.shared.state.permitsCoreFeatures { openSettingsWindow(initialTab: 4) }
        else { showLicenseGate() }
    }

    @MainActor
    private func showLicenseGate() {
        if let window = licenseGateWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "激活 CopyAttach"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: LicenseGateView().withAppTheme())
        // Pin the gate window to its fixed size.
        window.setContentSize(NSSize(width: 500, height: 470))
        window.center()
        licenseGateWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-center after AppKit adjusts the frame during layout.
        DispatchQueue.main.async {
            window.setContentSize(NSSize(width: 500, height: 470))
            window.center()
        }
    }

    @MainActor
    func closeLicenseGate() {
        guard let window = licenseGateWindow else { return }
        window.delegate = nil
        window.close()
        licenseGateWindow = nil
    }

    private func openSettingsWindow(initialTab: Int = 0) {
        ClipboardBackend.shared.refreshPermission()

        if let existing = settingsWindow, existing.isVisible {
            debugLog("Reusing existing settings window")
            if initialTab == 4 {
                existing.contentViewController = makeSettingsContent(initialTab: 4)
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsWindow = nil

        // Match by title, skipping NSPanels that share the same title.
        for window in NSApp.windows {
            if !(window is NSPanel) && window.title == "CopyAttach" {
                debugLog("Found existing settings window by title")
                settingsWindow = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        debugLog("Creating new settings window")
        createSettingsWindow(initialTab: initialTab)
    }

    private func makeSettingsContent(initialTab: Int) -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(InlineSettingsView(initialTab: initialTab).withAppTheme()))
    }

    private func createSettingsWindow(initialTab: Int = 0) {
        debugLog("Creating settings window...")
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CopyAttach"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Must be false: enabling background movement steals mouse drags before
        // SwiftUI can start an item drag (such as dragging the app icon to the
        // Accessibility pane in System Settings), causing the entire window to move.
        // The window remains draggable by its title bar (same as HistoryPopupWindow).
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let content = makeSettingsContent(initialTab: initialTab)
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
