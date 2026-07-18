import AppKit
import SwiftUI
import ServiceManagement

/// Main entry point for the CopyAttach macOS app.
@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("ShowMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        // Menu bar
        MenuBarExtra("剪贴板", systemImage: "clipboard", isInserted: $showMenuBarIcon) {
            AppMenuBarContent()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu bar content that dynamically observes hotkey changes
struct AppMenuBarContent: View {
    @ObservedObject private var hotkeyManager = HotkeyManager.shared

    var body: some View {
        Button("打开主界面") {
            AppDelegate.shared?.openSettings()
        }
        Divider()
        Button("显示历史记录 (\(hotkeyManager.config.displayString))") {
            AppDelegate.shared?.togglePopup()
        }
        Divider()
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private var settingsWindow: NSWindow?
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

        // Show settings window on launch
        openSettingsWindow()

        firstLaunchDone = true
        debugLog("Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardBackend.shared.stop()
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

        // Look for the window by title
        for window in NSApp.windows {
            if window.title == "CopyAttach" {
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

    // MARK: - Inline Settings View
    private struct InlineSettingsView: View {
        @StateObject private var backend = ClipboardBackend.shared
        @StateObject private var hotkeyManager = HotkeyManager.shared
        @State private var selectedTab = 0
        @State private var launchAtLogin = UserDefaults.standard.bool(forKey: "LaunchAtLogin")
        @State private var runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
        @State private var showMenuBarIcon = UserDefaults.standard.bool(forKey: "ShowMenuBarIcon") != false
        @State private var cleanupThreshold: Double = {
            let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
            return Double(saved >= 100 ? saved : 3000)
        }()
        @State private var ignoredApps: [String] = UserDefaults.standard.stringArray(forKey: "IgnoredApps") ?? ["1Password", "Keychain Access", "System Settings"]
        @State private var ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
        @State private var shortTextThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold") != 0 ? UserDefaults.standard.integer(forKey: "ShortTextThreshold") : 3
        @State private var ignoreProtectedWindows = UserDefaults.standard.bool(forKey: "IgnoreProtectedWindows") != false
        @State private var pendingThreshold: Int? = nil
        @State private var thresholdBeforeEdit: Double = 3000
        @State private var showDragGuide = false
        @State private var isHoveringDragIcon = false
        
        var body: some View {
            VStack(spacing: 0) {
                tabBar
                Divider()
                    .frame(height: 1)
                    .background(Color(nsColor: NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)))
                tabContent
            }
            .frame(width: 520, height: 600)
            .background(Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)))
        }

        private var textCount: Int { backend.items.filter { $0.isText }.count }
        private var imageCount: Int { backend.items.filter { $0.isImage }.count }

        private var appVersion: String {
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
        }

        private var textPct: CGFloat {
            let threshold = CGFloat(max(Int(cleanupThreshold), 1))
            return CGFloat(textCount) / threshold
        }
        private var imagePct: CGFloat {
            let threshold = CGFloat(max(Int(cleanupThreshold), 1))
            return CGFloat(imageCount) / threshold
        }

        private let tabTitles = ["通用", "快捷键", "存储", "忽略", "关于"]
        private let tabIcons = ["gearshape", "keyboard", "externaldrive", "eye.slash", "info.circle"]

        // MARK: - Tab Bar
        @State private var hoveredTab: Int? = nil

        private var tabBar: some View {
            HStack(spacing: 4) {
                Spacer()
                ForEach(0..<5, id: \.self) { i in
                    Button {
                        selectedTab = i
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tabIcons[i])
                                .font(.system(size: 15, weight: .medium))
                            Text(tabTitles[i])
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .frame(width: 72)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == i
                            ? Color.accentColor.opacity(0.12)
                            : hoveredTab == i ? Color.white.opacity(0.06) : Color.clear
                        )
                        .cornerRadius(8)
                        .overlay(
                            selectedTab == i
                            ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1)
                            : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(
                        selectedTab == i
                        ? Color.accentColor
                        : hoveredTab == i
                        ? Color(nsColor: NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1.0))
                        : Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0))
                    )
                    .onHover { hovering in
                        hoveredTab = hovering ? i : nil
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .background(Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1.0)))
        }

        // MARK: - Tab Content Router
        private var tabContent: some View {
            Group {
                if selectedTab == 0 { generalTab }
                else if selectedTab == 1 { shortcutsTab }
                else if selectedTab == 2 { storageTab }
                else if selectedTab == 3 { ignoreTab }
                else { aboutTab }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Helpers
        private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: NSColor(calibratedRed: 0.175, green: 0.175, blue: 0.19, alpha: 1.0)))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0)), lineWidth: 1)
                )
        }

        private func kbdBadge(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(white: 0.85))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.37, alpha: 1.0)), lineWidth: 1)
                )
                .cornerRadius(5)
        }

        private func formatStorageSize(_ bytes: Int64) -> String {
            let bc = Double(bytes)
            switch bc {
            case 0: return "0 B"
            case ..<1024: return "\(Int(bc)) B"
            case ..<(1024 * 1024): return String(format: "%.1f KB", bc / 1024)
            case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", bc / (1024 * 1024))
            default: return String(format: "%.1f GB", bc / (1024 * 1024 * 1024))
            }
        }

        // MARK: - 🔵 GENERAL TAB
        private var generalTab: some View {
            ScrollView {
                VStack(spacing: 16) {
                    permissionBanner
                    generalSettingsCard
                    menuBarConfigCard
                }
                .padding(20)
            }
        }

        private var permissionBanner: some View {
            VStack(alignment: .leading, spacing: 12) {
                // Header — always visible
                HStack(spacing: 10) {
                    Image(systemName: backend.permissionGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 18))
                        .foregroundColor(backend.permissionGranted ? .green : .orange)
                    Text(backend.permissionGranted ? "辅助功能：已授权" : "辅助功能：未授权")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(backend.permissionGranted ? .green : .orange)
                }
                Text(backend.permissionGranted
                     ? "按 \(hotkeyManager.config.displayString) 打开剪贴板历史"
                     : "应用需要辅助功能权限才能使用全局快捷键和自动粘贴")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.78, alpha: 1.0)))
                    .lineSpacing(2)
                if !backend.permissionGranted && !showDragGuide {
                    Button(action: {
                        backend.openPreferences()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                            showDragGuide = true
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.lefthalf.filled")
                            Text("打开系统设置 → 授予权限")
                                .font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if showDragGuide && !backend.permissionGranted {
                    dragGuideContent
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backend.permissionGranted ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(backend.permissionGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: showDragGuide)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: backend.permissionGranted)
            .onChange(of: backend.permissionGranted) { _, granted in
                if granted {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        showDragGuide = false
                    }
                }
            }
        }

        private var dragGuideContent: some View {
            VStack(spacing: 12) {
                Color.orange.opacity(0.15)
                    .frame(height: 1)
                    .padding(.horizontal, -16)

                HStack(spacing: 14) {
                    ZStack {
                        Image(nsImage: .appIcon)
                            .resizable()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "hand.point.up")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Circle().fill(Color.accentColor))
                                    .offset(x: 5, y: -5)
                            }
                            .scaleEffect(isHoveringDragIcon ? 1.05 : 1.0)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isHoveringDragIcon = hovering
                                }
                            }
                            .onDrag {
                                let provider = NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                                provider.suggestedName = "CopyAttach"
                                return provider
                            }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("将图标拖入系统辅助功能列表")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(white: 0.85))
                        Text("已打开「系统设置 → 隐私与安全性 → 辅助功能」")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                        Button(action: { backend.openPreferences() }) {
                            Text("再次打开系统设置")
                                .font(.system(size: 10.5))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }

                    Spacer()

                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            showDragGuide = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.53, alpha: 1.0)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private var generalSettingsCard: some View {
            settingsCard {
                cardTitle(icon: "gearshape.2", text: "其它设置")
                settingToggleRow(
                    icon: launchAtLogin ? "power.circle.fill" : "power.circle",
                    iconColor: launchAtLogin ? .green : .secondary,
                    title: "开机启动",
                    desc: "在 macOS 系统启动时自动开启 CopyAttach。",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "LaunchAtLogin")
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        debugLog("Failed to update login item: \(error)")
                        launchAtLogin = !newValue
                        UserDefaults.standard.set(!newValue, forKey: "LaunchAtLogin")
                    }
                }
                sectionDivider().padding(.vertical, 4)
                settingToggleRow(
                    icon: runInBackground ? "circle.fill" : "circle",
                    iconColor: runInBackground ? .green : .secondary,
                    title: "后台运行",
                    desc: "关闭主窗口后，保持应用在后台状态栏运行。",
                    isOn: $runInBackground
                )
                .onChange(of: runInBackground) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "RunInBackground")
                    if !newValue { NSApp.terminate(nil) }
                }
            }
        }

        private var menuBarConfigCard: some View {
            settingsCard {
                cardTitle(icon: "menubar.rectangle", text: "菜单栏图标状态设置")
                settingToggleRow(
                    icon: "dot.square",
                    iconColor: showMenuBarIcon ? Color.accentColor : .secondary,
                    title: "显示菜单栏图标",
                    desc: "控制 CopyAttach 图标在 macOS 右上角状态栏的显隐。",
                    isOn: $showMenuBarIcon
                )
                .onChange(of: showMenuBarIcon) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "ShowMenuBarIcon")
                }
            }
        }

        // MARK: - 🟢 SHORTCUTS TAB
        private var shortcutsTab: some View {
            ScrollView {
                VStack(spacing: 16) {
                    shortcutConfigCard
                    shortcutsGuideCard
                }
                .padding(20)
            }
        }

        private var shortcutConfigCard: some View {
            settingsCard {
                cardTitle(icon: "keyboard", text: "全局快捷键")
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("呼出剪贴板")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.85))
                        Text("在全局任意地方呼出或隐藏剪贴板窗口。")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                    }
                    Spacer()
                    Button(action: {
                        if hotkeyManager.isRecording {
                            hotkeyManager.stopRecording()
                        } else {
                            hotkeyManager.startRecording()
                        }
                    }) {
                        HStack(spacing: 6) {
                            if hotkeyManager.isRecording {
                                HStack(spacing: 6) {
                                    Image(systemName: "record.circle")
                                        .foregroundColor(.red).font(.system(size: 14))
                                    Text("按下快捷键...")
                                        .font(.system(size: 14)).foregroundColor(.red)
                                        .padding(.vertical, 6)
                                }
                                .padding(.horizontal, 12)
                            } else {
                                let parts = hotkeyManager.config.displayString.components(separatedBy: " ")
                                ForEach(parts, id: \.self) { p in
                                    Text(p)
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(Color(white: 0.95))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color(nsColor: NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.48, alpha: 1.0)), lineWidth: 1.5)
                                        )
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .background(hotkeyManager.isRecording ? Color.red.opacity(0.1) : Color.clear)
                        .cornerRadius(8)
                        .overlay(
                            Group {
                                if hotkeyManager.isRecording {
                                    RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.4), lineWidth: 1.5)
                                }
                            }
                        )
                        .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .help(hotkeyManager.isRecording ? "" : "点击可更改快捷键组合")
                }
            }
        }

        private func shortcutKeycapView(config: HotkeyConfig) -> some View {
            let parts = config.displayString.components(separatedBy: " ")
            return HStack(spacing: 5) {
                ForEach(parts, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.95))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.48, alpha: 1.0)), lineWidth: 1.5)
                        )
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }

        private var shortcutsGuideCard: some View {
            settingsCard {
                cardTitle(icon: "list.bullet.rectangle", text: "快捷键说明")
                VStack(spacing: 0) {
                    shortcutGuideRow(label: "呼出 / 隐藏剪贴板历史", keycaps: hotkeyManager.config.displayString.components(separatedBy: " "))
                    sectionDivider()
                    shortcutGuideRow(label: "列表中导航上移", keycaps: ["↑"])
                    sectionDivider()
                    shortcutGuideRow(label: "列表中导航下移", keycaps: ["↓"])
                    sectionDivider()
                    shortcutGuideRow(label: "确认并粘贴所选项", keycaps: ["⏎"])
                    sectionDivider()
                    shortcutGuideRow(label: "预览选中的多媒体/大文本项目", keycaps: ["Space"])
                    sectionDivider()
                    shortcutGuideRow(label: "关闭弹窗", keycaps: ["Esc"])
                    sectionDivider()
                    shortcutGuideRow(label: "快速删除选中历史项目", keycaps: ["⌃", "⌫"])
                }
            }
        }

        private func shortcutGuideRow(label: String, keycaps: [String]) -> some View {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.8))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(keycaps, id: \.self) { k in
                        kbdBadge(k)
                    }
                }
            }
            .padding(.vertical, 6)
        }

        // MARK: - 🟡 STORAGE TAB
        private var storageTab: some View {
            ScrollView {
                VStack(spacing: 16) {
                    storageStatsCard
                    cleanupCard
                }
                .padding(20)
            }
        }

        private var storageStatsCard: some View {
            settingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 16))
                        .foregroundColor(Color.accentColor)
                    Text("存储统计")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.9))
                    Text("(\(backend.items.count) / \(Int(cleanupThreshold)))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
                    Spacer()
                }
                .padding(.bottom, 12)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            let w = geo.size.width
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0)))
                                    .frame(height: 12)
                                HStack(spacing: 0) {
                                    Color.accentColor
                                        .frame(width: w * textPct)
                                    Color.green
                                        .frame(width: w * imagePct)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 12)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .frame(height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.32, alpha: 1.0)), lineWidth: 1)
                        )
                        HStack(spacing: 16) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                Text("文本项目 (\(textCount))")
                                    .font(.system(size: 10)).foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                            }
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("图片项目 (\(imageCount))")
                                    .font(.system(size: 10)).foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已使用存储空间")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                        Text(formatStorageSize(backend.getStorageSize()))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(Color(white: 0.9))
                        Text("共 \(backend.items.count) 个剪贴板历史项目")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
                    }
                    .frame(width: 140)
                    .padding(.leading, 16)
                    .overlay(
                        Rectangle()
                            .fill(Color(nsColor: NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)))
                            .frame(width: 1),
                        alignment: .leading
                    )
                }
            }
        }

        private var cleanupCard: some View {
            settingsCard {
                cardTitle(icon: "trash", text: "清理与维护")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("自动清理阈值")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(white: 0.85))
                        Spacer()
                        Text("\(Int(cleanupThreshold)) 条")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                    Slider(value: $cleanupThreshold, in: 100...10000, step: 100) {
                        Text("")
                    } onEditingChanged: { editing in
                        if editing {
                            thresholdBeforeEdit = cleanupThreshold
                        } else if Int(cleanupThreshold) < backend.items.count {
                            pendingThreshold = Int(cleanupThreshold)
                            cleanupThreshold = thresholdBeforeEdit
                        } else {
                            backend.setCleanupThreshold(Int(cleanupThreshold))
                        }
                    }
                    GeometryReader { geo in
                        let w = geo.size.width
                        let minV: Double = 100
                        let maxV: Double = 10000
                        let range = maxV - minV
                        let ticks: [(String, Double)] = [
                            ("100", 100), ("500", 500), ("1k", 1000), ("1.5k", 1500),
                            ("2k", 2000), ("3k", 3000), ("5k", 5000), ("10k", 10000)
                        ]
                        ZStack(alignment: .topLeading) {
                            ForEach(ticks, id: \.0) { label, value in
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundColor(
                                        abs(cleanupThreshold - value) < 50
                                        ? Color.accentColor : Color(nsColor: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.53, alpha: 1.0))
                                    )
                                    .onTapGesture {
                                        let newVal = Int(value)
                                        if newVal < backend.items.count {
                                            thresholdBeforeEdit = cleanupThreshold
                                            pendingThreshold = newVal
                                        } else {
                                            cleanupThreshold = value
                                            backend.setCleanupThreshold(newVal)
                                        }
                                    }
                                    .position(x: w * (value - minV) / range, y: 4)
                            }
                        }
                    }
                    .frame(height: 14)
                }
                Text("当历史项目超过该阈值时，自动清理最早记录，以保护磁盘存储。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                    .padding(.top, 4)

                sectionDivider().padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button {
                        let total = backend.items.count
                        let estimated = Int((Double(total) * 0.4).rounded(.up))
                        guard total > 0 else { return }
                        let alert = NSAlert()
                        alert.messageText = "清理前 40% 的剪贴板历史?"
                        alert.informativeText = "将从 \(total) 条记录中移除最旧的 \(estimated) 条（约前 40%），且无法撤销。"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "确认清理")
                        alert.addButton(withTitle: "取消")
                        if alert.runModal() == .alertFirstButtonReturn {
                            let removed = backend.trimOldestPercent(40)
                            if removed > 0 { debugLog("Trimmed \(removed) oldest entries (40%)") }
                        }
                    } label: {
                        Label("清理前 40% 历史", systemImage: "arrow.up.trash")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.orange)

                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "清除所有剪贴板历史?"
                        alert.informativeText = "此操作会删除所有已保存的剪贴板记录，且无法撤销。"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "确认清除")
                        alert.addButton(withTitle: "取消")
                        if alert.runModal() == .alertFirstButtonReturn {
                            backend.clearHistory()
                        }
                    } label: {
                        Label("清除所有历史", systemImage: "trash")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .alert("确认调整清理阈值?", isPresented: Binding<Bool>(
                get: { pendingThreshold != nil },
                set: { if !$0 { pendingThreshold = nil } }
            )) {
                Button("确认调整") {
                    if let val = pendingThreshold {
                        cleanupThreshold = Double(val)
                        backend.setCleanupThreshold(val)
                    }
                    pendingThreshold = nil
                }
                Button("取消", role: .cancel) {
                    pendingThreshold = nil
                }
            } message: {
                if let val = pendingThreshold {
                    Text("当前已有 \(backend.items.count) 条记录。阈值降至 \(val) 条后，超出部分将被自动清理。是否继续？")
                }
            }
        }

        // MARK: - 🟣 IGNORE TAB
        private var ignoreTab: some View {
            ScrollView {
                VStack(spacing: 16) {
                    ignoreAppsCard
                    filterRulesCard
                }
                .padding(20)
            }
        }

        private var ignoreAppsCard: some View {
            settingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 16))
                        .foregroundColor(Color.accentColor)
                    Text("忽略的应用程序")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.9))
                    todoBadge
                    Spacer()
                }
                .padding(.bottom, 12)
                Text("来自已选应用所复制的内容，CopyAttach 将不做任何记录和收集。")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))

                VStack(spacing: 0) {
                    ForEach(ignoredApps, id: \.self) { app in
                        HStack {
                            Image(systemName: "lock.square")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text(app)
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.8))
                            Spacer()
                            Button {
                                ignoredApps.removeAll { $0 == app }
                                UserDefaults.standard.set(ignoredApps, forKey: "IgnoredApps")
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.5, green: 0.5, blue: 0.53, alpha: 1.0)))
                            }
                            .buttonStyle(.plain)
                            .opacity(0.7)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if app != ignoredApps.last {
                            sectionDivider()
                        }
                    }
                }
                .background(Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0)), lineWidth: 1)
                )

                if ignoredApps.isEmpty {
                    Text("暂无忽略的应用")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                HStack(spacing: 8) {
                    Picker("", selection: .constant("")) {
                        Text("选择想要忽略的应用...").tag("")
                        Text("Safari").tag("Safari")
                        Text("Google Chrome").tag("Google Chrome")
                        Text("Terminal").tag("Terminal")
                        Text("Slack").tag("Slack")
                        Text("微信 (WeChat)").tag("WeChat")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .font(.system(size: 12))

                    Button("添加") {
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }
            }
        }

        private var filterRulesCard: some View {
            settingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 16))
                        .foregroundColor(Color.accentColor)
                    Text("过滤规则")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.9))
                    todoBadge
                    Spacer()
                }
                .padding(.bottom, 12)

                HStack {
                    Toggle(isOn: $ignoreShortText) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("忽略小于三个字符的文本")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.8))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: ignoreShortText) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "IgnoreShortText")
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("阈值:")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.62, alpha: 1.0)))
                        Picker("", selection: $shortTextThreshold) {
                            Text("2 个字符").tag(2)
                            Text("3 个字符").tag(3)
                            Text("5 个字符").tag(5)
                            Text("10 个字符").tag(10)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                        .font(.system(size: 11))
                    }
                    .opacity(ignoreShortText ? 1 : 0.5)
                }

                sectionDivider().padding(.vertical, 4)

                HStack {
                    Toggle(isOn: $ignoreProtectedWindows) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("忽略复制自受保护窗口的内容")
                                .font(.system(size: 12))
                                .foregroundColor(Color(white: 0.8))
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: ignoreProtectedWindows) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "IgnoreProtectedWindows")
                    }
                    Spacer()
                    Text("对密码输入框及无痕浏览窗口自动排除")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
                        .frame(maxWidth: 140, alignment: .trailing)
                }
            }
        }

        // MARK: - ⚪ ABOUT TAB
        private var aboutTab: some View {
            ScrollView {
                VStack(spacing: 16) {
                    Image(nsImage: .appIcon)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                    VStack(spacing: 4) {
                        Text("CopyAttach")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color(white: 0.9))
                        Text("版本 v\(appVersion)")
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
                    }

                    Text("CopyAttach 是一款轻量、快捷的 macOS 全局剪贴板与附件管理工具，专注于提升开发者及科研人员的工作流吞吐效率。")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.7, green: 0.7, blue: 0.73, alpha: 1.0)))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 300)

                    HStack(spacing: 12) {
                        Button("检查更新") {}
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .buttonStyle(.plain)
                        Button("官方网站") {}
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color(nsColor: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)))
                            .foregroundColor(Color(white: 0.8))
                            .cornerRadius(6)
                            .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(40)
                .frame(maxWidth: .infinity)
            }
        }

        // MARK: - Reusable Components

        private func cardTitle(icon: String, text: String) -> some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(Color.accentColor)
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.9))
                Spacer()
            }
            .padding(.bottom, 12)
        }

        private func settingToggleRow(icon: String, iconColor: Color, title: String, desc: String, isOn: Binding<Bool>) -> some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(white: 0.85))
                    Text(desc)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)))
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }

        private func sectionDivider() -> some View {
            Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.26, alpha: 1.0))
                .frame(height: 1)
        }

        private var todoBadge: some View {
            Text("TODO")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(red: 0.92, green: 0.58, blue: 0.20))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color(red: 0.92, green: 0.58, blue: 0.20).opacity(0.15))
                .cornerRadius(4)
        }
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

        let content = NSHostingController(rootView: InlineSettingsView())
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
