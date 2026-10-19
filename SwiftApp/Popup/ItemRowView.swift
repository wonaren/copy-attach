import AppKit
import SwiftUI

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    let shortcutHint: String?
    let queueOrder: Int?
    let isFavorite: Bool
    let isEditingRemark: Bool
    @Binding var editingText: String
    let searchQuery: String
    let onCommitRemark: (String) -> Void
    let onCancelRemark: () -> Void
    let selectionNamespace: Namespace.ID
    @State private var isHovering = false
    /// The row's decoded thumbnail once loaded (async, off-main). Also keeps
    /// the row from re-looking up the cache on every body evaluation.
    @State private var thumbImage: NSImage?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale

    private static let hexColorRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")
    }()

    /// 10×10 color swatches are drawn once per unique hex color and cached —
    /// the per-render `lockFocus` path (a fresh graphics context per match)
    /// was the most expensive thing in this row's body. Bounded so a hostile
    /// clipboard full of distinct colors cannot grow it without limit.
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
        // White at 95% on the selection fill is 4.8:1 (light) / 5.6:1 (dark).
        // `theme.popupPrimaryText` is near-black in the light theme, which read
        // as a stray dark label on the blue pill.
        isSelected ? Color.white.opacity(0.95) : theme.popupSecondaryText
    }

    /// Platform selection fill (a darker shade of the user's accent), not the
    /// raw accent. Measured: white on `controlAccentColor` (#007AFF) is 4.07:1
    /// — below AA — and the large saturated pill is what read as glaring.
    /// `selectedContentBackgroundColor` gives 5.4:1 (light) / 6.3:1 (dark) with
    /// white, inside the AA–AAA band, and follows the user's accent + contrast
    /// settings automatically.
    private var selectionFill: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    /// Delete-mode fill. `systemRed` with white text is only 3.5:1; blending
    /// 22% black raises it to 5.1:1 (light) / 4.9:1 (dark).
    private var deleteSelectionFill: Color {
        Color(nsColor: NSColor.systemRed.blended(withFraction: 0.22, of: .black) ?? .systemRed)
    }

    /// Teal accent for a user-authored remark, or nil on the selected row.
    ///
    /// The selected row is already marked by a solid accent-colored pill (or
    /// red in delete mode); keeping the warm accent there would put it on an
    /// unknown accent hue and break the contrast the theme values guarantee.
    /// Text falls back to the selection foreground, exactly like every other
    /// selected row.
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
                        // A remark replaces the preview as the row's content and
                        // carries the remark accent; ordinary entries keep the
                        // default readable foreground.
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
                        // Same accent as text remarks: one semantic color for
                        // "this entry has a note", white when selected.
                        let markColor = remarkAccent ?? textColor(true)
                        HStack(spacing: 5) {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(markColor)
                                .help(width > 0 && height > 0 ? "图片 (\(width)×\(height))" : "图片")
                            textContent(customLabel, color: markColor)
                        }
                    } else {
                        imageContent(dbId: dbId, width: width, height: height)
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
                    // Never from scale(0): nothing in the real world appears
                    // from nothing. 0.9 + opacity reads as the badge growing
                    // into place rather than materializing.
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemYellow))
                    .frame(width: 16, alignment: .center)
                    .symbolEffect(.bounce, value: isFavorite)
                    // Never from scale(0): nothing in the real world appears
                    // from nothing. 0.9 + opacity reads as the badge growing
                    // into place rather than materializing.
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if let order = queueOrder {
                let badgeBgColor: Color = isSelected
                    ? Color.white
                    : Color(nsColor: .controlAccentColor)
                // The selected badge is a white disc: its label must clear 4.5:1
                // against white, so use the same (darker) fills as the row.
                let badgeTextColor: Color = isSelected
                    ? (isDeleteModifierPressed ? deleteSelectionFill : selectionFill)
                    : Color.white

                Text("\(order)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(badgeTextColor)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(badgeBgColor)
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if isSelected && isDeleteModifierPressed {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white)
                    .frame(minWidth: 20, alignment: .center)
                    .padding(.trailing, 6)
                    .symbolEffect(.pulse, isActive: isDeleteModifierPressed)
                    // Never from scale(0): nothing in the real world appears
                    // from nothing. 0.9 + opacity reads as the badge growing
                    // into place rather than materializing.
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? sourceNameColor(true) : Color(nsColor: .controlAccentColor))
                    .lineLimit(1)
                    .monospacedDigit()
                    // Never from scale(0): nothing in the real world appears
                    // from nothing. 0.9 + opacity reads as the badge growing
                    // into place rather than materializing.
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
                    // No capsule on the selected row: the light-theme capsule
                    // is an opaque near-white block that clashed with the blue
                    // pill. The label alone carries it there.
                    .background(Capsule().fill(isSelected ? Color.clear : theme.popupTagBackground))
                    // Never from scale(0): nothing in the real world appears
                    // from nothing. 0.9 + opacity reads as the badge growing
                    // into place rather than materializing.
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        // Content flips its selection color quickly instead of riding the
        // container's spring — a springing text crossfade reads as slow/floaty.
        .animation(.easeOut(duration: 0.1), value: isSelected)
        // The star/tag badges insert and remove on these values; without a
        // transaction their `.transition` never runs and they pop. Scoped to
        // the value so nothing else on the row animates.
        .animation(.easeOut(duration: 0.15), value: isFavorite)
        .animation(.easeOut(duration: 0.15), value: item.hasCustomLabel)
        .background(selectionBackground)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// Selection/hover backdrop. The selected row hosts a matched-geometry
    /// RoundedRectangle so the highlight glides to the next row as the
    /// selection moves (Spotlight-style). Hover stays a static fill.
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

    /// Build a Text view with inline color swatches for hex color codes and search highlights.
    private func coloredLabel(_ text: String) -> Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // Most clipboard texts contain no '#' at all — skip the regex engine
        // for them (the regex runs on every body evaluation, i.e. hover,
        // selection moves, and scroll refreshes of every visible row).
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
            // Text before this color code
            if lastEnd < range.lowerBound {
                let piece = String(text[lastEnd..<range.lowerBound])
                if query.isEmpty {
                    result = Text("\(result)\(piece)")
                } else {
                    result = Text("\(result)\(Text(highlightedAttributedString(piece, query: query)))")
                }
            }
            // Color code with swatch
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

    /// Cached swatch image for a hex code (`#RGB` / `#RRGGBB`), nil for
    /// non-colors. The 10×10 NSImage is drawn once per unique color.
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

    /// Parse a hex color string (#RGB or #RRGGBB) into NSColor.
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

    /// Display box the row draws an image into, at this screen's scale. Mirrors
    /// the `.frame(maxHeight: 100)` below and Rust's `THUMB_BOX_*` (which sizes
    /// the stored blob); the box is one rectangle, so flat and tall images share
    /// a single source of truth instead of each guessing a longest edge.
    private var thumbnailBox: RowThumbnailBox {
        RowThumbnailBox.current(scale: displayScale)
    }

    private func imageContent(dbId: Int, width: Int, height: Int) -> some View {
        HStack(spacing: 8) {
            // Synchronous cache hit renders instantly (no IO); a miss shows
            // the shimmer placeholder card while `loadThumbnail` decodes off-main.
            if let nsImage = thumbImage ?? ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.popupRowBorder, lineWidth: 0.5))
            } else if dbId == 0 {
                ShimmerPlaceholderCard(title: "图片编码中…", iconName: "photo")
            } else {
                ShimmerPlaceholderCard(title: "载入预览中…", iconName: "photo")
            }
        }
        // Load the thumbnail off the main thread (FFI read + PNG decode).
        // `id: dbId` restarts the task when Phase 2 completes (dbId 0 → rowid)
        // and auto-cancels it when the row scrolls out of view. The loader is
        // concurrency-bounded and cancellation prevents publishing an image
        // into a row that is no longer visible.
        .task(id: dbId) {
            guard dbId != 0 else { return }
            let img = await ClipboardBackend.shared.loadThumbnail(dbId: dbId, box: thumbnailBox)
            guard !Task.isCancelled else { return }
            thumbImage = img
        }
        .onDisappear {
            // Release the row's strong image reference immediately. NSCache is
            // intentionally the only owner after a row leaves the viewport.
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
        lhs.isFavorite == rhs.isFavorite &&
        lhs.isEditingRemark == rhs.isEditingRemark &&
        (!lhs.isEditingRemark || lhs.editingText == rhs.editingText) &&
        lhs.searchQuery == rhs.searchQuery
    }
}

private extension String {
    /// Single-line preview: split on newlines, trim each line, drop empties,
    /// join with ⏎. Applied to bounded head/tail windows in `textContent`.
    func collapsedPreview() -> String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "⏎")
    }
}

// MARK: - Inline Remark Editor Field (Native AppKit NSTextField for perfect focus & key containment)

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
        // Keep the coordinator's copy current: it captures the binding and the
        // commit/cancel closures, which must reflect the latest render.
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

        /// Cap the remark while it is being typed or pasted. Counting scalars
        /// (not grapheme clusters) keeps this exactly aligned with the Rust
        /// `MAX_CUSTOM_LABEL_SCALARS` check, which would otherwise reject a
        /// field the UI considered legal (emoji / combining marks).
        func control(_ control: NSControl,
                     textView: NSTextView,
                     shouldChangeTextIn affectedCharRange: NSRange,
                     replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            // AppKit delivers this on the main thread; the SDK's
            // NSControlTextEditingDelegate is not MainActor-annotated, so the
            // contract is stated explicitly.
            return MainActor.assumeIsolated {
                let current = textView.string as NSString
                // IME composition can report a range past the current string; the
                // cap is a guard, so let the text system handle anything unexpected.
                guard affectedCharRange.location != NSNotFound,
                      affectedCharRange.location + affectedCharRange.length <= current.length else {
                    return true
                }
                let proposed = current.replacingCharacters(in: affectedCharRange, with: replacement)
                return proposed.unicodeScalars.count <= ClipboardBackend.maxCustomLabelScalars
            }
        }

        /// Mirror the field's live text back into the binding, so callers that
        /// commit on a path other than Enter (switching rows / tabs / search)
        /// have the text the user actually typed.
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
