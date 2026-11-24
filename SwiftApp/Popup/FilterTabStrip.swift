import AppKit
import SwiftUI

enum FilterTabOrder {
    static let defaultsKey = "FilterTabOrder"
    static let hiddenDefaultsKey = "FilterTabHiddenTabs"
    static let minimumVisible = 2

    static var defaultOrder: [FilterMode] { FilterMode.allCases }

    static var saved: [FilterMode] {
        let raw = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return sanitized(raw.compactMap(FilterMode.init(rawValue:)))
    }

    static var savedHidden: Set<FilterMode> {
        let raw = UserDefaults.standard.stringArray(forKey: hiddenDefaultsKey) ?? []
        let hidden = Set(raw.compactMap(FilterMode.init(rawValue:)))
        guard hidden.count < defaultOrder.count else { return [] }
        return hidden
    }

    static var initialSelection: FilterMode {
        let hidden = savedHidden
        let order = saved
        if !hidden.contains(.all), order.contains(.all) { return .all }
        return order.first(where: { !hidden.contains($0) }) ?? .all
    }

    static func sanitized(_ modes: [FilterMode]) -> [FilterMode] {
        var result: [FilterMode] = []
        for mode in modes where !result.contains(mode) {
            result.append(mode)
        }
        for mode in defaultOrder where !result.contains(mode) {
            result.append(mode)
        }
        return result
    }

    static func persist(_ order: [FilterMode]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: defaultsKey)
    }

    static func persistHidden(_ hidden: Set<FilterMode>) {
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: hiddenDefaultsKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    static func resetHidden() {
        UserDefaults.standard.removeObject(forKey: hiddenDefaultsKey)
    }

    static func visible(_ order: [FilterMode], hidden: Set<FilterMode>) -> [FilterMode] {
        order.filter { !hidden.contains($0) }
    }

    static func merged(visible: [FilterMode], into order: [FilterMode], hidden: Set<FilterMode>) -> [FilterMode] {
        var result = order
        var next = 0
        for (index, mode) in order.enumerated() where !hidden.contains(mode) {
            guard next < visible.count else { break }
            result[index] = visible[next]
            next += 1
        }
        return result
    }

    static func moving(_ order: [FilterMode], from source: Int, to target: Int) -> [FilterMode] {
        guard order.indices.contains(source),
              order.indices.contains(target),
              source != target else { return order }
        var next = order
        let mode = next.remove(at: source)
        next.insert(mode, at: target)
        return next
    }
}

private struct FilterTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [FilterMode: CGRect] = [:]

    static func reduce(value: inout [FilterMode: CGRect], nextValue: () -> [FilterMode: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct FilterTabStrip: View {
    @Binding var order: [FilterMode]
    @Binding var hidden: Set<FilterMode>
    let selected: FilterMode
    let onSelect: (FilterMode) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @Namespace private var pillNamespace

    @State private var frames: [FilterMode: CGRect] = [:]
    @State private var hoveredMode: FilterMode?
    @State private var pressedMode: FilterMode?
    @State private var draggingMode: FilterMode?
    @State private var dragOrder: [FilterMode] = []
    @State private var dragTranslation: CGFloat = 0

    private static let space = "filterTabStrip"
    private static let pillID = "activeFilterPill"
    private static let spacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 6
    private static let liftScale: CGFloat = 1.06
    private static let pressScale: CGFloat = 0.94
    private static let dragThreshold: CGFloat = 3

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(visibleOrder, id: \.self) { mode in
                chip(mode)
                    .offset(x: offset(for: mode))
                    .zIndex(draggingMode == mode ? 1 : 0)
                    .background { frameReader(mode) }
            }
            Spacer(minLength: 0)
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(FilterTabFramePreferenceKey.self) { next in
            guard next != frames else { return }
            frames = next
        }
    }

    @ViewBuilder
    private func chipBackground(isSelected: Bool,
                                isLifted: Bool,
                                isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        ZStack {
            if isLifted {
                shape.fill(theme.popupBackground)
            }
            if isSelected {
                let pill = shape.fill(theme.popupFilterTabBackgroundSelected)
                    .overlay(
                        shape.strokeBorder(Color(nsColor: .controlAccentColor).opacity(0.35), lineWidth: 1)
                    )
                if isLifted {
                    pill
                } else {
                    pill.matchedGeometryEffect(id: Self.pillID, in: pillNamespace)
                }
            } else {
                shape.fill(isHovered ? theme.popupRowHover : theme.popupFilterTabBackground)
                    .overlay(shape.strokeBorder(theme.popupRowBorder, lineWidth: 1))
            }
        }
    }

    private func frameReader(_ mode: FilterMode) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: FilterTabFramePreferenceKey.self,
                                   value: [mode: geo.frame(in: .named(Self.space))])
        }
    }

    private func chip(_ mode: FilterMode) -> some View {
        let isSelected = mode == selected
        let isLifted = draggingMode == mode
        let isPressed = pressedMode == mode && !isLifted
        let isHovered = hoveredMode == mode && !isSelected && !isLifted
        return Image(systemName: mode.icon)
            .font(.system(size: 13, weight: .medium))
            .frame(height: 16)
            .foregroundColor(isSelected
                             ? Color(nsColor: .controlAccentColor)
                             : theme.popupFilterTabInactive)
            .scaleEffect(isSelected ? ReduceMotion.scale(1.06) : 1.0)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                chipBackground(isSelected: isSelected, isLifted: isLifted, isHovered: isHovered)
            }
            .contentShape(Rectangle())
            .scaleEffect(isLifted ? ReduceMotion.scale(Self.liftScale) : (isPressed ? ReduceMotion.scale(Self.pressScale) : 1.0))
            .shadow(color: isLifted
                    ? Color.black.opacity(colorScheme == .dark ? 0.50 : 0.22)
                    : Color.clear,
                    radius: isLifted ? 7 : 0,
                    y: isLifted ? 3 : 0)
            .animation(AppleMotion.tactilePress, value: isPressed)
            .animation(AppleMotion.snappy, value: isLifted)
            .animation(ReduceMotion.animation(.easeOut(duration: 0.12)), value: isHovered)
            .onHover { hovering in
                guard draggingMode == nil else { return }
                if hovering {
                    hoveredMode = mode
                } else if hoveredMode == mode {
                    hoveredMode = nil
                }
            }
            .gesture(dragGesture(mode))
            .help(mode.title)
            .contextMenu { chipMenu(mode) }
            .accessibilityElement()
            .accessibilityLabel(mode.title)
            .accessibilityValue(isSelected ? "已选中" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSelect(mode) }
    }

    private func dragGesture(_ mode: FilterMode) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if draggingMode == nil {
                    if pressedMode != mode {
                        pressedMode = mode
                    }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard (dx * dx + dy * dy).squareRoot() >= Self.dragThreshold,
                          abs(dx) > abs(dy) else { return }
                    beginDrag(mode, translation: dx)
                }
                guard draggingMode == mode else { return }
                dragTranslation = value.translation.width
                updateTarget()
            }
            .onEnded { value in
                if draggingMode == mode {
                    finishDrag()
                } else if isInsideChip(mode, at: value.location) {
                    onSelect(mode)
                }
                pressedMode = nil
            }
    }

    private func isInsideChip(_ mode: FilterMode, at location: CGPoint) -> Bool {
        guard let frame = frames[mode] else { return true }
        return frame.insetBy(dx: -2, dy: -2).contains(location)
    }

    private var clampedTranslation: CGFloat {
        guard let mode = draggingMode, let own = frames[mode], !frames.isEmpty else {
            return dragTranslation
        }
        let minX = frames.values.map(\.minX).min() ?? own.minX
        let maxX = frames.values.map(\.maxX).max() ?? own.maxX
        return min(max(dragTranslation, minX - own.minX), maxX - own.maxX)
    }

    private var visibleOrder: [FilterMode] {
        FilterTabOrder.visible(order, hidden: hidden)
    }

    private func offset(for mode: FilterMode) -> CGFloat {
        let visible = visibleOrder
        guard draggingMode != nil, dragOrder.count == visible.count else { return 0 }
        if mode == draggingMode { return clampedTranslation }
        guard let position = dragOrder.firstIndex(of: mode),
              let home = visible.firstIndex(of: mode),
              let slot = frames[visible[position]],
              let own = frames[visible[home]] else { return 0 }
        return slot.minX - own.minX
    }

    private func beginDrag(_ mode: FilterMode, translation: CGFloat) {
        guard draggingMode == nil, frames[mode] != nil else { return }
        hoveredMode = nil
        draggingMode = mode
        dragOrder = visibleOrder
        dragTranslation = translation
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func updateTarget() {
        let visible = visibleOrder
        guard let mode = draggingMode,
              let own = frames[mode],
              let home = visible.firstIndex(of: mode),
              visible.count > 1 else { return }
        let center = own.midX + clampedTranslation
        var target = 0
        for position in 0 ..< (visible.count - 1) {
            guard let left = frames[visible[position]],
                  let right = frames[visible[position + 1]] else { continue }
            if center > (left.midX + right.midX) / 2 {
                target = position + 1
            }
        }
        guard target != (dragOrder.firstIndex(of: mode) ?? home) else { return }
        withAnimation(AppleMotion.snappy) {
            dragOrder = FilterTabOrder.moving(visible, from: home, to: target)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func finishDrag() {
        let visible = visibleOrder
        guard let mode = draggingMode, let home = visible.firstIndex(of: mode) else {
            draggingMode = nil
            dragOrder = []
            dragTranslation = 0
            return
        }
        let target = dragOrder.firstIndex(of: mode) ?? home
        let nextVisible = FilterTabOrder.moving(visible, from: home, to: target)
        let next = FilterTabOrder.merged(visible: nextVisible, into: order, hidden: hidden)
        if next != order {
            FilterTabOrder.persist(next)
        }
        withAnimation(AppleMotion.snappy) {
            order = next
            draggingMode = nil
            dragOrder = []
            dragTranslation = 0
        }
    }

    @ViewBuilder
    private func chipMenu(_ mode: FilterMode) -> some View {
        let visible = visibleOrder
        let index = visible.firstIndex(of: mode) ?? 0
        Button("隐藏「\(mode.title)」") { hideTab(mode) }
            .disabled(visible.count <= FilterTabOrder.minimumVisible)
        Menu("显示标签") {
            ForEach(FilterTabOrder.defaultOrder.filter { hidden.contains($0) }, id: \.self) { mode in
                Button(mode.title) { showTab(mode) }
            }
            if !hidden.isEmpty {
                Divider()
                Button("显示全部标签") { showAllTabs() }
            }
        }
        .disabled(hidden.isEmpty)
        Divider()
        Button("左移") { moveTab(mode, by: -1) }
            .disabled(index == 0)
        Button("右移") { moveTab(mode, by: 1) }
            .disabled(index >= visible.count - 1)
        Divider()
        Button("恢复默认顺序") { resetOrder() }
            .disabled(order == FilterTabOrder.defaultOrder)
    }

    private func moveTab(_ mode: FilterMode, by delta: Int) {
        let visible = visibleOrder
        guard let index = visible.firstIndex(of: mode) else { return }
        let target = index + delta
        guard visible.indices.contains(target) else { return }
        let nextVisible = FilterTabOrder.moving(visible, from: index, to: target)
        let next = FilterTabOrder.merged(visible: nextVisible, into: order, hidden: hidden)
        FilterTabOrder.persist(next)
        withAnimation(AppleMotion.snappy) {
            order = next
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    private func hideTab(_ mode: FilterMode) {
        guard visibleOrder.count > FilterTabOrder.minimumVisible, !hidden.contains(mode) else { return }
        var next = hidden
        next.insert(mode)
        FilterTabOrder.persistHidden(next)
        if mode == selected, let fallback = order.first(where: { !next.contains($0) }) {
            onSelect(fallback)
        }
        withAnimation(AppleMotion.snappy) {
            hidden = next
        }
    }

    private func showTab(_ mode: FilterMode) {
        guard hidden.contains(mode) else { return }
        var next = hidden
        next.remove(mode)
        FilterTabOrder.persistHidden(next)
        withAnimation(AppleMotion.snappy) {
            hidden = next
        }
    }

    private func showAllTabs() {
        guard !hidden.isEmpty else { return }
        FilterTabOrder.resetHidden()
        withAnimation(AppleMotion.snappy) {
            hidden = []
        }
    }

    private func resetOrder() {
        FilterTabOrder.reset()
        let next = FilterTabOrder.defaultOrder
        guard next != order else { return }
        withAnimation(AppleMotion.snappy) {
            order = next
        }
    }
}
