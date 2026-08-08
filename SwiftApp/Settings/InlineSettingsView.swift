import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Inline Settings View

struct InlineSettingsView: View {
    @State var backend = ClipboardBackend.shared
    @State var hotkeyManager = HotkeyManager.shared
    @State private var selectedTab: Int
    @State var launchAtLogin = UserDefaults.standard.bool(forKey: "LaunchAtLogin")
    @State var runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
    @State var showMenuBarIcon = UserDefaults.standard.bool(forKey: "ShowMenuBarIcon") != false
    @State var cleanupThreshold: Double = {
        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        return Double(saved >= 100 ? saved : 3000)
    }()
    @State var ignoredAppBundleIDs = UserDefaults.standard.stringArray(forKey: "IgnoredAppBundleIDs") ?? []
    @State var ignoreTextClipboardType = UserDefaults.standard.bool(forKey: "IgnoreTextClipboardType")
    @State var ignoreImageClipboardType = UserDefaults.standard.bool(forKey: "IgnoreImageClipboardType")
    @State var ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
    @State var shortTextThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold") != 0 ? UserDefaults.standard.integer(forKey: "ShortTextThreshold") : 3
    @State var pendingThreshold: Int? = nil
    @State var thresholdBeforeEdit: Double = 3000
    @State var closePopupAfterDrag = HistoryPopupWindow.closePopupAfterDragEnabled
    @State var showDragGuide = false
    @State var isHoveringDragIcon = false
    @State var updateState: UpdateCheckState = .idle
    @Environment(\.appTheme) var theme

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Update Check

    enum UpdateCheckState: Equatable, Identifiable {
        case idle
        case checking
        case upToDate(currentVersion: String)
        case updateAvailable(latestVersion: String, releaseURL: URL, isDowngrade: Bool)
        case error(String)

        var id: String {
            switch self {
            case .idle: return "idle"
            case .checking: return "checking"
            case .upToDate: return "upToDate"
            case .updateAvailable: return "updateAvailable"
            case .error: return "error"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
                .frame(height: 1)
                .background(theme.divider)
            tabContent
        }
        .frame(width: 520, height: 600)
        .background(theme.background)
    }

    var textCount: Int { backend.items.filter { $0.isText }.count }
    var imageCount: Int { backend.items.filter { $0.isImage }.count }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    private let tabTitles = ["通用", "快捷键", "存储", "忽略", "许可证", "关于"]
    private let tabIcons = ["gearshape", "keyboard", "externaldrive", "eye.slash", "key", "info.circle"]

    // MARK: - Tab Bar
    @State private var hoveredTab: Int? = nil

    private var tabBar: some View {
        HStack(spacing: 4) {
            Spacer()
            ForEach(0..<6, id: \.self) { i in
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
                        : hoveredTab == i ? theme.popupRowHover : Color.clear
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
                    ? theme.secondaryText
                    : theme.tertiaryText
                )
                .onHover { hovering in
                    hoveredTab = hovering ? i : nil
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .background(theme.tabBackground)
    }

    // MARK: - Tab Content Router
    private var tabContent: some View {
        Group {
            if selectedTab == 0 { generalTab }
            else if selectedTab == 1 { shortcutsTab }
            else if selectedTab == 2 { storageTab }
            else if selectedTab == 3 { ignoreTab }
            else if selectedTab == 4 { LicenseSettingsView() }
            else { aboutTab }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reusable Components

    func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(theme.cardBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
    }

    func kbdBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(theme.buttonBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.cardBorder, lineWidth: 1)
            )
            .cornerRadius(5)
    }

    func formatStorageSize(_ bytes: Int64) -> String {
        let bc = Double(bytes)
        switch bc {
        case 0: return "0 B"
        case ..<1024: return "\(Int(bc)) B"
        case ..<(1024 * 1024): return String(format: "%.1f KB", bc / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", bc / (1024 * 1024))
        default: return String(format: "%.1f GB", bc / (1024 * 1024 * 1024))
        }
    }

    func cardTitle(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Color.accentColor)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
        }
        .padding(.bottom, 12)
    }

    func settingToggleRow(icon: String, iconColor: Color, title: String, desc: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    func sectionDivider() -> some View {
        theme.divider
            .frame(height: 1)
    }
}
