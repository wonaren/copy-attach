import AppKit
import SwiftUI

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
}
