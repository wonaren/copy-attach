import AppKit
import SwiftUI

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    let shortcutHint: String?
    let queueOrder: Int?
    let canToggleQueue: Bool
    let isFavorite: Bool
    let quickSlot: Int?
    let isEditingRemark: Bool
    @Binding var editingText: String
    let searchQuery: String
    let onToggleQueue: () -> Void
    let onCommitRemark: (String) -> Void
    let onCancelRemark: () -> Void
    let onHoverChange: ((Bool, NSRect, Bool) -> Void)?
    let selectionNamespace: Namespace.ID
    @State private var isHovering = false
    @State private var isQueueToggleHovered = false
    @State private var thumbImage: NSImage?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale

    private static let hexColorRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")
    }()

    private static let swatchCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    private func textColor(_ isSelected: Bool) -> Color {
        isSelected ? Color.white : theme.popupPrimaryText
    }
    private var mutedText: Color { theme.popupMutedText }
    private func sourceNameColor(_ isSelected: Bool) -> Color {
        isSelected ? Color.white.opacity(0.95) : theme.popupSecondaryText
    }

    private var selectionFill: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    private var deleteSelectionFill: Color {
        Color(nsColor: NSColor.systemRed.blended(withFraction: 0.22, of: .black) ?? .systemRed)
    }

    private var remarkAccent: Color? {
        isSelected ? nil : theme.popupRemarkAccent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            appIcon
            VStack(alignment: .leading, spacing: 0) {
                switch item {
                case .text(_, _, let customLabel, _, _, _, _, let displayPreview):
                    if isEditingRemark {
                        HStack(spacing: 4) {
                            InlineRemarkField(
                                text: $editingText,
                                placeholder: item.hasCustomLabel ? item.customLabel : "添加备注...",
                                textColor: colorScheme == .dark ? .white : NSColor(white: 0.1, alpha: 1.0),
                                onCommit: onCommitRemark,
                                onCancel: onCancelRemark
                            )
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.95))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(
                                            colorSchemeContrast == .increased
                                                ? (colorScheme == .dark ? Color.white : Color.black)
                                                : (colorScheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.30)),
                                            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                                        )
                                )
                        )
                    } else {
                        textContent(!customLabel.isEmpty ? customLabel : displayPreview,
                                    color: customLabel.isEmpty ? nil : remarkAccent)
                    }
                case .image(_, let dbId, let width, let height, _, let customLabel, _, _, _):
                    if isEditingRemark {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: .systemOrange))
                            InlineRemarkField(
                                text: $editingText,
                                placeholder: item.hasCustomLabel ? item.customLabel : "添加图片备注...",
                                textColor: colorScheme == .dark ? .white : NSColor(white: 0.1, alpha: 1.0),
                                onCommit: onCommitRemark,
                                onCancel: onCancelRemark
                            )
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.95))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(
                                            colorSchemeContrast == .increased
                                                ? (colorScheme == .dark ? Color.white : Color.black)
                                                : (colorScheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.30)),
                                            lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                                        )
                                )
                        )
                    } else if !customLabel.isEmpty {
                        let markColor = remarkAccent ?? textColor(true)
                        HStack(spacing: 5) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(markColor)
                                .help(width > 0 && height > 0 ? "图片 (\(width)×\(height))" : "图片")
                            textContent(customLabel, color: markColor)
                        }
                    } else {
                        imageContent(dbId: dbId)
                    }
                }
            }
            Spacer(minLength: 2)
            if item.hasCustomLabel {
                Image(systemName: "tag.fill")
                    .font(.system(size: 9.5))
                    .foregroundColor(remarkAccent ?? textColor(true))
                    .frame(width: 14, alignment: .center)
                    .help("备注: \(item.customLabel)")
                    .symbolEffect(.bounce, value: item.hasCustomLabel)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemYellow))
                    .frame(width: 16, alignment: .center)
                    .symbolEffect(.bounce, value: isFavorite)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if let slot = quickSlot, shortcutHint == nil {
                quickSlotBadge(slot)
            }
            queueToggleControl
            if isSelected && isDeleteModifierPressed {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white)
                    .frame(minWidth: 20, alignment: .center)
                    .padding(.trailing, 6)
                    .symbolEffect(.pulse, isActive: isDeleteModifierPressed)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? sourceNameColor(true) : Color(nsColor: .controlAccentColor))
                    .lineLimit(1)
                    .monospacedDigit()
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if !item.sourceName.isEmpty {
                let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                let nameText: Text = query.isEmpty ? Text(item.sourceName) : Text(highlightedAttributedString(item.sourceName, query: query))
                nameText
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(sourceNameColor(isSelected))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(isSelected ? Color.clear : theme.popupTagBackground))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isFavorite)
        .animation(.easeOut(duration: 0.15), value: quickSlot)
        .animation(.easeOut(duration: 0.15), value: item.hasCustomLabel)
        .background(selectionBackground)
        .background(RowHoverDetector { hovering, screenRect, moved in
            isHovering = hovering
            onHoverChange?(hovering, screenRect, moved)
        })
    }

    private func quickSlotBadge(_ slot: Int) -> some View {
        Text("右⌘\(slot)")
            .font(.system(size: 9.5, weight: .semibold))
            .monospacedDigit()
            .foregroundColor(isSelected ? Color.white : theme.popupPrimaryText)
            .lineLimit(1)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected
                          ? Color.black.opacity(0.28)
                          : Color(nsColor: .controlAccentColor).opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected
                                  ? Color.white.opacity(0.45)
                                  : Color(nsColor: .controlAccentColor).opacity(0.35),
                                  lineWidth: 0.5)
            )
            .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @ViewBuilder
    private var queueToggleControl: some View {
        if canToggleQueue {
            Button(action: onToggleQueue) {
                ZStack {
                    if let order = queueOrder {
                        Text("\(order)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundColor(isSelected ? (isDeleteModifierPressed ? deleteSelectionFill : selectionFill) : Color.white)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(isSelected ? Color.white : Color(nsColor: .controlAccentColor))
                            )
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    } else if isHovering {
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.14) : Color(nsColor: .controlAccentColor).opacity(0.12))
                            .overlay(
                                Circle().strokeBorder(
                                    isSelected ? Color.white.opacity(0.95) : Color(nsColor: .controlAccentColor),
                                    lineWidth: 1.8
                                )
                            )
                            .frame(width: 16, height: 16)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .scaleEffect(isQueueToggleHovered ? 1.12 : 1.0)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(isQueueToggleHovered ? queueToggleHoverFill : Color.clear)
                        .frame(width: 24, height: 24)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(queueOrder != nil || isHovering)
            .background(RowHoverDetector { hovering, _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    isQueueToggleHovered = hovering
                }
            })
            .help(queueOrder == nil ? "加入粘贴队列" : "移出粘贴队列")
        }
    }

    private var queueToggleHoverFill: Color {
        isSelected ? Color.white.opacity(0.22) : Color(nsColor: .controlAccentColor).opacity(0.20)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            let strokeColor: Color = isDeleteModifierPressed
                ? Color.white.opacity(0.85)
                : (colorSchemeContrast == .increased
                    ? Color.white
                    : Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.85))
            let strokeWidth: CGFloat = colorSchemeContrast == .increased ? 1.8 : 1.0

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDeleteModifierPressed ? deleteSelectionFill : selectionFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: strokeWidth)
                )
                .matchedGeometryEffect(id: "itemSelectionHighlight",
                                       in: selectionNamespace,
                                       properties: .frame)
        } else if isHovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.popupRowHover)
        }
    }

    private var appIcon: some View {
        Group {
            if !item.sourceBundleId.isEmpty, let nsImage = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: nsImage).resizable().frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Image(systemName: "app.fill").resizable().frame(width: 14, height: 14)
                    .foregroundColor(mutedText)
            }
        }
        .frame(width: 20, height: 20).foregroundColor(.white)
    }

    private var searchHighlightBackground: Color {
        if isSelected {
            return Color(nsColor: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 0.90))
        } else {
            return theme.popupSearchHighlightBackground
        }
    }

    private var searchHighlightForeground: Color {
        if isSelected {
            return Color(white: 0.30)
        } else {
            return theme.popupSearchHighlightText
        }
    }

    private func highlightedAttributedString(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }

        let bg = searchHighlightBackground
        let fg = searchHighlightForeground

        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = bg
            attributed[range].foregroundColor = fg
            guard range.upperBound > searchStart else { break }
            searchStart = range.upperBound
        }
        return attributed
    }

    private func textContent(_ displayText: String, color: Color? = nil) -> some View {
        coloredLabel(displayText)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(color ?? textColor(isSelected))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coloredLabel(_ text: String) -> Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.contains("#") else {
            guard !query.isEmpty else { return Text(text) }
            return Text(highlightedAttributedString(text, query: query))
        }

        guard let regex = Self.hexColorRegex else {
            guard !query.isEmpty else { return Text(text) }
            return Text(highlightedAttributedString(text, query: query))
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)

        if matches.isEmpty {
            guard !query.isEmpty else { return Text(text) }
            return Text(highlightedAttributedString(text, query: query))
        }

        var result = Text("")
        var lastEnd = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if lastEnd < range.lowerBound {
                let piece = String(text[lastEnd..<range.lowerBound])
                if query.isEmpty {
                    result = Text("\(result)\(piece)")
                } else {
                    result = Text("\(result)\(Text(highlightedAttributedString(piece, query: query)))")
                }
            }
            let code = String(text[range])
            let codeText: Text = query.isEmpty ? Text(code) : Text(highlightedAttributedString(code, query: query))
            if let swatch = Self.swatch(for: code) {
                result = Text("\(result)\(Image(nsImage: swatch))\(codeText)")
            } else {
                result = Text("\(result)\(codeText)")
            }
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            let piece = String(text[lastEnd...])
            if query.isEmpty {
                result = Text("\(result)\(piece)")
            } else {
                result = Text("\(result)\(Text(highlightedAttributedString(piece, query: query)))")
            }
        }

        return result
    }

    private static func swatch(for code: String) -> NSImage? {
        if let cached = swatchCache.object(forKey: code as NSString) {
            return cached
        }
        guard let color = Self.parseHexColor(code) else { return nil }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: 2, yRadius: 2)
        path.fill()
        image.unlockFocus()
        swatchCache.setObject(image, forKey: code as NSString)
        return image
    }

    private static func parseHexColor(_ hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard let value = UInt64(h, radix: 16) else { return nil }
        switch h.count {
        case 3:
            let r = CGFloat((value >> 8) & 0xF) / 15.0
            let g = CGFloat((value >> 4) & 0xF) / 15.0
            let b = CGFloat(value & 0xF) / 15.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        case 6:
            let r = CGFloat((value >> 16) & 0xFF) / 255.0
            let g = CGFloat((value >> 8) & 0xFF) / 255.0
            let b = CGFloat(value & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        default:
            return nil
        }
    }

    private var thumbnailBox: RowThumbnailBox {
        RowThumbnailBox.current(scale: displayScale)
    }

    private func imageContent(dbId: Int) -> some View {
        HStack(spacing: 8) {
            if let nsImage = thumbImage ?? ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.popupRowBorder, lineWidth: 0.5))
            } else if dbId == 0 {
                ShimmerPlaceholderCard(title: "图片编码中…", iconName: "photo", maxHeight: 46)
            } else {
                ShimmerPlaceholderCard(title: "载入预览中…", iconName: "photo", maxHeight: 46)
            }
        }
        .task(id: dbId) {
            guard dbId != 0 else { return }
            let img = await ClipboardBackend.shared.loadThumbnail(dbId: dbId, box: thumbnailBox)
            guard !Task.isCancelled else { return }
            thumbImage = img
        }
        .onDisappear {
            thumbImage = nil
        }
    }
}

extension ItemRowView: @preconcurrency Equatable {
    @MainActor
    static func == (lhs: ItemRowView, rhs: ItemRowView) -> Bool {
        lhs.item == rhs.item &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isDeleteModifierPressed == rhs.isDeleteModifierPressed &&
        lhs.shortcutHint == rhs.shortcutHint &&
        lhs.queueOrder == rhs.queueOrder &&
        lhs.canToggleQueue == rhs.canToggleQueue &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.quickSlot == rhs.quickSlot &&
        lhs.isEditingRemark == rhs.isEditingRemark &&
        (!lhs.isEditingRemark || lhs.editingText == rhs.editingText) &&
        lhs.searchQuery == rhs.searchQuery
    }
}

private extension String {
    func collapsedPreview() -> String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "⏎")
    }
}

private struct RowHoverDetector: NSViewRepresentable {
    let onChange: (Bool, NSRect, Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool, NSRect, Bool) -> Void)?
        private var lastValue: Bool?
        private var sawMouseMove = false
        private var lastScreenLocation: NSPoint?
        private var installedArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sawMouseMove = false
            lastScreenLocation = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in self?.refresh(force: false) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if installedArea == nil {
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(area)
                installedArea = area
            }
            refresh(force: false)
        }

        override func mouseEntered(with event: NSEvent) { refresh(force: false) }
        override func mouseMoved(with event: NSEvent) { refresh(force: false) }

        override func mouseExited(with event: NSEvent) {
            sawMouseMove = false
            lastScreenLocation = NSEvent.mouseLocation
            refresh(force: true)
        }

        private func refresh(force: Bool) {
            guard let window else { return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let movedNow = noteLocation(NSEvent.mouseLocation)
            let wasMoved = sawMouseMove
            if movedNow { sawMouseMove = true }
            let inside = bounds.contains(point)
            guard force || lastValue != inside || (sawMouseMove && !wasMoved) else { return }
            lastValue = inside
            let screenRect = window.convertToScreen(convert(bounds, to: nil))
            onChange?(inside, screenRect, sawMouseMove && inside)
        }

        private func noteLocation(_ point: NSPoint) -> Bool {
            defer { lastScreenLocation = point }
            guard let last = lastScreenLocation else { return true }
            return hypot(point.x - last.x, point.y - last.y) > 1
        }
    }
}

struct InlineRemarkField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var textColor: NSColor = .white
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.textColor = textColor
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1

        DispatchQueue.main.async {
            if let window = field.window {
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.textColor != textColor {
            nsView.textColor = textColor
        }
        if nsView.stringValue != text && nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRemarkField
        var didCommitOrCancel = false

        init(_ parent: InlineRemarkField) {
            self.parent = parent
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     shouldChangeTextIn affectedCharRange: NSRange,
                     replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            return MainActor.assumeIsolated {
                let current = textView.string as NSString
                guard affectedCharRange.location != NSNotFound,
                      affectedCharRange.location + affectedCharRange.length <= current.length else {
                    return true
                }
                let proposed = current.replacingCharacters(in: affectedCharRange, with: replacement)
                return proposed.unicodeScalars.count <= ClipboardBackend.maxCustomLabelScalars
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                if !didCommitOrCancel {
                    didCommitOrCancel = true
                    control.window?.makeFirstResponder(control.window?.contentView)
                    parent.onCommit(control.stringValue)
                }
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !didCommitOrCancel {
                    didCommitOrCancel = true
                    control.window?.makeFirstResponder(control.window?.contentView)
                    parent.onCancel()
                }
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if !didCommitOrCancel {
                didCommitOrCancel = true
                field.window?.makeFirstResponder(field.window?.contentView)
                parent.onCommit(field.stringValue)
            }
        }
    }
}
