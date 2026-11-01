import AppKit
import SwiftUI
import ServiceManagement

@main
struct ClipboardManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("ShowMenuBarIcon") private var showMenuBarIcon = true

    init() {
        AppDelegate.terminateIfDuplicateInstance()
    }

    var body: some Scene {
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

private let cachedMenuBarIcon: NSImage? = {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar-stack.svg"),
          let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = true
    return img
}()

private func menuBarIcon() -> NSImage? {
    cachedMenuBarIcon
}

struct AppMenuBarContent: View {
    @State private var hotkeyManager = HotkeyManager.shared
    @State private var onboarding = OnboardingGuide.shared

    var body: some View {
        Button("偏好设置") { AppDelegate.shared?.openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        if onboarding.isActive {
            Button("结束新手引导") { onboarding.skip() }
        } else {
            Button("新手引导") { onboarding.restart() }
        }
        Divider()
        Button("显示历史记录 (\(hotkeyManager.config.displayString))") { AppDelegate.shared?.togglePopup() }
        Divider()
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
