import SwiftUI

struct QuickSlotSettings: View {
    let backend: ClipboardBackend

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false
    @State private var showFailure = false

    private struct SlotBinding {
        let slot: Int
        let item: ClipboardItem
    }

    private let slots = 1...9

    private var bindings: [SlotBinding] {
        let slotsByEntryID = backend.slotByEntryId
        guard !slotsByEntryID.isEmpty else { return [] }
        return backend.items.compactMap { item -> SlotBinding? in
            guard let slot = slotsByEntryID[item.id] else { return nil }
            return SlotBinding(slot: slot, item: item)
        }.sorted { $0.slot < $1.slot }
    }

    private var changeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24)
    }

    var body: some View {
        let bindings = bindings
        VStack(alignment: .leading, spacing: 12) {
            header(count: bindings.count)
            keyStrip(occupied: Set(bindings.map(\.slot)))

            if bindings.isEmpty {
                Text("还没有绑定内容")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ForEach(bindings, id: \.slot) { binding in
                        bindingRow(binding)
                            .transition(.opacity)
                    }
                }
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                Text("在剪贴板列表中选中条目，按右 ⌘ + 数字绑定。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if !bindings.isEmpty {
                    Button("解除全部") { confirmClear = true }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize()
                        .transition(.opacity)
                        .alert("解除全部快捷槽位？", isPresented: $confirmClear) {
                            Button("解除全部", role: .destructive) {
                                showFailure = !backend.clearQuickSlots()
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("剪贴板历史会保留。之后撤销删除时，恢复的条目需要重新绑定槽位。")
                        }
                }
            }

            if !bindings.isEmpty && !backend.permissionGranted {
                permissionNotice
                    .transition(.opacity)
            }
        }
        .animation(changeAnimation, value: backend.slotByEntryId)
        .animation(changeAnimation, value: backend.permissionGranted)
        .alert("无法解除快捷槽位", isPresented: $showFailure) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请重试。")
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("快捷槽位粘贴")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("关闭剪贴板列表后，按对应组合键粘贴。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Text("已绑定 \(count)/\(slots.count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .fixedSize()
                .contentTransition(.opacity)
        }
    }

    private func keyStrip(occupied: Set<Int>) -> some View {
        HStack(spacing: 6) {
            Text("右 ⌘")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: 46, height: 29)
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))

            Image(systemName: "plus")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            ForEach(slots, id: \.self) { slot in
                let isOccupied = occupied.contains(slot)
                let shape = RoundedRectangle(cornerRadius: 6)
                Text("\(slot)")
                    .font(.system(size: 12, weight: isOccupied ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isOccupied ? theme.primaryText : theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 29)
                    .background(isOccupied ? Color.accentColor.opacity(0.12) : Color.clear, in: shape)
                    .overlay {
                        shape.strokeBorder(isOccupied ? Color.accentColor.opacity(0.36) : theme.cardBorder)
                    }
                    .overlay(alignment: .bottom) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 3)
                            .padding(.bottom, 3)
                            .opacity(isOccupied ? 1 : 0)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func bindingRow(_ binding: SlotBinding) -> some View {
        let item = binding.item
        let name = item.slotDisplayName
        return HStack(spacing: 8) {
            Text("\(binding.slot)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 20)
                .accessibilityHidden(true)
            Image(systemName: item.isImage ? "photo" : "text.alignleft")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .help(name)
                .accessibilityLabel("槽位 \(binding.slot)，\(item.isImage ? "图片" : "文本")，\(name)")

            Button {
                showFailure = !backend.removeQuickSlot(entryId: item.id, slot: binding.slot)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuickSlotRemoveStyle())
            .help("解除槽位 \(binding.slot)")
            .accessibilityLabel("解除槽位 \(binding.slot)")
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.leading, 5)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    private var permissionNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            Text("全局粘贴需要辅助功能权限")
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            Button("打开系统设置", action: backend.openPreferences)
                .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct QuickSlotRemoveStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? theme.primaryText : theme.secondaryText)
            .background(isHovered ? theme.popupRowHover : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(AppleMotion.tactilePress, value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}
