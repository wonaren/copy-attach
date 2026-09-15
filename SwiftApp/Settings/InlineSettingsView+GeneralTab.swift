import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - 🔵 GENERAL TAB

extension InlineSettingsView {
    var generalTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !backend.permissionGranted {
                    permissionBanner
                }
                generalSettingsCard
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
                    .foregroundColor(backend.permissionGranted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                Text(backend.permissionGranted ? "辅助功能：已授权" : "辅助功能：未授权")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(backend.permissionGranted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
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
        .background(backend.permissionGranted ? Color(nsColor: .systemGreen).opacity(0.10) : Color(nsColor: .systemOrange).opacity(0.10))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(backend.permissionGranted ? Color(nsColor: .systemGreen).opacity(0.28) : Color(nsColor: .systemOrange).opacity(0.28), lineWidth: 1)
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
                        .contentShape(RoundedRectangle(cornerRadius: 11))
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
                                .allowsHitTesting(false)
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
            settingToggleRow(
                icon: launchAtLogin ? "power.circle.fill" : "power.circle",
                iconColor: launchAtLogin ? Color(nsColor: .systemGreen) : theme.secondaryText,
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
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: runInBackground ? "circle.fill" : "circle",
                iconColor: runInBackground ? Color(nsColor: .systemGreen) : theme.secondaryText,
                title: "后台运行",
                desc: "关闭主窗口后，保持应用在后台状态栏运行。",
                isOn: $runInBackground
            )
            .onChange(of: runInBackground) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "RunInBackground")
            }
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: "menubar.rectangle",
                iconColor: showMenuBarIcon ? Color.accentColor : theme.secondaryText,
                title: "显示菜单栏图标",
                desc: "控制 CopyAttach 图标在 macOS 顶部状态栏的显示与隐藏。",
                isOn: $showMenuBarIcon
            )
            .onChange(of: showMenuBarIcon) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "ShowMenuBarIcon")
            }
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: continuousDrag ? "hand.draw.fill" : "hand.draw",
                iconColor: continuousDrag ? Color.accentColor : theme.secondaryText,
                title: "连续拖拽",
                desc: "拖拽条目时弹窗保持打开，支持连续多次拖拽。",
                isOn: $continuousDrag
            )
            .onChange(of: continuousDrag) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: HistoryPopupWindow.continuousDragDefaultsKey)
            }
            sectionDivider().padding(.vertical, 7)
            richTextDragRow
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: "ant.circle.fill",
                iconColor: debugLogging ? Color(nsColor: .systemOrange) : theme.secondaryText,
                title: "调试日志",
                desc: "记录诊断日志到 /tmp/copyattach_debug.log；默认关闭。",
                isOn: $debugLogging
            )
            .onChange(of: debugLogging) { _, newValue in
                backend.setDebugLogging(newValue)
            }
        }
        .sheet(isPresented: $showRichTextListSheet) {
            richTextAppListSheet
        }
    }

    // MARK: - Rich Text Drag Applications Card (Apple Design)

    // MARK: - Rich Text Drag Applications Entry Row

    /// Single compact row inside the unified settings card.
    /// Clicking "查看列表…" opens the native modal sheet.
    private var richTextDragRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 15))
                .foregroundColor(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("富文本拖拽应用")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if !richTextDragApps.isEmpty {
                        Text("\(richTextDragApps.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(theme.cardBorder.opacity(0.5))
                            .clipShape(Capsule())
                    }
                }

                Text(richTextSummaryText)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Miniature app icons stack preview
            if !richTextDragApps.isEmpty {
                richTextMiniIconsPreview
            }

            // Native Apple-style "查看列表…" button that opens the modal sheet
            Button(action: {
                showRichTextListSheet = true
            }) {
                Text("查看列表…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.buttonBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Rich Text Drag Applications Modal Sheet (Apple Design)

    private var richTextAppListSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Sheet Header
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 18))
                    .foregroundColor(Color.accentColor)

                Text("富文本拖拽应用")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if !richTextDragApps.isEmpty {
                    Text("\(richTextDragApps.count) 个应用")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }

            Text("默认拖拽输出纯文本，以确保与 VS Code Copilot 等聊天框的兼容性。添加到下方的应用在拖拽时将额外提供 HTML / RTF 富文本，以满足思源笔记、Typora 等编辑器的接收需求。")
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)

            // Inset grouped list container
            VStack(spacing: 0) {
                if richTextDragApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 26))
                            .foregroundColor(theme.secondaryText.opacity(0.5))
                            .padding(.top, 24)
                        Text("未添加特殊应用，全部按纯文本拖拽")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text("点击下方「添加应用…」或将应用图标从访达拖入此处")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(richTextDragApps, id: \.self) { bundleID in
                                richTextAppRow(bundleID: bundleID)
                                if bundleID != richTextDragApps.last {
                                    sectionDivider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                sectionDivider()
                richTextTableFooterBar
            }
            .background(theme.cardRowBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDraggingOverRichTextCard ? Color.accentColor : theme.cardBorder, lineWidth: isDraggingOverRichTextCard ? 1.5 : 1)
            )
            .animation(.easeInOut(duration: 0.15), value: isDraggingOverRichTextCard)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDraggingOverRichTextCard) { providers in
                handleDropApplications(providers)
            }

            Spacer(minLength: 4)

            // Sheet Footer Bar
            HStack {
                Text("按唤起弹窗时的前台应用判定")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Button("完成") {
                    showRichTextListSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 470, height: 400)
        .background(theme.cardBackground)
        .sheetDismissOnOutsideClick {
            showRichTextListSheet = false
        }
    }

    private var richTextMiniIconsPreview: some View {
        HStack(spacing: -5) {
            ForEach(Array(richTextDragApps.prefix(3)), id: \.self) { bundleID in
                if let icon = getAppIcon(for: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(theme.cardBackground, lineWidth: 1.5)
                        )
                }
            }
        }
        .padding(.trailing, 2)
    }

    private var richTextSummaryText: String {
        if richTextDragApps.isEmpty {
            return "全部按纯文本拖拽（未设置特殊应用）"
        }
        let names = richTextDragApps.prefix(2).map { richTextDragApplicationName(for: $0) }
        let joined = names.joined(separator: "、")
        if richTextDragApps.count > 2 {
            return "仅 \(joined) 等 \(richTextDragApps.count) 个应用启用富文本"
        } else {
            return "仅为 \(joined) 启用富文本，其余保持纯文本"
        }
    }

    private func richTextAppRow(bundleID: String) -> some View {
        HStack(spacing: 10) {
            // App Icon with Apple squircle clip and shadow
            if let icon = getAppIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 2, y: 1)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13))
                        .foregroundColor(Color.accentColor)
                }
            }

            // App Name & Bundle ID
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(richTextDragApplicationName(for: bundleID))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if isRunning(bundleID: bundleID) {
                        Circle()
                            .fill(Color(nsColor: .systemGreen))
                            .frame(width: 6, height: 6)
                            .help("该应用当前正在运行")
                    }
                }

                Text(bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            // Delete button
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    richTextDragApps.removeAll { $0 == bundleID }
                    persistRichTextDragApps()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("从列表中移除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var richTextTableFooterBar: some View {
        HStack(spacing: 8) {
            Menu {
                let running = runningAppCandidates
                if !running.isEmpty {
                    Section("正在运行的应用") {
                        ForEach(running, id: \.processIdentifier) { app in
                            Button {
                                if let id = app.bundleIdentifier {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        richTextDragApps.append(id)
                                        persistRichTextDragApps()
                                    }
                                }
                            } label: {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                }
                                Text(app.localizedName ?? (app.bundleIdentifier ?? ""))
                            }
                        }
                    }
                }
                Section {
                    Button("从访达中选取…") {
                        chooseRichTextDragApplication()
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("添加应用…")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(Color.accentColor)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if isDraggingOverRichTextCard {
                Text("松开以添加应用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.cardBackground.opacity(0.35))
    }

    private func richTextDragApplicationName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        if bundleID == "org.b3log.siyuan" { return "SiYuan" }
        if bundleID == "abnerworks.Typora" { return "Typora" }
        return bundleID
    }

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private var runningAppCandidates: [NSRunningApplication] {
        let currentIDs = Set(richTextDragApps)
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, !currentIDs.contains(id) else { return false }
            guard app.processIdentifier != myPID else { return false }
            return app.activationPolicy == .regular
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseRichTextDragApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        panel.message = "选择需要支持富文本拖拽的应用"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            if !richTextDragApps.contains(bundleID) {
                richTextDragApps.append(bundleID)
            }
        }
        persistRichTextDragApps()
    }

    private func handleDropApplications(_ providers: [NSItemProvider]) -> Bool {
        let appProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !appProviders.isEmpty else { return false }
        for provider in appProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = {
                    if let url = item as? URL { return url }
                    if let nsurl = item as? NSURL { return nsurl as URL }
                    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                    return nil
                }()
                guard let url = url else { return }
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
                DispatchQueue.main.async {
                    if !self.richTextDragApps.contains(bundleID) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            self.richTextDragApps.append(bundleID)
                            self.persistRichTextDragApps()
                        }
                    }
                }
            }
        }
        return true
    }

    private func persistRichTextDragApps() {
        ClipboardBackend.richTextDragAppBundleIDs = richTextDragApps
    }


}
