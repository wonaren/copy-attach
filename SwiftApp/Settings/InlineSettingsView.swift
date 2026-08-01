import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Inline Settings View

struct InlineSettingsView: View {
    @StateObject private var backend = ClipboardBackend.shared
    @StateObject private var hotkeyManager = HotkeyManager.shared
    @State private var selectedTab: Int
    @State private var launchAtLogin = UserDefaults.standard.bool(forKey: "LaunchAtLogin")
    @State private var runInBackground = UserDefaults.standard.bool(forKey: "RunInBackground") != false
    @State private var showMenuBarIcon = UserDefaults.standard.bool(forKey: "ShowMenuBarIcon") != false
    @State private var cleanupThreshold: Double = {
        let saved = UserDefaults.standard.integer(forKey: "CleanupThreshold")
        return Double(saved >= 100 ? saved : 3000)
    }()
    @State private var ignoredAppBundleIDs = UserDefaults.standard.stringArray(forKey: "IgnoredAppBundleIDs") ?? []
    @State private var ignoreTextClipboardType = UserDefaults.standard.bool(forKey: "IgnoreTextClipboardType")
    @State private var ignoreImageClipboardType = UserDefaults.standard.bool(forKey: "IgnoreImageClipboardType")
    @State private var ignoreShortText = UserDefaults.standard.bool(forKey: "IgnoreShortText")
    @State private var shortTextThreshold = UserDefaults.standard.integer(forKey: "ShortTextThreshold") != 0 ? UserDefaults.standard.integer(forKey: "ShortTextThreshold") : 3
    @State private var pendingThreshold: Int? = nil
    @State private var thresholdBeforeEdit: Double = 3000
    @State private var imagePasteUseCtrlV = UserDefaults.standard.bool(forKey: "ImagePasteUseCtrlV")
    @State private var closePopupAfterDrag = HistoryPopupWindow.closePopupAfterDragEnabled
    @State private var showDragGuide = false
    @State private var isHoveringDragIcon = false
    @State private var updateState: UpdateCheckState = .idle
    @Environment(\.appTheme) private var theme

    init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Update Check

    private enum UpdateCheckState: Equatable, Identifiable {
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

    // MARK: - Helpers
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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

    private func kbdBadge(_ text: String) -> some View {
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
            if !backend.permissionGranted {
                Text("应用需要辅助功能权限才能使用全局快捷键和自动粘贴")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }
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
                    Image(nsImage: .appIconSVG ?? .appIcon)
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
                        .foregroundColor(theme.primaryText)
                    Text("已打开「系统设置 → 隐私与安全性 → 辅助功能」")
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.secondaryText)
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
                        .foregroundColor(theme.tertiaryText)
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
            }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(
                icon: "arrow.up.doc",
                iconColor: imagePasteUseCtrlV ? .orange : .secondary,
                title: "终端图片使用 Ctrl+V 粘贴(适配ClaudeCode)",
                desc: "在 Ghostty、iTerm2、Kitty 等终端中粘贴图片时发送 Ctrl+V（对其他应用无影响）。",
                isOn: $imagePasteUseCtrlV
            )
            .onChange(of: imagePasteUseCtrlV) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "ImagePasteUseCtrlV")
                backend.syncImagePasteModifier()
            }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(
                icon: closePopupAfterDrag ? "hand.draw.fill" : "hand.draw",
                iconColor: closePopupAfterDrag ? Color.accentColor : .secondary,
                title: "拖拽后自动关闭弹窗",
                desc: "将历史条目拖拽到其他应用后自动关闭弹窗；关闭此开关可连续拖拽多个条目。",
                isOn: $closePopupAfterDrag
            )
            .onChange(of: closePopupAfterDrag) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: HistoryPopupWindow.closePopupAfterDragDefaultsKey)
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
                        .foregroundColor(theme.primaryText)
                    Text("在全局任意地方呼出或隐藏剪贴板窗口。")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
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
                                    .foregroundColor(theme.buttonText)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(theme.buttonBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(theme.buttonBorder, lineWidth: 1.5)
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
                    .foregroundColor(theme.buttonText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.buttonBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.buttonBorder, lineWidth: 1.5)
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
                shortcutGuideRow(label: "选择条目", keycaps: ["↑","↓"])
                sectionDivider()
                shortcutGuideRow(label: "确认并粘贴", keycaps: ["⏎"])
                sectionDivider()
                shortcutGuideRow(label: "预览 / 关闭预览", keycaps: ["Space"])
                sectionDivider()
                shortcutGuideRow(label: "关闭弹窗", keycaps: ["Esc"])
                sectionDivider()
                shortcutGuideRow(label: "切换Tab", keycaps: ["←", "→"])
                sectionDivider()
                shortcutGuideRow(label: "收藏 / 取消收藏", keycaps: ["⌥", "P"])
                sectionDivider()
                shortcutGuideRow(label: "快速删除选中条目", keycaps: ["⌃", "⌫"])
                sectionDivider()
                shortcutGuideRow(label: "撤销删除(最多10步)", keycaps: ["⌘", "Z"])
                sectionDivider()
                shortcutGuideRow(label: "快速选择第 1 ~ 9 项", keycaps: ["⌘", "1~9"])
            }
        }
    }

    private func shortcutGuideRow(label: String, keycaps: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
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
                    .foregroundColor(theme.primaryText)
                Text("(\(backend.items.count) / \(Int(cleanupThreshold)))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
            }
            .padding(.bottom, 12)
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        let w = geo.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.cardBorder)
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
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
                    HStack(spacing: 16) {
                        HStack(spacing: 5) {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            Text("文本项目 (\(textCount))")
                                .font(.system(size: 10)).foregroundColor(theme.secondaryText)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("图片项目 (\(imageCount))")
                                .font(.system(size: 10)).foregroundColor(theme.secondaryText)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("已使用存储空间")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Text(formatStorageSize(backend.getStorageSize()))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text("共 \(backend.items.count) 个剪贴板历史项目")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(width: 140)
                .padding(.leading, 16)
                .overlay(
                    Rectangle()
                        .fill(theme.divider)
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
                        .foregroundColor(theme.primaryText)
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
                                    ? Color.accentColor : theme.tertiaryText
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
                .foregroundColor(theme.secondaryText)
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
            cardTitle(icon: "app.badge", text: "按应用忽略")
            Text("匹配应用的 bundle identifier；在读取剪贴板内容之前跳过，因此不会写入内存或数据库。")
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)

            VStack(spacing: 0) {
                if ignoredAppBundleIDs.isEmpty {
                    Text("未设置应用规则")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    ForEach(ignoredAppBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 12))
                                .foregroundColor(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(applicationName(for: bundleID))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                Text(bundleID)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            Spacer()
                            Button {
                                ignoredAppBundleIDs.removeAll { $0 == bundleID }
                                persistIgnoreRules()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        if bundleID != ignoredAppBundleIDs.last { sectionDivider() }
                    }
                }
            }
            .background(theme.background)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder, lineWidth: 1))

            Button(action: chooseIgnoredApplication) {
                Label("选择应用…", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
            .padding(.top, 10)
        }
    }

    private var filterRulesCard: some View {
        settingsCard {
            cardTitle(icon: "line.3.horizontal.decrease", text: "按类型与特点忽略")
            settingToggleRow(icon: "textformat", iconColor: .accentColor, title: "忽略文本", desc: "不记录任何纯文本剪贴板内容。", isOn: $ignoreTextClipboardType)
                .onChange(of: ignoreTextClipboardType) { _, _ in persistIgnoreRules() }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(icon: "photo", iconColor: .green, title: "忽略图片", desc: "不读取、编码或存储图片剪贴板内容。", isOn: $ignoreImageClipboardType)
                .onChange(of: ignoreImageClipboardType) { _, _ in persistIgnoreRules() }
            sectionDivider().padding(.vertical, 4)

            HStack {
                Toggle(isOn: $ignoreShortText) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("忽略小于 \(shortTextThreshold) 个字符的文本")
                            .font(.system(size: 12))
                            .foregroundColor(theme.primaryText)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: ignoreShortText) { _, _ in persistIgnoreRules() }
                Spacer()
                HStack(spacing: 4) {
                    Text("阈值:")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
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
                .onChange(of: shortTextThreshold) { _, _ in persistIgnoreRules() }
            }
        }
    }

    private func applicationName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseIgnoredApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        guard !ignoredAppBundleIDs.contains(bundleID) else { return }
        ignoredAppBundleIDs.append(bundleID)
        persistIgnoreRules()
    }

    private func persistIgnoreRules() {
        UserDefaults.standard.set(ignoredAppBundleIDs, forKey: "IgnoredAppBundleIDs")
        UserDefaults.standard.set(ignoreTextClipboardType, forKey: "IgnoreTextClipboardType")
        UserDefaults.standard.set(ignoreImageClipboardType, forKey: "IgnoreImageClipboardType")
        UserDefaults.standard.set(ignoreShortText, forKey: "IgnoreShortText")
        UserDefaults.standard.set(shortTextThreshold, forKey: "ShortTextThreshold")
        backend.syncIgnoreRules()
    }

    // MARK: - ⚪ ABOUT TAB
    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: .appIconSVG ?? .appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                VStack(spacing: 6) {
                    Text("CopyAttach")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    HStack(spacing: 5) {
                        Text("版本")
                            .foregroundColor(theme.secondaryText)
                        Text("v\(appVersion)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                    }
                    .font(.system(size: 13))

                    Button {
                        NSWorkspace.shared.open(authorGitHubURL)
                    } label: {
                        HStack(spacing: 5) {
                            if let img = githubIconImage() {
                                Image(nsImage: img)
                                    .resizable()
                                    .frame(width: 13, height: 13)
                            }
                            Text("wonaren")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("github.com/wonaren")
                }

                Text("CopyAttach 是一款极轻量的剪贴板历史管理应用,它在性能体验、内存占用、存储效率、功耗表现、操作逻辑、UI界面都经过精心设计,旨在为用户提供一个简洁、高效、无负担的剪贴板历史管理工具。")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 300)

                HStack(spacing: 12) {
                    Button(action: checkForUpdates) {
                        if case .checking = updateState {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                                Text("检查中…")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        } else {
                            Text("检查更新")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .disabled(updateState == .checking)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .alert(item: alertBinding) { result in
            switch result {
            case .upToDate(let version):
                return Alert(
                    title: Text("已是最新版本"),
                    message: Text("当前版本 v\(version) 已是最新"),
                    dismissButton: .default(Text("好的"))
                )
            case .updateAvailable(let latestVersion, let releaseURL, let isDowngrade):
                if isDowngrade {
                    return Alert(
                        title: Text("正式版可用 v\(latestVersion)"),
                        message: Text("当前为开发版本 v\(appVersion)\n是否切换到正式版？"),
                        primaryButton: .default(Text("前往下载")) {
                            NSWorkspace.shared.open(releaseURL)
                        },
                        secondaryButton: .cancel(Text("继续使用开发版"))
                    )
                } else {
                    return Alert(
                        title: Text("发现新版本 v\(latestVersion)"),
                        message: Text("当前版本：v\(appVersion)\n是否前往下载页面？"),
                        primaryButton: .default(Text("前往下载")) {
                            NSWorkspace.shared.open(releaseURL)
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                }
            case .error(let message):
                return Alert(
                    title: Text("检查更新失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好的"))
                )
            case .idle, .checking:
                // Should never be shown — alertBinding filters these out.
                return Alert(title: Text(""))
            }
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
                .foregroundColor(theme.primaryText)
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

    private func sectionDivider() -> some View {
        theme.divider
            .frame(height: 1)
    }

    // MARK: - About tab actions

    private func githubIconImage() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("github.svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    private var repoURL: URL { URL(string: "https://github.com/wonaren/copyattach-release")! }
    private var authorGitHubURL: URL { URL(string: "https://github.com/wonaren")! }

    private func openWebsite() {
        NSWorkspace.shared.open(repoURL)
    }

    private var alertBinding: Binding<UpdateCheckState?> {
        Binding {
            if case .idle = updateState { return nil }
            if case .checking = updateState { return nil }
            return updateState
        } set: { _ in
            updateState = .idle
        }
    }

    /// Strip pre-release suffix (e.g. "-dev") for version comparison.
    /// "0.82.0-dev" → "0.82.0" so that a released "0.82.0" is correctly
    /// detected as newer.
    private static func stripDevSuffix(_ version: String) -> String {
        version.components(separatedBy: "-").first ?? version
    }
    private func stripDevSuffix(_ version: String) -> String { Self.stripDevSuffix(version) }

    private func checkForUpdates() {
        guard case .idle = updateState else { return }
        updateState = .checking

        let url = URL(string: "https://api.github.com/repos/wonaren/copyattach-release/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    updateState = .error("无法连接到更新服务器：\(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    updateState = .error("无效的服务器响应")
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    break // continue parsing
                case 404:
                    updateState = .error("未找到版本信息（仓库中尚无正式 Release）")
                    return
                case 403:
                    updateState = .error("API 请求过于频繁，请稍后再试")
                    return
                default:
                    updateState = .error("服务器返回错误 (HTTP \(httpResponse.statusCode))")
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    updateState = .error("无法解析更新信息")
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let currentVersion = self.appVersion
                let currentBase = stripDevSuffix(currentVersion)
                let isDev = currentVersion != currentBase

                let releaseURL: URL
                if let htmlURL = json["html_url"] as? String, let url = URL(string: htmlURL) {
                    releaseURL = url
                } else {
                    releaseURL = URL(string: "https://github.com/wonaren/copyattach-release/releases/tag/v\(latestVersion)")!
                }

                if latestVersion.compare(currentBase, options: .numeric) == .orderedDescending {
                    // Normal upgrade: a newer version exists
                    updateState = .updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: false)
                } else if isDev {
                    // Dev → stable: offer the stable release even if it's the same
                    // version number or slightly behind (downgrade from dev)
                    updateState = .updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: true)
                } else {
                    updateState = .upToDate(currentVersion: currentVersion)
                }
            }
        }.resume()
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
