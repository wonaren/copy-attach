import AppKit
import SwiftUI

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var backendRetryTimer: Timer?
    private var stressWindowController: StressTestWindowController?
    private var firstLaunchDone = false
    private var backendStarted = false
    /// Set when clipboard_init returned -1; blocks the retry loop until the
    /// user recovers via the dialog.
    private var databaseCorrupt = false
    private var corruptDialogShowing = false
    /// Set when clipboard_init reported a permanent environment failure (-2);
    /// prompts the user on hotkey press while the background retry loop
    /// continues binary exponential backoff for auto-recovery.
    private var databaseUnusable = false
    private var databaseUnusableDialogShowing = false
    /// Last backend start attempt, for retry cooldown.
    private var lastBackendStartAttempt: Date?
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

        // Resolve perf tracing before any measured path can run, and validate
        // the instrument itself. The self-check runs every launch (its probe
        // and verdict records are written unconditionally) so "is the
        // instrument working?" always has a recorded answer.
        let perfOn = Perf.bootstrap()
        let perfVerdict = PerfSelfCheck.run()
        debugLog("Perf tracing \(perfOn ? "enabled" : "disabled"); self-check \(perfVerdict ? "PASS" : "FAIL")")

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

        // Start the clipboard backend directly.
        startBackendIfNeeded()

        // Register local ⌘+, monitor for when app windows are active (popup, settings, etc.)
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 43 && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) { // kVK_ANSI_Comma = 43
                self?.openSettings()
                return nil
            }
            // ⌥⌘S opens stress-test panel (debug/benchmark use)
            if event.keyCode == 1 && flags.contains(.command) && flags.contains(.option) && !flags.contains(.control) {
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
        backendRetryTimer?.invalidate()
        OnboardingGuide.shared.stop()
        if backendStarted { ClipboardBackend.shared.stop() }
    }

    /// Redirect stderr to the debug log so Rust diagnostics land in the same file.
    private func redirectStderrToDebugLog() {
        let path = "/tmp/copyattach_debug.log"
        Self.rotateDebugLogIfNeeded(at: path)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    /// Keep the shared debug log bounded by rotating it once per launch.
    ///
    /// Nothing rotated this file before: it is append-only, written by three
    /// independent writers (Swift's `dup2`'d stderr, Rust's per-record `emit`,
    /// and Rust's error log) and it therefore grew without bound. That is not
    /// just disk hygiene — it corrupted measurement. The analyzer reads the
    /// whole file, and spans from previous builds are indistinguishable from
    /// current ones, so a stale `popup.show` from an older binary reported as
    /// p95 561 ms / max 733 ms while the live pid showed p50 53 ms / max 118 ms.
    /// Worse, `popup.build_hosting` no longer exists in the source yet still
    /// appeared in the statistics.
    ///
    /// Rotation happens here, before every writer has opened the file: the
    /// stderr fd is `dup2`'d to whatever `open` returns below, and Rust opens
    /// per record, so no writer is ever left pointing at a moved inode. Doing
    /// it per record instead would race exactly that fd.
    private static func rotateDebugLogIfNeeded(at path: String) {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: path)[.size] as? Int,
              let bytes = size as Int?,
              bytes >= debugLogRotationBytes else { return }
        let archived = path + ".1"
        try? fm.removeItem(atPath: archived)
        do {
            try fm.moveItem(atPath: path, toPath: archived)
        } catch {
            // Keeping the old file is better than losing the log.
            return
        }
    }

    /// Rotate once the log passes this size (~4 MB holds many sessions of
    /// tracing records while staying small enough to read whole).
    private static let debugLogRotationBytes = 4 * 1024 * 1024

    @MainActor
    private func startBackendIfNeeded() {
        guard !backendStarted else { return }
        lastBackendStartAttempt = Date()
        debugLog("Starting Rust backend")
        switch ClipboardBackend.shared.start() {
        case .started:
            backendStarted = true
            backendRetryTimer?.invalidate()
            backendRetryTimer = nil
            // Recovered (or started cleanly): clear the backoff so a future
            // failure starts from the base delay again.
            if startFailures > 0 {
                debugLog("Rust backend started after \(startFailures) failed attempt(s); backoff reset")
            }
            startFailures = 0
            // Clear any environment-failure flag: auto-recovery succeeded.
            databaseUnusable = false
            // Core features are live: the first-run tour can now be walked
            // (its first step is watching the clipboard for a capture).
            OnboardingGuide.shared.startIfNeeded()
        case .retryable:
            startFailures += 1
            let next = currentStartRetryDelay()
            debugLog("Rust backend failed to initialize (attempt \(startFailures)); next retry in \(String(format: "%.1f", next))s")
            scheduleBackendRetry(delay: next)
        case .corruptDatabase:
            // Permanent: retrying cannot fix a corrupt file and silently
            // showing an empty popup hides the failure. Stop the retry loop and
            // ask the user; only replacing the file can help.
            databaseCorrupt = true
            backendRetryTimer?.invalidate()
            backendRetryTimer = nil
            lastBackendStartAttempt = nil
            startFailures = 0
            debugLog("Rust backend refused to start: database corrupt")
            presentCorruptDatabaseDialog()
        case .permanentEnvironment:
            // The database is intact; the environment is not. Auto-recovery is
            // the whole point here: the user fixes disk/permissions out of band
            // (no UI interaction), so the app keeps retrying on the backoff
            // schedule and starts by itself once the fix lands. The dialog is a
            // separate, user-initiated affordance — it must NOT stop the timer.
            startFailures += 1
            let next = currentStartRetryDelay()
            databaseUnusable = true
            debugLog("Rust backend refused to start: database unusable in this environment (attempt \(startFailures)); will keep retrying, next in \(String(format: "%.1f", next))s")
            scheduleBackendRetry(delay: next)
        }
    }

    /// Non-corrupt permanent failure dialog: the database is fine, the
    /// environment is not (read-only, permissions, disk full). No rebuild offer,
    /// because that would discard a usable database.
    @MainActor
    private func presentDatabaseUnusableDialog() {
        guard !databaseUnusableDialogShowing else { return }
        databaseUnusableDialogShowing = true
        defer { databaseUnusableDialogShowing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法读写剪贴板历史数据库"
        alert.informativeText = """
        CopyAttach 无法打开历史数据库，剪贴板监控已停止。

        常见原因：磁盘空间不足、目录权限异常，或该目录被安全软件限制写入。

        位置：~/Library/Application Support/CopyAttach/

        修复后 CopyAttach 会自动恢复；也可点击「重试」立即重试。
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertFirstButtonReturn {
            // Explicit user retry: reset the backoff so this attempt is
            // immediate rather than waiting out the current step. Auto-recovery
            // is already running; this just pre-empts the timer.
            databaseUnusable = false
            startFailures = 0
            lastBackendStartAttempt = nil
            backendRetryTimer?.invalidate()
            backendRetryTimer = nil
            // Retry on the next run-loop turn: this function's defer has not
            // run yet, so calling startBackendIfNeeded() synchronously here
            // would leave databaseUnusableDialogShowing == true and silently
            // swallow a re-presentation if the environment is still broken
            // (the user would click 重试 and see the dialog vanish with no
            // feedback). Letting this call unwind first makes the retry path
            // reachable and, on repeat failure, re-presents the dialog.
            DispatchQueue.main.async { [weak self] in
                self?.startBackendIfNeeded()
            }
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

    // MARK: - Backend start retry (binary exponential backoff)

    /// Consecutive failed start attempts. Reset to 0 on success; drives the
    /// backoff exponent.
    private var startFailures = 0
    /// First retry delay after a failure. Small: a busy/locked database often
    /// clears within a second or two, and the user is waiting for capture.
    private static let startRetryBaseDelay: TimeInterval = 2
    /// Ceiling on the retry delay. A permanently broken environment must not
    /// produce an unbounded schedule, and a self-healing one (disk freed,
    /// permissions restored) still recovers within a minute.
    private static let startRetryMaxDelay: TimeInterval = 60

    /// Binary exponential backoff: delay_n = min(cap, base * 2^(n-1)), before
    /// a +/-25% jitter.
    ///
    /// The doubling is the standard response to a resource that is not ready:
    /// retry eagerly while the fault may be momentary, then back off so a
    /// persistent fault costs a bounded trickle of attempts instead of a busy
    /// loop. The jitter de-synchronises this timer from the other periodic
    /// work (the clipboard poll) so retries do not
    /// repeatedly land on the same instant as unrelated work.
    @MainActor
    private func currentStartRetryDelay() -> TimeInterval {
        guard startFailures > 0 else { return 0 }
        // Cap the exponent before pow to avoid overflow on a long outage.
        let exponent = min(Double(startFailures - 1), 20)
        let raw = Self.startRetryBaseDelay * pow(2, exponent)
        let capped = min(raw, Self.startRetryMaxDelay)
        return capped * Double.random(in: 0.75...1.25)
    }

    /// Schedules a one-shot retry to start the backend after the backoff delay.
    ///
    /// Deliberately does NOT stop for databaseUnusable: a permanent
    /// environment failure (read-only file, disk full) is exactly the case
    /// where the user fixes the cause out-of-band, and the app must recover on
    /// its own. Retrying costs one open() per backoff period, bounded by the
    /// cap; the dialog is presented separately, on user action.
    @MainActor
    private func scheduleBackendRetry(delay: TimeInterval) {
        backendRetryTimer?.invalidate()
        let interval = max(0.5, delay)
        let timer = Timer(fire: Date().addingTimeInterval(interval), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.backendRetryTimer = nil
                self.startBackendIfNeeded()
            }
        }
        backendRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        guard window === settingsWindow else { return }
        settingsWindow = nil

        // Quit unless background mode is enabled.
        let runInBackground = UserDefaults.standard.object(forKey: "RunInBackground") as? Bool ?? true
        if !runInBackground { NSApp.terminate(nil) }
    }

    /// True when an interactive window of this application (Settings,
    /// Stress Test) is currently visible.
    @MainActor
    var hasVisibleAppWindow: Bool {
        if let window = settingsWindow, window.isVisible { return true }
        if let wc = stressWindowController, let window = wc.window, window.isVisible { return true }
        for window in NSApp.windows {
            if !(window is NSPanel) && window.isVisible && window.title == "CopyAttach" {
                return true
            }
        }
        return false
    }

    /// True while presenting an app window, preventing concurrent popup closure
    /// from surrendering foreground focus to the previous application.
    @MainActor
    private(set) var isPresentingAppWindow: Bool = false

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
        let popup = HistoryPopupWindow.shared
        if databaseCorrupt {
            presentCorruptDatabaseDialog()
            return
        }
        if databaseUnusable {
            presentDatabaseUnusableDialog()
            return
        }
        // Summoning the history list is an explicit "I'm done pasting" signal.
        // End the queue HERE, before the popup exists: the popup's onAppear also
        // clears it as a safety net, but doing it after the window is already up
        // looked like the queue had evaporated on its own.
        if PasteQueueManager.shared.status == .dispensing {
            debugLog("togglePopup: leaving the paste queue before showing history")
            PasteQueueManager.shared.cancel()
        }
        popup.toggle()
        if popup.isOpenOrOpening {
            OnboardingGuide.shared.record(.popupOpened)
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
        MainActor.assumeIsolated {
            isPresentingAppWindow = true
            defer { isPresentingAppWindow = false }
            if HistoryPopupWindow.shared.isVisible {
                HistoryPopupWindow.shared.close()
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
    }

    // MARK: - Settings

    @MainActor @objc func openSettings() {
        isPresentingAppWindow = true
        defer { isPresentingAppWindow = false }
        if HistoryPopupWindow.shared.isVisible {
            HistoryPopupWindow.shared.close()
        }
        openSettingsWindow()
    }

    private func openSettingsWindow(initialTab: Int = 0) {
        ClipboardBackend.shared.refreshPermission()

        if let existing = settingsWindow, existing.isVisible {
            debugLog("Reusing existing settings window")
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
                window.center()
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
