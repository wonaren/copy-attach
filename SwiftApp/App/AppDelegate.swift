import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    private var settingsWindow: NSWindow?
    private var backendRetryTimer: Timer?
    private var stressWindowController: StressTestWindowController?
    private var firstLaunchDone = false
    private var backendStarted = false
    private var databaseCorrupt = false
    private var corruptDialogShowing = false
    private var databaseUnusable = false
    private var databaseUnusableDialogShowing = false
    private var lastBackendStartAttempt: Date?
    private var localKeyDownMonitor: Any?

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

        redirectStderrToDebugLog()

        let perfOn = Perf.bootstrap()
        let perfVerdict = PerfSelfCheck.run()
        debugLog("Perf tracing \(perfOn ? "enabled" : "disabled"); self-check \(perfVerdict ? "PASS" : "FAIL")")

        ClipboardBackend.syncDebugLogging()

        UpdateDownloader.cleanupLegacyArtifacts()

        debugLog("Starting initialization...")

        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.onHotkeyPressed = { [weak self] in
            debugLog("Hotkey pressed callback triggered")
            self?.togglePopup()
        }
        debugLog("Hotkey callback set up")

        startBackendIfNeeded()

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 43 && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                self?.openSettings()
                return nil
            }
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

    private func redirectStderrToDebugLog() {
        let path = "/tmp/copyattach_debug.log"
        Self.rotateDebugLogIfNeeded(at: path)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

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
            return
        }
    }

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
            if startFailures > 0 {
                debugLog("Rust backend started after \(startFailures) failed attempt(s); backoff reset")
            }
            startFailures = 0
            databaseUnusable = false
            OnboardingGuide.shared.startIfNeeded()
        case .retryable:
            startFailures += 1
            let next = currentStartRetryDelay()
            debugLog("Rust backend failed to initialize (attempt \(startFailures)); next retry in \(String(format: "%.1f", next))s")
            scheduleBackendRetry(delay: next)
        case .corruptDatabase:
            databaseCorrupt = true
            backendRetryTimer?.invalidate()
            backendRetryTimer = nil
            lastBackendStartAttempt = nil
            startFailures = 0
            debugLog("Rust backend refused to start: database corrupt")
            presentCorruptDatabaseDialog()
        case .permanentEnvironment:
            startFailures += 1
            let next = currentStartRetryDelay()
            databaseUnusable = true
            debugLog("Rust backend refused to start: database unusable in this environment (attempt \(startFailures)); will keep retrying, next in \(String(format: "%.1f", next))s")
            scheduleBackendRetry(delay: next)
        }
    }

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
            databaseUnusable = false
            startFailures = 0
            lastBackendStartAttempt = nil
            backendRetryTimer?.invalidate()
            backendRetryTimer = nil
            DispatchQueue.main.async { [weak self] in
                self?.startBackendIfNeeded()
            }
        }
    }

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

    private var startFailures = 0
    private static let startRetryBaseDelay: TimeInterval = 2
    private static let startRetryMaxDelay: TimeInterval = 60

    @MainActor
    private func currentStartRetryDelay() -> TimeInterval {
        guard startFailures > 0 else { return 0 }
        let exponent = min(Double(startFailures - 1), 20)
        let raw = Self.startRetryBaseDelay * pow(2, exponent)
        let capped = min(raw, Self.startRetryMaxDelay)
        return capped * Double.random(in: 0.75...1.25)
    }

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

        let runInBackground = UserDefaults.standard.object(forKey: "RunInBackground") as? Bool ?? true
        if !runInBackground { NSApp.terminate(nil) }
    }

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

    @MainActor
    private(set) var isPresentingAppWindow: Bool = false

    func focusSettingsWindow() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

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
        if PasteQueueManager.shared.status == .dispensing {
            debugLog("togglePopup: leaving the paste queue before showing history")
            PasteQueueManager.shared.cancel()
        }
        if BatchDragController.shared.isDispatching {
            debugLog("togglePopup: cancelling the in-flight batch dispatch")
            BatchDragController.shared.abortPendingDispatch()
        }
        popup.toggle()
        if popup.isOpenOrOpening {
            OnboardingGuide.shared.record(.popupOpened)
        }
    }

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
