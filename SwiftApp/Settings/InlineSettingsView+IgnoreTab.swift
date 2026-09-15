import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 🟣 IGNORE TAB

extension InlineSettingsView {
    var ignoreTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                ignoreAppsCard
                filterRulesCard
            }
            .padding(20)
        }
    }

    // MARK: - Ignored Applications Entry & Modal Sheet (Apple Design)

    private var ignoreAppsCard: some View {
        settingsCard {
            HStack(spacing: 12) {
                Image(systemName: "app.badge")
                    .font(.system(size: 15))
                    .foregroundColor(Color.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("按应用忽略")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        if !ignoredAppBundleIDs.isEmpty {
                            Text("\(ignoredAppBundleIDs.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.cardBorder.opacity(0.5))
                                .clipShape(Capsule())
                        }
                    }

                    Text(ignoredAppsSummaryText)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Miniature app icons stack preview
                if !ignoredAppBundleIDs.isEmpty {
                    ignoredAppsMiniIconsPreview
                }

                // Native Apple-style "查看列表…" button
                Button(action: {
                    showIgnoredAppsSheet = true
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
        .sheet(isPresented: $showIgnoredAppsSheet) {
            ignoredAppsListSheet
        }
    }

    private var ignoredAppsMiniIconsPreview: some View {
        HStack(spacing: -5) {
            ForEach(Array(ignoredAppBundleIDs.prefix(3)), id: \.self) { bundleID in
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

    private var ignoredAppsSummaryText: String {
        if ignoredAppBundleIDs.isEmpty {
            return "未设置应用，记录全部剪贴板内容"
        }
        let names = ignoredAppBundleIDs.prefix(2).map { applicationName(for: $0) }
        let joined = names.joined(separator: "、")
        if ignoredAppBundleIDs.count > 2 {
            return "已忽略 \(joined) 等 \(ignoredAppBundleIDs.count) 个应用的复制内容"
        } else {
            return "已忽略 \(joined) 的复制内容，不写入历史"
        }
    }

    // MARK: - Ignored Applications Modal Sheet (Apple Design)

    private var ignoredAppsListSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Sheet Header
            HStack(spacing: 10) {
                Image(systemName: "app.badge")
                    .font(.system(size: 18))
                    .foregroundColor(Color.accentColor)

                Text("按应用忽略")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Spacer()

                if !ignoredAppBundleIDs.isEmpty {
                    Text("\(ignoredAppBundleIDs.count) 个应用")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }

            Text("匹配应用的 bundle identifier。复制这些应用中的内容时将直接跳过，不会记录到历史记录、内存或数据库中。")
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)

            // Inset grouped list container
            VStack(spacing: 0) {
                if ignoredAppBundleIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 26))
                            .foregroundColor(theme.secondaryText.opacity(0.5))
                            .padding(.top, 24)
                        Text("未设置应用规则")
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
                            ForEach(ignoredAppBundleIDs, id: \.self) { bundleID in
                                ignoredAppRow(bundleID: bundleID)
                                if bundleID != ignoredAppBundleIDs.last {
                                    sectionDivider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                sectionDivider()
                ignoredAppsTableFooterBar
            }
            .background(theme.cardRowBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDraggingOverIgnoreSheet ? Color.accentColor : theme.cardBorder, lineWidth: isDraggingOverIgnoreSheet ? 1.5 : 1)
            )
            .animation(.easeInOut(duration: 0.15), value: isDraggingOverIgnoreSheet)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDraggingOverIgnoreSheet) { providers in
                handleDropIgnoredApplications(providers)
            }

            Spacer(minLength: 4)

            // Sheet Footer Bar
            HStack {
                Text("在读取剪贴板前过滤，不占存储")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Button("完成") {
                    showIgnoredAppsSheet = false
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
            showIgnoredAppsSheet = false
        }
    }

    private func ignoredAppRow(bundleID: String) -> some View {
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
                    Text(applicationName(for: bundleID))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if isRunningApp(bundleID: bundleID) {
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
                    ignoredAppBundleIDs.removeAll { $0 == bundleID }
                    persistIgnoreRules()
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

    private var ignoredAppsTableFooterBar: some View {
        HStack(spacing: 8) {
            Menu {
                let running = runningIgnoreAppCandidates
                if !running.isEmpty {
                    Section("正在运行的应用") {
                        ForEach(running, id: \.processIdentifier) { app in
                            Button {
                                if let id = app.bundleIdentifier {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        ignoredAppBundleIDs.append(id)
                                        persistIgnoreRules()
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
                        chooseIgnoredApplication()
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

            if isDraggingOverIgnoreSheet {
                Text("松开以添加应用")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.cardBackground.opacity(0.35))
    }

    private func isRunningApp(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private var runningIgnoreAppCandidates: [NSRunningApplication] {
        let currentIDs = Set(ignoredAppBundleIDs)
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier, !currentIDs.contains(id) else { return false }
            guard app.processIdentifier != myPID else { return false }
            return app.activationPolicy == .regular
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseIgnoredApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        panel.message = "选择需要忽略的应用"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            if !ignoredAppBundleIDs.contains(bundleID) {
                ignoredAppBundleIDs.append(bundleID)
            }
        }
        persistIgnoreRules()
    }

    private func handleDropIgnoredApplications(_ providers: [NSItemProvider]) -> Bool {
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
                    if !self.ignoredAppBundleIDs.contains(bundleID) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            self.ignoredAppBundleIDs.append(bundleID)
                            self.persistIgnoreRules()
                        }
                    }
                }
            }
        }
        return true
    }

    private var filterRulesCard: some View {
        settingsCard {
            cardTitle(icon: "line.3.horizontal.decrease", text: "按类型与特点忽略")
            settingToggleRow(
                icon: "lock.shield",
                iconColor: Color(nsColor: .systemBlue),
                title: "忽略密码与敏感内容",
                desc: "自动过滤 1Password、Bitwarden、钥匙串等密码管理器标记为敏感或临时（Concealed/Transient）的剪贴板内容。",
                isOn: $ignoreSensitive
            )
            .onChange(of: ignoreSensitive) { _, _ in persistIgnoreRules() }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(icon: "textformat", iconColor: .accentColor, title: "忽略文本", desc: "不记录任何纯文本剪贴板内容。", isOn: $ignoreTextClipboardType)
                .onChange(of: ignoreTextClipboardType) { _, _ in persistIgnoreRules() }
            sectionDivider().padding(.vertical, 4)
            settingToggleRow(icon: "photo", iconColor: Color(nsColor: .systemGreen), title: "忽略图片", desc: "不读取、编码或存储图片剪贴板内容。", isOn: $ignoreImageClipboardType)
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

    private func persistIgnoreRules() {
        UserDefaults.standard.set(ignoredAppBundleIDs, forKey: "IgnoredAppBundleIDs")
        UserDefaults.standard.set(ignoreSensitive, forKey: "IgnoreSensitiveClipboard")
        UserDefaults.standard.set(ignoreTextClipboardType, forKey: "IgnoreTextClipboardType")
        UserDefaults.standard.set(ignoreImageClipboardType, forKey: "IgnoreImageClipboardType")
        UserDefaults.standard.set(ignoreShortText, forKey: "IgnoreShortText")
        UserDefaults.standard.set(shortTextThreshold, forKey: "ShortTextThreshold")
        backend.syncIgnoreRules()
    }
}
