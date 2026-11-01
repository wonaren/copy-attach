import AppKit
import SwiftUI

struct JustifiedParagraph: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let width: CGFloat
    let lineSpacing: CGFloat
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
