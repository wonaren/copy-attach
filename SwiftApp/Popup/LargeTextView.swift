import AppKit
import SwiftUI

// MARK: - Large Text Preview (NSTextView-backed, non-contiguous layout)

struct LargeTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
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
        textView.textContainer!.widthTracksTextView = true
        textView.textContainer!.lineFragmentPadding = 0

        // Set attributed string with font + line spacing + color (shared metrics)
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: PreviewTextLayout.attributes(textColor: textColor)))
        // Also set NSTextView-level font/color so readers of textView.font and the
        // else-if comparison in updateNSView get the expected value.
        textView.font = PreviewTextLayout.font
        textView.textColor = textColor

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Force text view width to match scroll view's clip view width.
        let clipWidth = scrollView.bounds.width
        textView.frame.size.width = clipWidth
        let inset = textView.textContainerInset
        textView.textContainer!.containerSize.width = clipWidth - inset.width * 2

        if textView.string != text {
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: PreviewTextLayout.attributes(textColor: textColor)))
        } else if textView.textColor != textColor {
            textView.textColor = textColor
            let len = textView.textStorage?.length ?? 0
            if len > 0 {
                textView.textStorage?.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: len))
            }
        }
    }
}
