import SwiftUI
import UniformTypeIdentifiers

private func makeQuickSlotProvider(slot: Int) -> NSItemProvider {
    let provider = NSItemProvider()
    let payload = Data(String(slot).utf8)
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.data.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(payload, nil)
        return nil
    }
    return provider
}

struct QuickSlotSettings: View {
    let backend: ClipboardBackend

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmClear = false
    @State private var showFailure = false
    @State private var draggingSlot: Int?
    @State private var hoverSlot: Int?
    @State private var trashTargeted = false
    @State private var previewSlot: Int?

    private let slots = 1...9

    private var slotOwners: [Int: ClipboardItem] {
        let slotsByEntryID = backend.slotByEntryId
        guard !slotsByEntryID.isEmpty else { return [:] }
        var result: [Int: ClipboardItem] = [:]
        for item in backend.items {
            guard let slot = slotsByEntryID[item.id] else { continue }
            result[slot] = item
        }
        return result
    }

    private var boundCount: Int { backend.slotByEntryId.count }

    private var changeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    var body: some View {
        let owners = slotOwners
        VStack(alignment: .leading, spacing: 10) {
            header
            grid(owners: owners)
            if draggingSlot != nil {
                trashZone
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            footer
            if boundCount > 0 && !backend.permissionGranted {
                permissionNotice
                    .transition(.opacity)
            }
        }
        .animation(changeAnimation, value: draggingSlot)
        .animation(changeAnimation, value: backend.slotByEntryId)
        .animation(changeAnimation, value: backend.permissionGranted)
        .onAppear { ImageDecode.beginPreviewSession() }
        .onDisappear { ImageDecode.endPreviewSession() }
        .alert("解除全部快捷槽位？", isPresented: $confirmClear) {
            Button("解除全部", role: .destructive) {
                showFailure = !backend.clearQuickSlots()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("剪贴板历史会保留。之后撤销删除时，恢复的条目需要重新绑定槽位。")
        }
        .alert("无法解除快捷槽位", isPresented: $showFailure) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请重试。")
        }
    }

    private func previewBinding(_ slot: Int) -> Binding<Bool> {
        Binding(
            get: { previewSlot == slot },
            set: { if !$0 { previewSlot = nil } }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("快捷槽位粘贴")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text("关闭剪贴板列表后，按对应组合键粘贴。")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 0)
            Text("已绑定 \(boundCount)/\(slots.count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .fixedSize()
                .contentTransition(.opacity)
        }
    }

    private func grid(owners: [Int: ClipboardItem]) -> some View {
        HStack(spacing: 6) {
            ForEach(slots, id: \.self) { slot in
                slotTile(slot: slot, item: owners[slot])
            }
        }
        .animation(changeAnimation, value: draggingSlot)
    }

    private func slotTile(slot: Int, item: ClipboardItem?) -> some View {
        let occupied = item != nil
        let isDropTarget = hoverSlot == slot
        let isSource = draggingSlot == slot
        return QuickSlotTile(
            slot: slot,
            item: item,
            isDropTarget: isDropTarget,
            onPreview: {
                guard occupied else { return }
                previewSlot = slot
            }
        )
        .opacity(isSource ? 0.45 : 1)
        .popover(isPresented: previewBinding(slot), arrowEdge: .bottom) {
            if let item {
                let size = PreviewWindow.miniSize(for: item)
                PreviewContent(item: item,
                               maxPixelOverride: PreviewWindow.miniMaxPixel,
                               showsZoomHint: true,
                               embedded: true)
                    .frame(width: size.width, height: size.height)
            }
        }
        .onDrag {
            guard occupied else { return NSItemProvider() }
            draggingSlot = slot
            return makeQuickSlotProvider(slot: slot)
        }
        .onDrop(of: [.data], isTargeted: dropTargetBinding(slot)) { _ in
            handleDrop(to: slot)
        }
    }

    private func dropTargetBinding(_ slot: Int) -> Binding<Bool> {
        Binding(
            get: { hoverSlot == slot },
            set: { inside in
                if inside {
                    hoverSlot = slot
                } else if hoverSlot == slot {
                    hoverSlot = nil
                }
            }
        )
    }

    private func handleDrop(to slot: Int) -> Bool {
        defer {
            hoverSlot = nil
            draggingSlot = nil
        }
        guard let from = draggingSlot, from != slot else { return false }
        guard let item = slotOwners[from] else { return false }
        return backend.moveQuickSlot(entryId: item.id, to: slot)
    }

    private var trashZone: some View {
        HStack(spacing: 8) {
            Image(systemName: trashTargeted ? "trash.fill" : "trash")
                .font(.system(size: 15))
            Text(trashTargeted ? "松开以解除槽位" : "拖到此处解除槽位")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(trashTargeted ? Color.red : theme.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(trashTargeted ? Color.red.opacity(0.12) : theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    trashTargeted ? Color.red : theme.cardBorder,
                    style: StrokeStyle(lineWidth: trashTargeted ? 1.5 : 1,
                                       dash: trashTargeted ? [] : [4, 3])
                )
        )
        .onDrop(of: [.data], isTargeted: $trashTargeted) { _ in
            defer {
                trashTargeted = false
                draggingSlot = nil
            }
            guard let from = draggingSlot, let item = slotOwners[from] else { return false }
            return backend.removeQuickSlot(entryId: item.id, slot: from)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("拖拽交换槽位，拖到垃圾桶解除；点击槽位查看内容。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            if boundCount > 0 {
                Button("解除全部") { confirmClear = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize()
            }
        }
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

private struct QuickSlotTile: View {
    let slot: Int
    let item: ClipboardItem?
    let isDropTarget: Bool
    let onPreview: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var occupied: Bool { item != nil }

    var body: some View {
        Text("\(slot)")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(labelColor)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(background)
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture { onPreview() }
            .onHover { isHovered = $0 }
            .help(helpText)
    }

    private var labelColor: Color {
        if isDropTarget { return Color.accentColor }
        return occupied ? Color.accentColor : theme.tertiaryText
    }

    private var background: some View {
        let fill: Color = isDropTarget
            ? Color.accentColor.opacity(0.20)
            : (occupied
               ? (isHovered ? Color.accentColor.opacity(0.12) : Color.accentColor.opacity(0.07))
               : Color.clear)
        return RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isDropTarget ? Color.accentColor : theme.cardBorder,
                style: StrokeStyle(lineWidth: isDropTarget ? 1.5 : 1,
                                   dash: occupied ? [] : [4, 3])
            )
    }

    private var helpText: String {
        guard let item else { return "槽位 \(slot) 未绑定" }
        return "右 ⌘\(slot)：\(item.slotDisplayName)"
    }
}
