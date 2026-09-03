import AppKit

/// Shared text attributes for preview text (font + line spacing).
/// Both the height measurement in PreviewWindow and the rendering in
/// LargeTextView must use the same metrics so the window height matches
/// the actual text layout.
@MainActor
enum PreviewTextLayout {
    static let font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    static let lineSpacing: CGFloat = 5

    /// Prebuilt paragraph style — avoids heap allocation on every attributes() call.
    private static let _paragraphStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = lineSpacing
        return ps
    }()

    static func attributes(textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: _paragraphStyle
        ]
    }

    /// Measure the rendered height of `text` constrained to `width` and bounded by `maxHeight`.
    static func measureHeight(_ text: String, width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        // Fast path: if quick line estimate exceeds maxHeight, avoid full NSLayoutManager glyph layout
        let approxLineHeight: CGFloat = 19.0 // 14pt font + 5pt line spacing
        let maxLinesNeeded = Int(ceil(maxHeight / approxLineHeight)) + 2

        var lineCount = 0
        text.enumerateLines { _, stop in
            lineCount += 1
            if lineCount >= maxLinesNeeded {
                stop = true
            }
        }

        if lineCount >= maxLinesNeeded {
            return maxHeight
        }

        // Short text: precise layout
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes(textColor: .white)))
        _ = layoutManager.glyphRange(for: textContainer)
        return min(layoutManager.usedRect(for: textContainer).height, maxHeight)
    }
}
