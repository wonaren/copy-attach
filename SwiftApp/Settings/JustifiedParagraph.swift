import AppKit
import SwiftUI

/// A paragraph that is justified on both edges with an indented first line.
///
/// SwiftUI's `Text` cannot produce this: `multilineTextAlignment` only offers
/// leading/center/trailing, and converting an `NSAttributedString` carrying an
/// `NSParagraphStyle` into an `AttributedString` silently drops the paragraph
/// style (verified by rendering both paths side by side — the SwiftUI one comes
/// out ragged and unindented). So this is the AppKit escape hatch: a
/// non-editable `NSTextField` that lays the paragraph out through CoreText.
///
/// Text stays resolution independent — glyphs are rasterised per frame at the
/// screen's backing scale, exactly like every native control, so Retina and
/// scaled external displays render crisp (no bitmap is involved anywhere).
struct JustifiedParagraph: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    /// Width in points. Fixed on purpose: the caller owns the paragraph's column.
    let width: CGFloat
    let lineSpacing: CGFloat
    /// First-line indent in points; defaults to two full-width characters.
    let firstLineIndent: CGFloat?

    init(
        text: String,
        font: NSFont,
        textColor: NSColor,
        width: CGFloat,
        lineSpacing: CGFloat = 3,
        firstLineIndent: CGFloat? = nil
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.width = width
        self.lineSpacing = lineSpacing
        self.firstLineIndent = firstLineIndent
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.preferredMaxLayoutWidth = width
        applyContent(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.preferredMaxLayoutWidth = width
        applyContent(to: field)
    }

    /// Ask the text field itself for the wrapped height so the SwiftUI layout and
    /// AppKit's line breaking can never disagree (a separately computed height
    /// would drift by a fraction of a point and clip the last line).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.preferredMaxLayoutWidth = width
        let height = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    private func applyContent(to field: NSTextField) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineSpacing = lineSpacing
        paragraph.firstLineHeadIndent = firstLineIndent ?? font.pointSize * 2
        paragraph.lineBreakMode = .byWordWrapping

        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
