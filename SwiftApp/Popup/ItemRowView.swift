import AppKit
import SwiftUI

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    let shortcutHint: String?
    let isFavorite: Bool
    let isEditingRemark: Bool
    @Binding var editingText: String
    let onCommitRemark: (String) -> Void
    let onCancelRemark: () -> Void
    let selectionNamespace: Namespace.ID
    @State private var isHovering = false
    /// The row's decoded thumbnail once loaded (async, off-main). Also keeps
    /// the row from re-looking up the cache on every body evaluation.
    @State private var thumbImage: NSImage?
    @Environment(\.appTheme) private var theme

    private static let hexColorRegex = try! NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")

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
        isSelected ? theme.popupPrimaryText : theme.popupSecondaryText
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
                                onCommit: onCommitRemark,
                                onCancel: onCancelRemark
                            )
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                                )
                        )
                    } else {
                        textContent(!customLabel.isEmpty ? customLabel : displayPreview)
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
                                onCommit: onCommitRemark,
                                onCancel: onCancelRemark
                            )
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                                )
                        )
                    } else if !customLabel.isEmpty {
                        let markColor = (isSelected && isDeleteModifierPressed) ? Color.white : Color(nsColor: .systemOrange)
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
                    .foregroundColor(Color(nsColor: .systemTeal))
                    .frame(width: 14, alignment: .center)
                    .help("备注: \(item.customLabel)")
                    .transition(.scale.combined(with: .opacity))
            }
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemYellow))
                    .frame(width: 16, alignment: .center)
                    .transition(.scale.combined(with: .opacity))
            }
            if isSelected && isDeleteModifierPressed {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white)
                    .frame(minWidth: 20, alignment: .center)
                    .padding(.trailing, 6)
                    .transition(.scale.combined(with: .opacity))
            } else if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? sourceNameColor(true) : Color(nsColor: .controlAccentColor))
                    .lineLimit(1)
                    .monospacedDigit()
                    .transition(.scale.combined(with: .opacity))
            } else if !item.sourceName.isEmpty {
                Text(item.sourceName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(sourceNameColor(isSelected))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(theme.popupTagBackground))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        // Content flips its selection color quickly instead of riding the
        // container's spring — a springing text crossfade reads as slow/floaty.
        .animation(.easeOut(duration: 0.1), value: isSelected)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDeleteModifierPressed ? Color(nsColor: .systemRed) : Color(nsColor: .controlAccentColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isDeleteModifierPressed
                                ? Color(nsColor: .systemRed)
                                : Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.8),
                            lineWidth: 1
                        )
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
                    .foregroundColor(mutedText.opacity(0.5))
            }
        }
        .frame(width: 20, height: 20).foregroundColor(.white)
    }

    private func textContent(_ displayText: String, color: Color? = nil) -> some View {
        coloredLabel(displayText)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(color ?? textColor(isSelected))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build a Text view with inline color swatches for hex color codes.
    private func coloredLabel(_ text: String) -> Text {
        // Most clipboard texts contain no '#' at all — skip the regex engine
        // for them (the regex runs on every body evaluation, i.e. hover,
        // selection moves, and scroll refreshes of every visible row).
        guard text.contains("#") else { return Text(text) }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = Self.hexColorRegex.matches(in: text, range: nsRange)

        if matches.isEmpty { return Text(text) }

        var result = Text("")
        var lastEnd = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            // Text before this color code
            if lastEnd < range.lowerBound {
                result = Text("\(result)\(String(text[lastEnd..<range.lowerBound]))")
            }
            // Color code with swatch
            let code = String(text[range])
            if let swatch = Self.swatch(for: code) {
                result = Text("\(result)\(Image(nsImage: swatch))\(code)")
            } else {
                result = Text("\(result)\(code)")
            }
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            result = Text("\(result)\(String(text[lastEnd...]))")
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

    private func imageContent(dbId: Int, width: Int, height: Int) -> some View {
        HStack(spacing: 8) {
            // Synchronous cache hit renders instantly (no IO); a miss shows
            // the placeholder while `loadThumbnail` decodes off-main (below).
            if let nsImage = thumbImage ?? ClipboardBackend.shared.cachedThumbnail(dbId: dbId) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.popupRowHover, lineWidth: 0.5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(mutedText.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(maxHeight: 100)
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            // Source: Image
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.system(size: 18))
                                    .foregroundColor(mutedText.opacity(0.8))
                            }
                            .frame(width: 36, height: 36)
                            .background(theme.popupRowDefault)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(mutedText.opacity(0.15), lineWidth: 1)
                            )

                            // Flow/Processing Indicator
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(mutedText.opacity(0.5))
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 10)
                            }

                            // Destination: Local
                            VStack(spacing: 4) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 18))
                                    .foregroundColor(mutedText.opacity(0.8))
                            }
                            .frame(width: 36, height: 36)
                            .background(theme.popupRowDefault)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(mutedText.opacity(0.15), lineWidth: 1)
                            )
                        }
                        Text("图片编码中")
                            .font(.system(size: 11))
                            .foregroundColor(mutedText.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        // Load the thumbnail off the main thread (FFI read + PNG decode).
        // `id: dbId` restarts the task when Phase 2 completes (dbId 0 → rowid)
        // and auto-cancels it when the row scrolls out of view. The loader is
        // concurrency-bounded and cancellation prevents publishing an image
        // into a row that is no longer visible.
        .task(id: dbId) {
            guard dbId != 0 else { return }
            let img = await ClipboardBackend.shared.loadThumbnail(dbId: dbId)
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
        field.textColor = .white
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
