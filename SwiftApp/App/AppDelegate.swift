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
    /// When the backend was last attempted so a transient failure (e.g. a
    /// locked SQLite file) is retried on a cooldown instead of staying dead
    /// for the whole session.
    private var lastBackendStartAttempt: Date?
    /// True while a maintenance tick's async body is running — overlapping
    /// triggers collapse into a single pass.
    private var maintenanceTickInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        // Route the Rust backend's stderr (eprintln) into the debug log. The
        // LSUIElement agent has no terminal — without this, every Rust-side
        // failure (DB write errors, persistence rollbacks, ghost-entry guards)
        // is silently discarded by launchd and diagnosing data issues becomes
        // guesswork.
        redirectStderrToDebugLog()

        // Apply the persisted debug-logging preference before any debugLog
        // call, so startup/licensing diagnostics are captured even when the
        // Rust backend has not started yet (e.g. license gate).
        ClipboardBackend.syncDebugLogging()

        debugLog("Starting initialization...")

        // Get HotkeyManager setup first (doesn't require Rust backend)
        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.onHotkeyPressed = { [weak self] in
            debugLog("Hotkey pressed callback triggered")
            self?.togglePopup()
        }
        debugLog("Hotkey callback set up")

        // Licensing is initialized before the clipboard core. The Rust backend
        // never starts while the entitlement is absent or invalid.
        Task { @MainActor in
            await LicenseManager.shared.initialize()
            entitlementDidChange()
            startEntitlementTimer()
        }

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

        // First-launch routing happens after licensing initialization above.
        // An unlicensed app always opens directly on the License tab.

        firstLaunchDone = true
        debugLog("Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        entitlementTimer?.invalidate()
        if backendStarted { ClipboardBackend.shared.stop() }
    }

    /// dup2 the process's stderr onto the debug log file so Rust's eprintln
    /// diagnostics (which bypass Swift's debugLog) land in the same log.
    /// Must run before the Rust backend starts. debugLog no longer writes to
    /// stderr itself — the redirected fd would duplicate every line.
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
        // Re-arm the one-shot maintenance timer for the new entitlement state.
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
        backendStarted = ClipboardBackend.shared.start()
        if !backendStarted { debugLog("Rust backend failed to initialize") }
    }

    /// Retries a failed backend start (transient DB lock etc.) on a 5s
    /// cooldown so a licensed app recovers without a relaunch. Idempotent:
    /// `start()` is a no-op once the Rust backend is running.
    @MainActor
    private func retryBackendStartIfNeeded() {
        guard !backendStarted,
              LicenseManager.shared.state.permitsCoreFeatures else { return }
        if let last = lastBackendStartAttempt,
           Date().timeIntervalSince(last) < 5 { return }
        startBackendIfNeeded()
    }

    /// The activation celebration has finished. Return to the license page so
    /// the user can confirm activation succeeded before dismissing the gate.
    /// The backend starts now so the app is already functional while the gate
    /// stays open.
    @MainActor
    func licenseCelebrationFinished() {
        startBackendIfNeeded()
        // The freshly applied lease schedules an immediate online status
        // check (nextStatusCheckAt = now); arm the one-shot timer for it.
        scheduleMaintenanceTick()
    }

    @MainActor
    private func startEntitlementTimer() {
        scheduleMaintenanceTick()
    }

    /// Arms ONE one-shot maintenance timer against the earliest pending
    /// deadline (license refresh / online status check / trial expiry /
    /// backend-start retry). The previous design scheduled a repeating timer
    /// that woke every second for the app's entire lifetime — 86 400 needless
    /// wakeups per day on a no-op body for perpetual licenses (which schedule
    /// no maintenance at all) and unlicensed installs. Deadline-based arming
    /// brings steady-state timer wakeups to zero there and to one per
    /// status-check interval (~2 min) for trial/subscription, with every check
    /// still running at-or-before its original deadline.
    @MainActor
    private func scheduleMaintenanceTick() {
        entitlementTimer?.invalidate()
        entitlementTimer = nil

        guard LicenseManager.shared.state.permitsCoreFeatures else { return }

        // While the activation celebration plays in the still-open gate window,
        // maintenance must not run: entitlementDidChange() would close it
        // early. Defer by a second and re-evaluate.
        if LicenseManager.shared.celebration != nil {
            armMaintenanceTimer(at: Date().addingTimeInterval(1))
            return
        }

        // A failed backend start retries on a 5s cooldown even when no license
        // maintenance is pending (transient DB lock etc.).
        let retryAt: Date? = {
            guard !backendStarted, let last = lastBackendStartAttempt else { return nil }
            return last.addingTimeInterval(5)
        }()

        var candidates: [Date] = []
        if let d = LicenseManager.shared.nextMaintenanceAt { candidates.append(d) }
        if let d = retryAt { candidates.append(d) }
        guard let next = candidates.min() else {
            // Perpetual license and a healthy backend: no timer at all.
            return
        }

        if next.timeIntervalSinceNow <= 0.5 {
            // Deadline already due — run the tick now; its completion re-arms
            // against the fresh deadlines (the status check pushes the next
            // one ~120s out, so this cannot hot-loop).
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

    /// One maintenance pass: retry the backend start if it failed, then run
    /// the license maintenance (lease refresh / status check / expiry) and
    /// re-arm the next deadline. The in-flight flag collapses overlapping
    /// triggers (e.g. `entitlementDidChange` firing while a tick is already
    /// running) into a single pass.
    @MainActor
    private func runMaintenanceTick() {
        guard !maintenanceTickInFlight else { return }
        // The celebration plays in the still-open gate window; maintenance
        // would close it early via entitlementDidChange — defer and re-arm
        // (this also covers the timer-fire path, whose timer was armed while
        // the celebration was running).
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

    /// Called by LicenseManager right after a successful activation to signal
    /// that the in-window celebration is about to play. Nothing needs to
    /// happen here (the gate stays open on purpose), but the hook documents
    /// the contract and keeps the flow explicit.
    @MainActor
    func licenseCelebrationDidStart() {
        debugLog("License celebration started; gate stays open until animation finishes")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === licenseGateWindow {
            licenseGateWindow = nil
            if !LicenseManager.shared.state.permitsCoreFeatures { NSApp.terminate(nil) }
            return
        }
        guard window === settingsWindow else { return }
        settingsWindow = nil

        // When "Run in background" is off, closing the settings window quits
        // the app (conventional single-window app behavior). When on, the app
        // stays alive in the menu bar.
        // Without an entitlement there is no background functionality to run:
        // closing the mandatory license window exits instead of leaving a
        // non-functional menu-bar process alive.
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
        // Pin the gate window to its fixed size so SwiftUI fitting-size
        // adjustments (e.g. when the in-window celebration swaps content)
        // never resize or relocate the window.
        window.setContentSize(NSSize(width: 500, height: 470))
        window.center()
        licenseGateWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Re-center after the window is on screen: AppKit can still adjust the
        // frame once the hosting view lays out, which would move the window
        // away from the screen center.
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
        // Settings shows the accessibility-permission state — refresh it now
        // (explicit check point, no background polling).
        ClipboardBackend.shared.refreshPermission()

        // If we already have a settings window, bring it to front
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
        createSettingsWindow(initialTab: initialTab)
    }

    private func makeSettingsContent(initialTab: Int) -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(InlineSettingsView(initialTab: initialTab).withAppTheme()))
    }

    private func createSettingsWindow(initialTab: Int = 0) {
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
