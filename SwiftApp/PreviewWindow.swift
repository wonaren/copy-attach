import AppKit
import SwiftUI

// MARK: - Shared state model (drives PreviewContent without replacing rootView)

class PreviewContentModel: ObservableObject {
    @Published var item: ClipboardItem
    init(item: ClipboardItem) { self.item = item }
}

// MARK: - Preview Window (non-key, auto-sized, content driven by ObservableObject)

class PreviewWindow: NSPanel {
    private let model: PreviewContentModel
    private var hostingView: NSHostingView<PreviewContent>!

    /// Cache text heights per entryId so arrow-key navigation doesn't re-layout.
    private static var textHeightCache: [Int: CGFloat] = [:]

    override var canBecomeKey: Bool { false }

    init(item: ClipboardItem) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = Self.contentSize(for: item, screenFrame: screenFrame)
        let x = screenFrame.origin.x + (screenFrame.size.width - size.width) / 2
        let y = screenFrame.origin.y + (screenFrame.size.height - size.height) / 2

        self.model = PreviewContentModel(item: item)

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

        let content = PreviewContent(model: model)
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
        guard model.item.id != item.id else { return } // same item, skip
        model.item = item
        // Force NSHostingView to re-render immediately by replacing rootView.
        // @ObservedObject can be unreliable in NSHostingView on macOS SwiftUI,
        // so we bypass it with a direct rootView swap.
        hostingView.rootView = PreviewContent(model: model)
        resizeToFitContent()
    }

    override func close() {
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0
    }

    // MARK: - Window resizing

    private func resizeToFitContent() {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        guard screenFrame.width > 0 else { return }
        let newSize = Self.contentSize(for: model.item, screenFrame: screenFrame)
        var frame = self.frame
        let oldSize = frame.size
        guard abs(newSize.width - oldSize.width) > 2 || abs(newSize.height - oldSize.height) > 2 else { return }
        frame.size = newSize
        frame.origin.x += (oldSize.width - newSize.width) / 2
        frame.origin.y += (oldSize.height - newSize.height) / 2
        self.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Auto-sizing

    private static func contentSize(for item: ClipboardItem, screenFrame: NSRect) -> NSSize {
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85

        switch item {
        case .text(let entryId, let text, _, _, _, _):
            let textWidth: CGFloat = min(900, maxW)
            let pad: CGFloat = 24
            let containerW = textWidth - pad
            let textH = calculateTextHeight(text, width: containerW, entryId: entryId)
            let totalH = min(textH + pad, maxH)
            return NSSize(width: textWidth, height: max(totalH, 100))

        case .image(_, _, _, let w, let h, _, _, _, _):
            // Cap display height at 500; don't upscale images shorter than that.
            let capH: CGFloat = 500
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

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
    @ObservedObject var model: PreviewContentModel

    @State private var image: NSImage?
    @State private var isLoadingImage = false

    private var currentDbId: Int {
        guard case .image(_, let dbId, _, _, _, _, _, _, _) = model.item else { return 0 }
        return dbId
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            switch model.item {
            case .text(_, let text, _, _, _, _):
                LargeTextView(text: text)
            case .image(_, let dbId, _, _, _, _, _, _, _):
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
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.3))
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
