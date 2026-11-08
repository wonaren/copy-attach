import AppKit
import SwiftUI

extension InlineSettingsView {
    var shortcutsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                shortcutConfigCard
                quickSlotsCard
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

    private var quickSlotsCard: some View {
        settingsCard {
            cardTitle(icon: "command.square", text: "快捷槽位粘贴 (右 ⌘ + 1~9)")
            if backend.slotByEntryId.isEmpty {
                Text("在剪贴板列表中选中条目并按「右 ⌘ + 1~9」绑定槽位；关闭列表后，在任意应用按「右 ⌘ + 对应数字」即可直接粘贴。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(1...9, id: \.self) { slot in
                        if let entryId = backend.slotByEntryId.first(where: { $0.value == slot })?.key,
                           let item = backend.items.first(where: { $0.id == entryId }) {
                            HStack(spacing: 10) {
                                kbdBadge("右⌘\(slot)")
                                Text(item.slotDisplayName)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    if !backend.toggleQuickSlot(entryId: entryId, slot: slot) {
                                        NSSound.beep()
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .help("解除此槽位")
                            }
                            .padding(.vertical, 6)
                            sectionDivider()
                        }
                    }
                    HStack {
                        if !backend.permissionGranted {
                            Text("需开启辅助功能权限，才能在弹窗外用右 ⌘ + 数字直接粘贴。")
                                .font(.system(size: 10.5))
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Button("清空全部") {
                            if !backend.clearQuickSlots() { NSSound.beep() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .padding(.top, 8)
                    }
                }
            }
        }
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
                shortcutGuideRow(label: "撤销删除 (可连续撤销)", keycaps: ["⌘", "Z"])
                sectionDivider()
                shortcutGuideRow(label: "快速选择第 1 ~ 9 项", keycaps: ["左 ⌘", "1~9"])
                sectionDivider()
                shortcutGuideRow(label: "绑定 / 解除快捷槽位（弹窗内）", keycaps: ["右 ⌘", "1~9"])
                sectionDivider()
                shortcutGuideRow(label: "全局粘贴快捷槽位（弹窗关闭）", keycaps: ["右 ⌘", "1~9"])
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
