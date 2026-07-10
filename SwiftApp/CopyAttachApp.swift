import AppKit
import SwiftUI

/// Main entry point for the CopyAttach macOS app.
@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar
        MenuBarExtra("Clipboard", systemImage: "clipboard") {
            Button("打开主界面 (Open CopyAttach)") {
                AppDelegate.shared?.openSettings()
            }
            Divider()
            Button("Show History (\(HotkeyManager.shared.config.displayString))") {
                AppDelegate.shared?.togglePopup()
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
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
        ClipboardBackend.shared.start()
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
                Text("📋 CopyAttach").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
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
                        Text(backend.permissionGranted ? "Accessibility: Granted" : "Accessibility: Not Granted")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(backend.permissionGranted ? .green : .orange)
                        Text(backend.permissionGranted
                             ? "Press \(hotkeyManager.config.displayString) to open clipboard history."
                             : "The app needs Accessibility permissions for global hotkey detection and auto-paste.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                if !backend.permissionGranted {
                    Button(action: { backend.openPreferences() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield")
                            Text("Open System Settings → Grant Permission").font(.system(size: 12))
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
                HStack(spacing: 14) {
                    Image(systemName: "keyboard").font(.system(size: 20)).foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Global Shortcut Key").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("Customize the keyboard shortcut to show clipboard history.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                VStack(spacing: 12) {
                    HStack {
                        Text("Current shortcut:").font(.system(size: 12)).foregroundColor(.secondary)
                        Text(hotkeyManager.config.displayString)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(nsColor: .darkGray).opacity(0.5)).cornerRadius(6)
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        if hotkeyManager.isRecording {
                            HStack {
                                Image(systemName: "record.circle").foregroundColor(.red)
                                Text("Press new shortcut...").font(.system(size: 12, weight: .medium)).foregroundColor(.red)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.red.opacity(0.1)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.5), lineWidth: 1))
                            Button("Cancel") { hotkeyManager.stopRecording() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            Button(action: { hotkeyManager.startRecording() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch")
                                    Text("Change Shortcut")
                                }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                            }.buttonStyle(.borderedProminent).tint(Color(nsColor: .darkGray))
                            Button("Reset") { hotkeyManager.resetToDefault() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }.padding(.top, 8)
            }
        }
        
        private var generalCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(.gray)
                    Text("General").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                }
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: launchAtLogin ? "power.circle.fill" : "power.circle")
                            .foregroundColor(launchAtLogin ? .green : .secondary).font(.system(size: 14))
                        Text("Launch at Login").font(.system(size: 12)).foregroundColor(.white)
                        Spacer()
                        Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).controlSize(.small)
                            .onChange(of: launchAtLogin) { _, newValue in setLaunchAtLogin(newValue) }
                    }
                    Divider().background(Color.gray.opacity(0.3))
                    HStack {
                        Image(systemName: runInBackground ? "circle.fill" : "circle")
                            .foregroundColor(runInBackground ? .green : .secondary).font(.system(size: 14))
                        Text("Run in Background").font(.system(size: 12)).foregroundColor(.white)
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
                    Text("Statistics").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                }
                VStack(spacing: 6) {
                    statRow("Total Items", "\(backend.items.count)")
                    statRow("Text Items", "\(textCount)")
                    statRow("Image Items", "\(imageCount)")
                    statRow("Max Capacity", "1,000")
                }.padding(.top, 8)
            }
        }
        
        private var tipsCard: some View {
            settingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "lightbulb.fill").font(.system(size: 20)).foregroundColor(.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usage Tips").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("• Press \(hotkeyManager.config.displayString) to show/hide clipboard history\n• ↑↓ to navigate, Enter to select and paste\n• Esc to close the popup\n• Click an item to copy and paste it")
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
