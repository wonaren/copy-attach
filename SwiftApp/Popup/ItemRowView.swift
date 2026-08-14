import AppKit
import SwiftUI

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    let shortcutHint: String?
    let isFavorite: Bool
    let selectionNamespace: Namespace.ID
    @State private var isHovering = false
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
                case .text(_, _, _, _, _, _, let preview):
                    textContent(preview)
                case .image(_, let dbId, let width, let height, _, _, _, _):
                    imageContent(dbId: dbId, width: width, height: height)
                }
            }
            Spacer(minLength: 2)
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

    private func textContent(_ text: String) -> some View {
        // `text` is the backend preview, already bounded to 256 scalars; long
        // entries arrive elided to head……tail, so the cut below always sees the
        // real ending. Collapsing the bounded preview is cheap — no local cap.
        let displayText = text.collapsedPreview()
        let display: String
        let visualLen = visualWidth(displayText)
        if visualLen > 50 {
            let prefix = String(displayText.prefix(whileVisualWidth: 25))
            let suffix = String(displayText.suffix(whileVisualWidth: 25))
            display = "\(prefix)……\(suffix)"
        } else { display = displayText }
        return coloredLabel(display)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(textColor(isSelected))
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
            if let nsImage = ClipboardBackend.shared.getCachedThumbnail(dbId: dbId) {
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
