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
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            AppMenuBarContent()
        } label: {
            if let img = menuBarIcon() {
                Image(nsImage: img)
            } else {
                Image(systemName: "clipboard")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu Bar Icon

/// Cached template icon for the menu bar. The icon never changes while the
/// process runs; parsing the SVG again on every Scene body evaluation is
/// wasted IO and CoreSVG work.
private let cachedMenuBarIcon: NSImage? = {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar-stack.svg"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = true
    return img
}()

private func menuBarIcon() -> NSImage? {
    cachedMenuBarIcon
}

/// Menu bar content that dynamically observes hotkey changes
struct AppMenuBarContent: View {
    @State private var hotkeyManager = HotkeyManager.shared
    @State private var licenseManager = LicenseManager.shared

    var body: some View {
        if licenseManager.state.permitsCoreFeatures {
            Button("偏好设置") { AppDelegate.shared?.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("许可证…") { AppDelegate.shared?.openLicenseWindow() }
            Divider()
            Button("显示历史记录 (\(hotkeyManager.config.displayString))") { AppDelegate.shared?.togglePopup() }
        } else {
            Button("激活 CopyAttach…") { AppDelegate.shared?.openLicenseWindow() }
        }
        Divider()
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
