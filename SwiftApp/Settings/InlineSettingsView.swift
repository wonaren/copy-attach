import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct InlineSettingsView: View {
    @State var backend = ClipboardBackend.shared
    @State var hotkeyManager = HotkeyManager.shared
    @State private var selectedTab: Int
    @State var launchAtLogin = UserDefaults.standard.bool(forKey: "LaunchAtLogin")
    @State var runInBackground = UserDefaults.standard.object(forKey: "RunInBackground") as? Bool ?? true
    @State var autoPasteAtCursor = PasteDeliveryMode.current == .keystroke
    @State var showMenuBarIcon = UserDefaults.standard.object(forKey: "ShowMenuBarIcon") as? Bool ?? true
    @State var cleanupThreshold: Double = {
        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        return Double(saved >= 100 ? saved : 3000)
    }()
    @State var ignoredAppBundleIDs = UserDefaults.standard.stringArray(forKey: "IgnoredAppBundleIDs") ?? []
    @State var ignoreSensitive = UserDefaults.standard.object(forKey: "IgnoreSensitiveClipboard") as? Bool ?? true
    @State var ignoreTextClipboardType = UserDefaults.standard.bool(forKey: "IgnoreTextClipboardType")
    @State var ignoreImageClipboardType = UserDefaults.standard.bool(forKey: "IgnoreImageClipboardType")
    @State var ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
    @State var shortTextThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold") > 0 ? UserDefaults.standard.integer(forKey: "ShortTextThreshold") : 3
    @State var pendingThreshold: Int? = nil
    @State var thresholdBeforeEdit: Double = 3000
    @State var undoBudgetChoiceCache: UndoBudgetChoice = UndoBudgetChoice.nearest(
        to: ClipboardBackend.shared.undoLimit()
    )
    @AppStorage(HistoryPopupContent.undoEvictionWarningKey) var undoEvictionWarningDisabled = true
    @State var continuousDrag = HistoryPopupWindow.continuousDragEnabled
    @State var richTextDragApps = ClipboardBackend.richTextDragAppBundleIDs
    @State var isDraggingOverRichTextCard = false
    @State var showRichTextListSheet = false
    @State var isDraggingOverIgnoreSheet = false
    @State var showIgnoredAppsSheet = false
    @State var debugLogging = UserDefaults.standard.object(forKey: "DebugLogging") as? Bool ?? (clipboard_is_debug_logging() != 0)
    @State var showDragGuide = false
    @State var isHoveringDragIcon = false
    @State var backupStatusMessage: String? = nil
    @State var updateState: UpdateCheckState = .idle
    @State var isCheckingUpdate = false
    @State var updateAlert: UpdateCheckState? = nil
    @StateObject var updater = UpdateDownloader.shared
    var updateBadge: UpdateBadge { UpdateBadge.shared }
    @Environment(\.appTheme) var theme
    @Environment(\.colorScheme) var colorScheme

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    enum UpdateCheckState: Equatable, Identifiable {
        case idle
        case upToDate(currentVersion: String)
        case updateAvailable(latestVersion: String, releaseURL: URL, isDowngrade: Bool)
        case error(String)

        var id: String {
            switch self {
            case .idle: return "idle"
            case .upToDate: return "upToDate"
            case .updateAvailable: return "updateAvailable"
            case .error: return "error"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            tabContent
        }
        .frame(width: 520, height: 600)
        .background(theme.background)
        .task(id: backend.permissionGranted) {
            guard !backend.permissionGranted else { return }
            while !Task.isCancelled && !backend.permissionGranted {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { break }
                backend.refreshPermission()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            backend.refreshPermission()
        }
    }

    var textCount: Int { backend.items.filter { $0.isText }.count }
    var imageCount: Int { backend.items.filter { $0.isImage }.count }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    private let tabTitles = ["通用", "快捷键", "存储", "忽略", "关于"]
    private let tabIcons = ["gearshape", "keyboard", "externaldrive", "eye.slash", "info.circle"]

    @State private var hoveredTab: Int? = nil
    @Namespace private var tabGlassNamespace

    private let tabCornerRadius: CGFloat = 10

    @ViewBuilder
    private var liquidGlassSelectedBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tabCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45), location: 0.0),
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.03 : 0.15), location: 0.5),
                            .init(color: Color.clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: tabCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.70 : 0.90), location: 0.0),
                            .init(color: Color.white.opacity(colorScheme == .dark ? 0.25 : 0.35), location: 0.25),
                            .init(color: Color.clear, location: 0.55),
                            .init(color: colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.15), location: 1.0)
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1.2
                )
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 3, x: 0, y: 1.5)
    }

    @available(macOS 26.0, *)
    private var selectionGlass: Glass {
        .regular
            .tint(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18))
            .interactive()
    }

    @ViewBuilder
    private func tabItemBackground(for index: Int) -> some View {
        if selectedTab == index {
            if #available(macOS 26.0, *) {
                EmptyView()
            } else {
                liquidGlassSelectedBackground
                    .matchedGeometryEffect(id: "settingsSelectedTab", in: tabGlassNamespace)
            }
        } else if hoveredTab == index {
            RoundedRectangle(cornerRadius: tabCornerRadius, style: .continuous)
                .fill(theme.popupRowHover)
                .transition(.opacity)
        }
    }

    private func tabItemCore(_ i: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tabIcons[i])
                .font(.system(size: 17, weight: .medium))
                .symbolVariant(selectedTab == i ? .fill : .none)
                .frame(width: 22, height: 20)
                .overlay(alignment: .topTrailing) {
                    if i == 4, updateBadge.hasUnseenUpdate {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -1)
                    }
                }
            Text(tabTitles[i])
                .font(.system(size: 11, weight: selectedTab == i ? .semibold : .medium))
                .lineLimit(1)
        }
        .frame(width: 68, height: 48)
    }

    @ViewBuilder
    private func tabItemLabel(_ i: Int) -> some View {
        if #available(macOS 26.0, *), selectedTab == i {
            tabItemCore(i)
                .glassEffect(
                    selectionGlass,
                    in: RoundedRectangle(cornerRadius: tabCornerRadius, style: .continuous)
                )
                .glassEffectID("tabSelection", in: tabGlassNamespace)
        } else {
            tabItemCore(i)
        }
    }

    private var tabButtons: some View {
        HStack(spacing: 4) {
            Spacer()
            ForEach(tabTitles.indices, id: \.self) { i in
                Button {
                    withAnimation(.smooth(duration: 0.3)) {
                        selectedTab = i
                    }
                    if i == 4 { updateBadge.markSeen() }
                } label: {
                    tabItemLabel(i)
                        .contentShape(RoundedRectangle(cornerRadius: tabCornerRadius, style: .continuous))
                        .background { tabItemBackground(for: i) }
                }
                .buttonStyle(.plain)
                .foregroundColor(
                    selectedTab == i
                    ? Color.accentColor
                    : hoveredTab == i
                    ? theme.primaryText
                    : theme.secondaryText
                )
                .onHover { hovering in
                    hoveredTab = hovering ? i : nil
                }
            }
            Spacer()
        }
    }

    private var tabBar: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    tabButtons
                }
            } else {
                tabButtons
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hoveredTab)
        .padding(.top, 8)
        .background(theme.tabBackground)
    }

    private var tabContent: some View {
        Group {
            if selectedTab == 0 { generalTab }
            else if selectedTab == 1 { shortcutsTab }
            else if selectedTab == 2 { storageTab }
            else if selectedTab == 3 { ignoreTab }
            else { aboutTab }
        }
        .id(selectedTab)
        .transition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    func sectionDivider() -> some View {
        theme.divider
            .frame(height: 1)
    }
}
