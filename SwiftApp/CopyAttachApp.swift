import AppKit
import SwiftUI

/// Main entry point for the CopyAttach macOS app.
@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar
        MenuBarExtra("剪贴板", systemImage: "clipboard") {
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
        @State private var launchAtLogin = UserDefaults.standard.bool(forKey: "LaunchAtLogin")
        @State private var runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
        
        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    permissionCard
                    hotkeyCard
                    generalCard
                    statsCard
                    tipsCard
                }
                .padding(16)
            }
            .frame(width: 420, height: 620)
            .background(Color(NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)))
        }
        
        private var textCount: Int { backend.items.filter { $0.isText }.count }
        private var imageCount: Int { backend.items.filter { $0.isImage }.count }
        
        private var header: some View {
            HStack {
                Image(nsImage: .appIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text("CopyAttach").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                Spacer()
            }
        }
        
        private var permissionCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: backend.permissionGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 20))
                        .foregroundColor(backend.permissionGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backend.permissionGranted ? "辅助功能：已授权" : "辅助功能：未授权")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(backend.permissionGranted ? .green : .orange)
                        Text(backend.permissionGranted
                             ? "按 \(hotkeyManager.config.displayString) 打开剪贴板历史"
                             : "应用需要辅助功能权限才能使用全局快捷键和自动粘贴")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if !backend.permissionGranted {
                    Button(action: { backend.openPreferences() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield")
                            Text("打开系统设置 → 授予权限").font(.system(size: 12))
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.75, alpha: 1.0)))
                    .padding(.top, 8)
                }
            }
        }
        
        private var hotkeyCard: some View {
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "keyboard").font(.system(size: 18)).foregroundColor(.blue)
                        Text("全局快捷键").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text("呼出剪贴板：").font(.system(size: 12)).foregroundColor(.secondary)
                        if hotkeyManager.isRecording {
                            Button(action: { hotkeyManager.stopRecording() }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "record.circle").foregroundColor(.red).font(.system(size: 10))
                                    Text("按下快捷键...").font(.system(size: 13)).foregroundColor(.red)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.red.opacity(0.1)).cornerRadius(5)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red.opacity(0.5), lineWidth: 1))
                            }.buttonStyle(.plain)
                        } else {
                            Button(action: { hotkeyManager.startRecording() }) {
                                Text(hotkeyManager.config.displayString)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color(nsColor: .darkGray)).cornerRadius(5)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
            }
        }
        
        private var generalCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(.gray)
                    Text("通用").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                }
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: launchAtLogin ? "power.circle.fill" : "power.circle")
                            .foregroundColor(launchAtLogin ? .green : .secondary).font(.system(size: 14))
                        Text("开机启动").font(.system(size: 12)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).controlSize(.small)
                            .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                    }
                    Divider().background(Color.gray.opacity(0.3))
                    HStack {
                        Image(systemName: runInBackground ? "circle.fill" : "circle")
                            .foregroundColor(runInBackground ? .green : .secondary).font(.system(size: 14))
                        Text("后台运行").font(.system(size: 12)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $runInBackground).toggleStyle(.switch).controlSize(.small)
                            .onChange(of: runInBackground) { _, newValue in setRunInBackground(newValue) }
                    }
                }.padding(.top, 8)
            }
        }
        
        private var statsCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "chart.bar.fill").font(.system(size: 20)).foregroundColor(.green)
                    Text("统计数据").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                }
                VStack(spacing: 6) {
                    statRow("总项目数", "\(backend.items.count)")
                    statRow("文本项目数", "\(textCount)")
                    statRow("图片项目数", "\(imageCount)")
                    statRow("已使用存储空间", formatStorageSize(backend.getStorageSize()))
                    statRow("自动清理阈值", "3,000")
                }.padding(.top, 8)
                Divider().background(Color.gray.opacity(0.3)).padding(.vertical, 8)
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
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("清除所有历史").font(.system(size: 12))
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.red.opacity(0.7))
            }
        }
        
        private var tipsCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "lightbulb.fill").font(.system(size: 20)).foregroundColor(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("使用技巧").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("• 按 \(hotkeyManager.config.displayString) 显示/隐藏剪贴板历史\n• ↑↓ 导航，回车选择并粘贴\n• Esc 关闭弹出窗口\n• 点击项目即可复制并粘贴")
                            .font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(3)
                    }
                    Spacer()
                }
            }
        }
        
        // Helpers
        private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(14).frame(maxWidth: .infinity)
                .background(Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)))
                .cornerRadius(10)
        }
        
        private func formatStorageSize(_ bytes: Int64) -> String {
            let byteCount = Double(bytes)
            switch byteCount {
            case 0: return "0 B"
            case ..<1024: return "\(Int(byteCount)) B"
            case ..<(1024 * 1024): return String(format: "%.1f KB", byteCount / 1024)
            case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", byteCount / (1024 * 1024))
            default: return String(format: "%.1f GB", byteCount / (1024 * 1024 * 1024))
            }
        }

        private func statRow(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
        }
        
        private func setLaunchAtLogin(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: "LaunchAtLogin")
        }
        
        private func setRunInBackground(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: "RunInBackground")
            if !enabled { NSApp.terminate(nil) }
        }
    }

    private func createSettingsWindow() {
        debugLog("Creating settings window...")
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CopyAttach"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        
        let content = NSHostingController(rootView: InlineSettingsView())
        content.view.frame = NSRect(x: 0, y: 0, width: 420, height: 620)
        content.view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        window.contentViewController = content
        
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
        debugLog("Created settings window with InlineSettingsView")
    }
}
