import AppKit
import SwiftUI

// MARK: - Preview Window (non-key, auto-sized, content driven by direct value)

class PreviewWindow: NSPanel {
    private let centerAnchor: NSPoint
    private var hostingView: NSHostingView<AnyView>?
    private var currentItemId: Int = 0

    /// Cache text heights per entryId so arrow-key navigation doesn't re-layout.
    /// Bounded: the static dictionary would otherwise keep an entry for every
    /// item ever previewed across the whole process lifetime (including
    /// deleted entries). 512 entries is far beyond any realistic preview
    /// session; older entries are evicted and simply re-measured.
    private static var textHeightCache: [Int: CGFloat] = [:]
    private static let textHeightCacheMaxEntries = 512

    override var canBecomeKey: Bool { false }

    init(item: ClipboardItem, centerAt screenCenter: NSPoint) {
        let targetScreen = NSScreen.screens.first(where: { NSPointInRect(screenCenter, $0.frame) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = Self.contentSize(for: item, screenFrame: screenFrame)
        let x = screenCenter.x - size.width / 2
        let y = screenCenter.y - size.height / 2

        self.centerAnchor = screenCenter

        self.currentItemId = item.id

        super.init(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.isMovableByWindowBackground = true

        let content = AnyView(PreviewContent(item: item).withAppTheme())
        let hosting = NSHostingView(rootView: content)
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.cornerCurve = .continuous
        hosting.autoresizingMask = [.width, .height]

        self.contentView = hosting
        self.hostingView = hosting
    }

    /// Update displayed content and resize window — called by popup on selection change.
    func updateContent(item: ClipboardItem) {
        guard currentItemId != item.id else { return }
        currentItemId = item.id

        // No CATransition here: a cross-fade makes CA keep snapshots of both
        // the old and new frames while the transition runs. Under rapid
        // arrow-key switching those snapshots accumulate as software-rendered
        // (Whippet) drawables — measured at ~7 MB per switch on big-image
        // previews, some of which never got released after close. Direct root
        // replacement is visually equivalent for 150 ms and keeps the window
        // to a single backing store.
        hostingView?.rootView = AnyView(PreviewContent(item: item).withAppTheme())
        resizeToFitContent(for: item)
    }

    override func close() {
        Self.textHeightCache.removeAll()

        // contentView is not the only owner: hostingView is retained by this
        // window so it can update previews in place. Detach its root first;
        // otherwise PreviewContent keeps its NSImage, which keeps the CGImage
        // provider and Rust preview buffer alive after the window closes.
        hostingView?.rootView = AnyView(EmptyView())
        hostingView = nil
        self.contentView = nil

        super.close()
        self.alphaValue = 1.0
    }

    // MARK: - Window resizing

    private func resizeToFitContent(for item: ClipboardItem) {
        let targetScreen = NSScreen.screens.first(where: { NSPointInRect(centerAnchor, $0.frame) }) ?? NSScreen.main
        guard let screenFrame = targetScreen?.visibleFrame, screenFrame.width > 0 else { return }
        let newSize = Self.contentSize(for: item, screenFrame: screenFrame)
        let oldSize = self.frame.size
        guard abs(newSize.width - oldSize.width) > 2 || abs(newSize.height - oldSize.height) > 2 else { return }
        let newOrigin = NSPoint(
            x: centerAnchor.x - newSize.width / 2,
            y: centerAnchor.y - newSize.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: newSize)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Auto-sizing

    private static func contentSize(for item: ClipboardItem, screenFrame: NSRect) -> NSSize {
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85

        switch item {
        case .text(let entryId, _, _, _, _, let text, _):
            let pad: CGFloat = 32
            // Find the longest line in the text to determine adaptive window width.
            // Single-pass, line-at-a-time: the old `components(separatedBy: .newlines)`
            // copied the ENTIRE text into an array of per-line strings held
            // simultaneously — a multi-MB paste doubled its resident size just to
            // measure the width. `enumerateLines` keeps one line alive at a time,
            // and the scan stops early once a line already saturates the width
            // cap (the final width is clamped to `maxW` anyway, so later lines
            // can no longer change the result).
            let widthLimit = maxW - pad
            var longestLineWidth: CGFloat = 0
            text.enumerateLines { line, stop in
                let lineWidth = (line as NSString)
                    .size(withAttributes: [.font: PreviewTextLayout.font]).width
                if lineWidth > longestLineWidth { longestLineWidth = lineWidth }
                if longestLineWidth >= widthLimit { stop = true }
            }
            let textWidth = min(max(longestLineWidth + pad, 300), maxW)
            let containerW = textWidth - pad
            let textH = calculateTextHeight(text, width: containerW, entryId: entryId, maxHeight: maxH)
            let totalH = min(textH + pad, maxH)
            return NSSize(width: textWidth, height: max(totalH, 100))

        case .image(_, _, let w, let h, _, _, _, _):
            guard w > 0, h > 0 else {
                return NSSize(width: 320, height: 240)
            }
            // Cap display height at 720; don't upscale images shorter than that.
            let capH: CGFloat = 720
            let displayH = CGFloat(h) < capH ? CGFloat(h) : capH
            let aspect = CGFloat(w) / CGFloat(h)
            let displayW = displayH * aspect
            let pad: CGFloat = 24
            let finalW = min(displayW + pad, maxW)
            let finalH = min(displayH + pad, maxH)
            return NSSize(width: max(finalW, 100), height: max(finalH, 100))
        }
    }

    private static func calculateTextHeight(_ text: String, width: CGFloat, entryId: Int, maxHeight: CGFloat) -> CGFloat {
        if let cached = textHeightCache[entryId] { return cached }
        let height = PreviewTextLayout.measureHeight(text, width: width, maxHeight: maxHeight) + 28
        if textHeightCache.count >= textHeightCacheMaxEntries,
           let key = textHeightCache.keys.first {
            textHeightCache.removeValue(forKey: key)
        }
        textHeightCache[entryId] = height
        return height
    }
}
