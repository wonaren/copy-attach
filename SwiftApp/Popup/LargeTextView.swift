import AppKit
import SwiftUI

// MARK: - Large Text Preview (NSTextView-backed, non-contiguous layout with adaptive typography)

struct LargeTextView: NSViewRepresentable {
    let preparedText: PreparedPreviewText
    let textColor: NSColor
    let isDark: Bool

    init(preparedText: PreparedPreviewText, textColor: NSColor, isDark: Bool = true) {
        self.preparedText = preparedText
        self.textColor = textColor
        self.isDark = isDark
    }

    init(text: String, textColor: NSColor, isDark: Bool = true) {
        self.preparedText = PreviewTextLayout.prepare(text)
        self.textColor = textColor
        self.isDark = isDark
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isHorizontallyResizable = false
        guard let textContainer = textView.textContainer else {
            scrollView.documentView = textView
            return scrollView
        }
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        applyContent(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Force text view width to match scroll view's clip view width.
        let clipWidth = scrollView.bounds.width
        if clipWidth > 0 {
            textView.frame.size.width = clipWidth
            let inset = textView.textContainerInset
            if let textContainer = textView.textContainer {
                textContainer.containerSize.width = max(clipWidth - inset.width * 2, 0)
            }
        }

        if textView.string != preparedText.displayText || textView.textColor != textColor {
            applyContent(to: textView)
        }
    }

    private func applyContent(to textView: NSTextView) {
        let attrString = NSMutableAttributedString(
            string: preparedText.displayText,
            attributes: PreviewTextLayout.attributes(for: preparedText.kind, textColor: textColor)
        )
        if let storage = textView.textStorage {
            storage.setAttributedString(attrString)
            PreviewHighlighter.highlight(
                storage: storage,
                kind: preparedText.kind,
                baseTextColor: textColor,
                isDark: isDark
            )
        }
        textView.font = PreviewTextLayout.font(for: preparedText.kind)
        textView.textColor = textColor
    }
}
