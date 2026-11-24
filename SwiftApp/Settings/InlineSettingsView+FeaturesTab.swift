import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InlineSettingsView {
    var featuresTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                featuresSettingsCard
            }
            .padding(20)
        }
    }

    private var featuresSettingsCard: some View {
        settingsCard {
            settingToggleRow(
                icon: autoPasteAtCursor ? "text.insert" : "doc.on.clipboard",
                iconColor: autoPasteAtCursor ? Color.accentColor : theme.secondaryText,
                title: "自动粘贴到光标处",
                desc: autoPasteAtCursor
                    ? "内容插入到光标处（需要辅助功能权限）。"
                    : "内容仅复制到剪贴板，由你按 ⌘V 自行粘贴。",
                isOn: $autoPasteAtCursor
            )
            .onChange(of: autoPasteAtCursor) { _, newValue in
                PasteDeliveryMode.persist(newValue ? .keystroke : .clipboardOnly)
            }
            sectionDivider().padding(.vertical, 7)
            settingToggleRow(
                icon: "cursorarrow.click",
                iconColor: singleClickUsesItem ? Color.accentColor : theme.secondaryText,
                title: "单击使用条目",
                desc: singleClickUsesItem
                    ? "单击条目即可使用。"
                    : "先点击选中，再点击同一条目或按Enter使用。",
                isOn: $singleClickUsesItem
            )
            sectionDivider().padding(.vertical, 7)
            sidePreviewToggleRow
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
        }
        .sheet(isPresented: $showRichTextListSheet) {
            richTextAppListSheet
        }
    }

    private var sidePreviewToggleRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 15))
                .foregroundColor((textSidePreviewEnabled || imageSidePreviewEnabled) ? Color.accentColor : theme.secondaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("侧边悬浮预览")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text("悬停或 ↑ ↓ 时显示，3 秒后自动关闭。")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Text("文本")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                    Toggle("", isOn: $textSidePreviewEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                HStack(spacing: 5) {
                    Text("图片")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                    Toggle("", isOn: $imageSidePreviewEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

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

                Text("拖拽时保留字体、颜色与链接；仅对列表中的应用生效。")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !richTextDragApps.isEmpty {
                richTextMiniIconsPreview
            }

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

    private var richTextAppListSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Text("拖拽默认输出纯文本，兼容大多数应用。列表中的应用会额外收到 HTML / RTF，从而保留字体、颜色与链接。")
                .font(.system(size: 11.5))
                .foregroundColor(theme.secondaryText)
                .lineSpacing(2)

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
            .animation(ReduceMotion.animation(.easeInOut(duration: 0.15)), value: isDraggingOverRichTextCard)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDraggingOverRichTextCard) { providers in
                handleDropApplications(providers)
            }

            Spacer(minLength: 4)

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

    private func richTextAppRow(bundleID: String) -> some View {
        HStack(spacing: 10) {
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

            Button {
                withAnimation(ReduceMotion.animation(.spring(response: 0.25, dampingFraction: 0.8))) {
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
                                    withAnimation(ReduceMotion.animation(.spring(response: 0.25, dampingFraction: 0.8))) {
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
                        withAnimation(ReduceMotion.animation(.spring(response: 0.25, dampingFraction: 0.8))) {
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
