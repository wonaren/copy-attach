import AppKit
import SwiftUI

// MARK: - Preview Window (non-key, auto-sized, content driven by direct value)

class PreviewWindow: NSPanel {
    private let centerAnchor: NSPoint
    private var hostingView: NSHostingView<AnyView>!
    private var currentItemId: Int = 0

    /// Cache text heights per entryId so arrow-key navigation doesn't re-layout.
    private static var textHeightCache: [Int: CGFloat] = [:]

    override var canBecomeKey: Bool { false }

    init(item: ClipboardItem, centerAt screenCenter: NSPoint) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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

        // Cross-fade content during transition
        let fade = CATransition()
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.type = .fade
        hostingView.layer?.add(fade, forKey: kCATransition)

        hostingView.rootView = AnyView(PreviewContent(item: item).withAppTheme())
        resizeToFitContent(for: item)
    }

    override func close() {
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0
    }

    // MARK: - Window resizing

    private func resizeToFitContent(for item: ClipboardItem) {
        guard let screenFrame = NSScreen.main?.visibleFrame, screenFrame.width > 0 else { return }
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
        case .text(let entryId, let text, _, _, _, _, _):
            let pad: CGFloat = 32
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            // Find the longest line in the text to determine adaptive window width
            let longestLine = text.components(separatedBy: .newlines).max(by: { $0.count < $1.count }) ?? ""
            let lineWidth = (longestLine as NSString).size(withAttributes: [.font: font]).width
            let textWidth = min(max(lineWidth + pad, 300), maxW)
            let containerW = textWidth - pad
            let textH = calculateTextHeight(text, width: containerW, entryId: entryId)
            let totalH = min(textH + pad, maxH)
            return NSSize(width: textWidth, height: max(totalH, 100))

        case .image(_, _, let w, let h, _, _, _, _):
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

    private static func calculateTextHeight(_ text: String, width: CGFloat, entryId: Int) -> CGFloat {
        if let cached = textHeightCache[entryId] { return cached }

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))

        _ = layoutManager.glyphRange(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        let height = rect.height + 24
        textHeightCache[entryId] = height
        return height
    }
}

// MARK: - Preview Content

struct PreviewContent: View {
    let item: ClipboardItem

    @State private var image: NSImage?
    @State private var isLoadingImage = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var currentDbId: Int {
        guard case .image(_, let dbId, _, _, _, _, _, _) = item else { return 0 }
        return dbId
    }

    private var previewTextNSColor: NSColor {
        colorScheme == .dark
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor(white: 0.12, alpha: 1.0)
    }

    var body: some View {
        ZStack {
            theme.previewBackground
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch item {
            case .text(_, let text, _, _, _, _, _):
                LargeTextView(text: text, textColor: previewTextNSColor)
            case .image(_, let dbId, _, _, _, _, _, _):
                imageContent(dbId: dbId)
            }
        }
    }

    @ViewBuilder
    private func imageContent(dbId: Int) -> some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else if isLoadingImage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundColor(theme.previewSecondaryText)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 24))
                    .foregroundColor(theme.previewSecondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Auto-cancels previous task and restarts when dbId changes
        .task(id: dbId, priority: .userInitiated) {
            await loadImage(dbId: dbId)
        }
    }

    private func loadImage(dbId: Int) async {
        guard dbId != 0 else { return }
        isLoadingImage = true
        let data = await Task.detached(priority: .userInitiated) {
            ClipboardBackend.shared.getImageFullByDbId(dbId)
        }.value
        // Only apply if we're still showing the same item
        if currentDbId == dbId {
            if let data, let img = NSImage(data: data) { image = img }
            isLoadingImage = false
        }
    }
}
