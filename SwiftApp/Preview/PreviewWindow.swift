import AppKit
import Observation
import SwiftUI

@Observable
final class PreviewHoverState {
    var isHovering = false
}

final class PreviewHostingView: NSHostingView<AnyView> {
    var onHoverChange: ((Bool) -> Void)?
    var usesPointingHand = false
    private var installedArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if usesPointingHand {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if installedArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            installedArea = area
        }
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

class PreviewWindow: NSPanel {
    enum Presentation {
        case mini
        case large
    }

    private static let miniMaxWidth: CGFloat = 300
    private static let miniMaxHeight: CGFloat = 280
    private static let miniPadding: CGFloat = 6
    private static let miniMaxPixel: Int = 800
    private static let miniGap: CGFloat = 10
    private static let miniMinSideSpace: CGFloat = 120

    private(set) var presentation: Presentation
    private var currentItem: ClipboardItem
    private var centerAnchor: NSPoint
    private var hostingView: PreviewHostingView?
    private var currentItemId: Int = 0
    private var miniImage: NSImage?
    private let dismissState = PreviewDismissState()
    private let hoverState = PreviewHoverState()

    var onExpand: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onPaste: ((Int) -> Void)?
    var onClose: (() -> Void)?

    private struct TextHeightCacheKey: Hashable {
        let entryId: Int
        let width: Int
        let maxHeight: Int
    }

    private static var textHeightCache: [TextHeightCacheKey: CGFloat] = [:]
    private static let textHeightCacheMaxEntries = 512

    override var canBecomeKey: Bool { false }

    var itemId: Int { currentItemId }

    init(item: ClipboardItem,
         centerAt screenCenter: NSPoint,
         onPaste: ((Int) -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        let targetScreen = NSScreen.screens.first(where: { NSPointInRect(screenCenter, $0.frame) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = Self.contentSize(for: item, screenFrame: screenFrame)

        self.onPaste = onPaste
        self.onClose = onClose
        self.presentation = .large
        self.currentItem = item
        self.currentItemId = item.id
        self.centerAnchor = screenCenter

        super.init(
            contentRect: NSRect(x: screenCenter.x - size.width / 2,
                                y: screenCenter.y - size.height / 2,
                                width: size.width,
                                height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        installContent(item: item, initialImage: nil)
    }

    init(miniItem item: ClipboardItem, frame: NSRect) {
        self.presentation = .mini
        self.currentItem = item
        self.currentItemId = item.id
        self.centerAnchor = NSPoint(x: frame.midX, y: frame.midY)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        installContent(item: item, initialImage: nil)
    }

    private func configureWindow() {
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.isMovableByWindowBackground = presentation == .large
    }

    private func installContent(item: ClipboardItem, initialImage: NSImage?) {
        let hosting = PreviewHostingView(rootView: makeContent(item: item, initialImage: initialImage))
        hosting.sizingOptions = []
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.cornerCurve = .continuous
        hosting.autoresizingMask = [.width, .height]
        hosting.usesPointingHand = presentation == .mini
        hosting.onHoverChange = { [weak self] inside in
            self?.hoverState.isHovering = inside
            self?.onHoverChange?(inside)
        }

        self.contentView = hosting
        self.hostingView = hosting
    }

    private func makeContent(item: ClipboardItem, initialImage: NSImage?) -> AnyView {
        let content: PreviewContent
        switch presentation {
        case .mini:
            content = PreviewContent(
                item: item,
                initialImage: initialImage,
                maxPixelOverride: Self.miniMaxPixel,
                onTapWhenUnzoomed: { [weak self] in self?.onExpand?() },
                onImageLoaded: { [weak self] image in
                    guard let self, self.currentItemId == item.id else { return }
                    self.miniImage = image
                },
                showsZoomHint: true,
                hoverState: hoverState,
                dismissState: dismissState
            )
        case .large:
            let dismiss: (() -> Void)? = onDismiss == nil
                ? nil
                : { [weak self] in self?.onDismiss?() }
            content = PreviewContent(
                item: item,
                initialImage: initialImage,
                maxPixelOverride: nil,
                onTapWhenUnzoomed: dismiss,
                onPaste: onPaste,
                onClose: onClose ?? dismiss,
                dismissState: dismissState
            )
        }
        return AnyView(content.id(item.id).withAppTheme())
    }

    func fadeIn(duration: TimeInterval = 0.14) {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            guard let self, self.isVisible, self.alphaValue < 0.5 else { return }
            self.alphaValue = 1
        }
    }

    func fadeOutAndClose(duration: TimeInterval = 0.15) {
        guard isVisible else { close(); return }
        withAnimation(.easeOut(duration: duration)) {
            dismissState.isDismissing = true
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { self.close() }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.close()
            }
        }
    }

    func updateMini(item: ClipboardItem, frame: NSRect) {
        guard presentation == .mini else { return }
        if currentItemId != item.id {
            currentItemId = item.id
            currentItem = item
            miniImage = nil
            hostingView?.rootView = makeContent(item: item, initialImage: nil)
        }
        animateFrame(frame, duration: 0.15)
    }

    func expandToLarge(item: ClipboardItem, centerAt point: NSPoint, completion: (@MainActor () -> Void)? = nil) {
        guard presentation == .mini else { return }
        currentItem = item
        currentItemId = item.id
        presentation = .large
        centerAnchor = point
        isMovableByWindowBackground = true
        hoverState.isHovering = false
        hostingView?.usesPointingHand = false
        if let hosting = hostingView {
            invalidateCursorRects(for: hosting)
        }

        let targetScreen = NSScreen.screens.first(where: { NSPointInRect(point, $0.frame) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = Self.contentSize(for: currentItem, screenFrame: screenFrame)
        let target = NSRect(x: point.x - size.width / 2,
                            y: point.y - size.height / 2,
                            width: size.width,
                            height: size.height)
        animateFrame(target,
                     duration: 0.24,
                     timing: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
            guard let self, self.isVisible, let hosting = self.hostingView else { return }
            hosting.rootView = self.makeContent(item: self.currentItem, initialImage: self.miniImage)
            completion?()
        }
    }

    func updateContent(item: ClipboardItem) {
        guard presentation == .large else { return }
        guard currentItemId != item.id else { return }
        currentItemId = item.id
        currentItem = item

        hostingView?.rootView = makeContent(item: item, initialImage: nil)
        resizeToFitContent(for: item)
    }

    private func animateFrame(_ target: NSRect,
                              duration: TimeInterval,
                              timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
                              completion: (@MainActor () -> Void)? = nil) {
        guard target.size != frame.size || target.origin != frame.origin else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            self.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                completion?()
            }
        })
    }

    override func close() {
        dismissState.isDismissing = false

        hostingView?.rootView = AnyView(EmptyView())
        hostingView = nil
        self.contentView = nil

        super.close()
        self.alphaValue = 1.0
    }

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

    static func miniFrame(for item: ClipboardItem, anchorRow: NSRect, popupFrame: NSRect) -> NSRect? {
        let probe = NSPoint(x: popupFrame.midX, y: popupFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }

        let rightSpace = visible.maxX - popupFrame.maxX - miniGap
        let leftSpace = popupFrame.minX - visible.minX - miniGap
        let useLeft = leftSpace >= miniMinSideSpace || rightSpace < miniMinSideSpace
        let available = useLeft ? leftSpace : rightSpace
        guard available >= miniMinSideSpace else { return nil }

        let size = miniSize(for: item)
        let width = min(size.width, available)
        let height = size.height
        let x = useLeft ? popupFrame.minX - miniGap - width : popupFrame.maxX + miniGap
        let y = min(max(anchorRow.midY - height / 2, visible.minY + 8),
                    visible.maxY - height - 8)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func miniSize(for item: ClipboardItem) -> NSSize {
        switch item {
        case .image(_, _, let w, let h, _, _, _, _, _):
            guard w > 0, h > 0 else { return NSSize(width: 220, height: 160) }
            let boxW = miniMaxWidth - miniPadding
            let boxH = miniMaxHeight - miniPadding
            let scale = min(boxW / CGFloat(w), boxH / CGFloat(h), 2)
            return NSSize(width: CGFloat(w) * scale + miniPadding,
                          height: CGFloat(h) * scale + miniPadding)
        case .text(_, _, _, _, _, _, let preview, _):
            return miniTextSize(preview)
        }
    }

    private static func miniTextSize(_ preview: String) -> NSSize {
        let width: CGFloat = 320
        let prepared = PreviewTextClassifier.prepare(preview)
        let font: NSFont = prepared.kind == .prose
            ? .systemFont(ofSize: 12)
            : .monospacedSystemFont(ofSize: 12, weight: .regular)
        let rect = (prepared.displayText as NSString).boundingRect(
            with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let contentHeight = min(ceil(rect.height), 96)
        return NSSize(width: width, height: contentHeight + 24)
    }

    private static func contentSize(for item: ClipboardItem, screenFrame: NSRect) -> NSSize {
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85

        switch item {
        case .text(let entryId, _, _, _, _, _, let text, _):
            let prepared = PreviewTextLayout.prepare(text)
            let pad: CGFloat = 32
            let maxErgonomicWidth: CGFloat = (prepared.kind == .prose) ? 680 : 880
            let effectiveMaxW = min(maxErgonomicWidth, maxW)
            let widthLimit = effectiveMaxW - pad

            var longestLineWidth: CGFloat = 0
            let font = PreviewTextLayout.font(for: prepared.kind)
            prepared.displayText.enumerateLines { line, stop in
                let lineWidth = (line as NSString)
                    .size(withAttributes: [.font: font]).width
                if lineWidth > longestLineWidth { longestLineWidth = lineWidth }
                if longestLineWidth >= widthLimit { stop = true }
            }
            let minW: CGFloat = (prepared.kind == .prose) ? 360 : 400
            let textWidth = min(max(longestLineWidth + pad, minW), effectiveMaxW)
            let containerW = textWidth - pad

            let verticalOverhead: CGFloat = 54
            let maxTextH = max(maxH - verticalOverhead, 50)
            let textH = calculateTextHeight(
                prepared.displayText,
                kind: prepared.kind,
                width: containerW,
                entryId: entryId,
                maxHeight: maxTextH
            )
            let totalH = min(textH + verticalOverhead, maxH)
            return NSSize(width: textWidth, height: max(totalH, 110))

        case .image(_, _, let w, let h, _, _, _, _, _):
            guard w > 0, h > 0 else {
                return NSSize(width: 360, height: 160)
            }
            let padX: CGFloat = 6
            let chrome: CGFloat = 3 + 1 + PreviewFooterBar.height
            let maxContentW = maxW - padX
            let maxContentH = max(min(maxH - chrome, 720), 50)
            let scale = min(1, maxContentW / CGFloat(w), maxContentH / CGFloat(h))
            let displayW = CGFloat(w) * scale
            let displayH = CGFloat(h) * scale
            return NSSize(width: min(max(displayW + padX, 360), maxW),
                          height: max(displayH + chrome, 110))
        }
    }

    private static func calculateTextHeight(
        _ text: String,
        kind: TextContentKind,
        width: CGFloat,
        entryId: Int,
        maxHeight: CGFloat
    ) -> CGFloat {
        let key = TextHeightCacheKey(entryId: entryId,
                                     width: Int(width.rounded()),
                                     maxHeight: Int(maxHeight.rounded()))
        if let cached = textHeightCache[key] { return cached }
        let height = PreviewTextLayout.measureHeight(text, kind: kind, width: width, maxHeight: maxHeight)
        if textHeightCache.count >= textHeightCacheMaxEntries,
           let oldest = textHeightCache.keys.first {
            textHeightCache.removeValue(forKey: oldest)
        }
        textHeightCache[key] = height
        return height
    }
}
