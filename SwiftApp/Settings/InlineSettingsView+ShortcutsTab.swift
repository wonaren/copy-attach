import SwiftUI

// MARK: - 🟢 SHORTCUTS TAB

extension InlineSettingsView {
    var shortcutsTab: some View {
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
                shortcutGuideRow(label: "添加 / 编辑备注", keycaps: ["⌥", "R"])
                sectionDivider()
                shortcutGuideRow(label: "快速删除选中条目", keycaps: ["⌃", "⌫"])
                sectionDivider()
                shortcutGuideRow(label: "撤销删除 (最近 1 条)", keycaps: ["⌘", "Z"])
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
}
