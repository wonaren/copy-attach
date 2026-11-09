import AppKit
import SwiftUI

private final class PreviewTextView: NSTextView {
    var onTap: (() -> Void)?
    private var mouseDownAtRest = false
    private var mouseDownLocation: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard onTap != nil else {
            super.mouseDown(with: event)
            return
        }
        mouseDownAtRest = true
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard onTap == nil else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownAtRest else {
            super.mouseUp(with: event)
            return
        }
        mouseDownAtRest = false
        let down = mouseDownLocation
        mouseDownLocation = nil
        if let down,
           hypot(event.locationInWindow.x - down.x,
                 event.locationInWindow.y - down.y) > 3 {
            return
        }
        onTap?()
    }
}

struct LargeTextView: NSViewRepresentable {
    let preparedText: PreparedPreviewText
    let textColor: NSColor
    let isDark: Bool
    var onTap: (() -> Void)?

    init(preparedText: PreparedPreviewText, textColor: NSColor, isDark: Bool = true, onTap: (() -> Void)? = nil) {
        self.preparedText = preparedText
        self.textColor = textColor
        self.isDark = isDark
        self.onTap = onTap
    }

    init(text: String, textColor: NSColor, isDark: Bool = true, onTap: (() -> Void)? = nil) {
        self.preparedText = PreviewTextLayout.prepare(text)
        self.textColor = textColor
        self.isDark = isDark
        self.onTap = onTap
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

        let textView = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = onTap == nil
        textView.onTap = onTap
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 13, height: 11)
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
        guard let textView = scrollView.documentView as? PreviewTextView else { return }
        textView.onTap = onTap
        textView.isSelectable = onTap == nil

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
