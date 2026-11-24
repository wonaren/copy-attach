import AppKit
import Observation
import SwiftUI

@Observable
final class PreviewHoverState {
    var isHovering = false
}

enum PreviewShellGeometry {
    static let cornerRadius: CGFloat = 20

    static func fullPath(cornerRadius radius: CGFloat, rect: CGRect) -> CGPath {
        if #available(macOS 26.0, *) {
            return ConcentricRectangle(uniformTopCorners: .fixed(radius),
                                       uniformBottomCorners: .fixed(radius)).path(in: rect).cgPath
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
    }

    static func bottomRoundedPath(cornerRadius radius: CGFloat, rect: CGRect) -> CGPath {
        if #available(macOS 26.0, *) {
            return ConcentricRectangle(topLeadingCorner: .fixed(0),
                                       topTrailingCorner: .fixed(0),
                                       bottomLeadingCorner: .fixed(radius),
                                       bottomTrailingCorner: .fixed(radius)).path(in: rect).cgPath
        }
        return UnevenRoundedRectangle(bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius,
                                      style: .continuous).path(in: rect).cgPath
    }
}

struct PreviewBottomRoundedClip: Shape {
    var cornerRadius: CGFloat = PreviewShellGeometry.cornerRadius

    func path(in rect: CGRect) -> Path {
        Path(PreviewShellGeometry.bottomRoundedPath(cornerRadius: cornerRadius, rect: rect))
    }
}

final class SquircleMaskView: NSView {
    private let maskLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        let radius = min(PreviewShellGeometry.cornerRadius, max(0, min(bounds.width, bounds.height) / 2))
        maskLayer.path = PreviewShellGeometry.fullPath(cornerRadius: radius, rect: bounds)
        CATransaction.commit()
    }
}

final class PreviewHostingView: NSHostingView<AnyView> {
    var onHoverChange: ((Bool) -> Void)?
    var usesPointingHand = false
    private var installedArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    var allowsWindowDrag = false
    override var mouseDownCanMoveWindow: Bool { allowsWindowDrag }

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
    static func miniMaxPixel(scale: CGFloat) -> Int {
        Int((miniMaxWidth * scale).rounded(.up))
    }
    private static let miniGap: CGFloat = 10
    private static let miniMinSideSpace: CGFloat = 120

    private(set) var presentation: Presentation
    private var currentItem: ClipboardItem
    private var centerAnchor: NSPoint
    private var hostingView: PreviewHostingView?
    private var miniState: MiniPreviewState?
    private var currentItemId: Int = 0
    private var miniPreview: DecodedImage?
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

    private var previewScreenScale: CGFloat {
        (self.screen ?? NSScreen.main)?.backingScaleFactor ?? 2
    }

    init(item: ClipboardItem,
         centerAt screenCenter: NSPoint,
         onPaste: ((Int) -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onDismiss: (() -> Void)? = nil) {
        let targetScreen = NSScreen.screens.first(where: { NSPointInRect(screenCenter, $0.frame) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = Self.contentSize(for: item, screenFrame: screenFrame)

        self.onPaste = onPaste
        self.onClose = onClose
        self.onDismiss = onDismiss
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
        installContent(item: item, initialPreview: nil)
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
        installContent(item: item, initialPreview: nil)
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

    private func installContent(item: ClipboardItem, initialPreview: DecodedImage?) {
        let hosting: PreviewHostingView
        if presentation == .mini {
            let state = MiniPreviewState(item: item)
            miniState = state
            hosting = PreviewHostingView(rootView: makeMiniContent(state: state))
        } else {
            miniState = nil
            hosting = PreviewHostingView(rootView: makeContent(item: item, initialPreview: initialPreview))
        }
        hosting.sizingOptions = []
        let contentRect = self.contentRect(forFrameRect: self.frame)
        let container = SquircleMaskView(frame: NSRect(origin: .zero, size: contentRect.size))
        hosting.frame = container.bounds

        hosting.autoresizingMask = [.width, .height]
        hosting.allowsWindowDrag = presentation == .large
        hosting.usesPointingHand = presentation == .mini
        hosting.onHoverChange = { [weak self] inside in
            self?.hoverState.isHovering = inside
            self?.onHoverChange?(inside)
        }

        container.addSubview(hosting)
        self.contentView = container
        self.hostingView = hosting
    }

    private func makeMiniContent(state: MiniPreviewState) -> AnyView {
        AnyView(PreviewContent(
            miniState: state,
            maxPixelOverride: Self.miniMaxPixel(scale: previewScreenScale),
            onTapWhenUnzoomed: { [weak self] in self?.onExpand?() },
            onImageLoaded: { [weak self] image in
                guard let self, self.currentItemId == state.item.id else { return }
                self.miniPreview = image
            },
            showsZoomHint: true,
            hoverState: hoverState,
            dismissState: dismissState
        ))
    }

    private func makeContent(item: ClipboardItem,
                             initialPreview: DecodedImage?,
                             expandStartHeight: CGFloat? = nil,
                             expandEndHeight: CGFloat? = nil) -> AnyView {
        let content: PreviewContent
        switch presentation {
        case .mini:
            content = PreviewContent(
                item: item,
                initialPreview: initialPreview,
                maxPixelOverride: Self.miniMaxPixel(scale: previewScreenScale),
                onTapWhenUnzoomed: { [weak self] in self?.onExpand?() },
                onImageLoaded: { [weak self] image in
                    guard let self, self.currentItemId == item.id else { return }
                    self.miniPreview = image
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
                initialPreview: initialPreview,
                maxPixelOverride: nil,
                onTapWhenUnzoomed: dismiss,
                onPaste: onPaste,
                onClose: onClose ?? dismiss,
                dismissState: dismissState,
                expandStartHeight: expandStartHeight,
                expandEndHeight: expandEndHeight
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

    func fadeOutAndClose(duration: TimeInterval = 0.15,
                         scale: CGFloat = 1.04,
                         blur: CGFloat = 16.0) {
        guard isVisible else { close(); return }
        dismissState.duration = duration
        dismissState.scale = scale
        dismissState.blur = blur
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
            miniPreview = nil
            miniState?.item = item
        }
        let currentOrigin = self.frame.origin
        setFrame(NSRect(origin: currentOrigin, size: frame.size), display: true)
        animateFrame(NSRect(origin: frame.origin, size: frame.size), duration: 0.15)
    }

    func expandToLarge(item: ClipboardItem, centerAt point: NSPoint, completion: (@MainActor () -> Void)? = nil) {
        guard presentation == .mini else { return }
        currentItem = item
        currentItemId = item.id
        presentation = .large
        miniState = nil
        centerAnchor = point
        isMovableByWindowBackground = true
        hoverState.isHovering = false
        hostingView?.usesPointingHand = false
        hostingView?.allowsWindowDrag = true
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
        if case .image = item {
            let startHeight = frame.height
            if let hosting = hostingView {
                hosting.rootView = makeContent(item: item,
                                               initialPreview: miniPreview,
                                               expandStartHeight: startHeight,
                                               expandEndHeight: size.height)
            }
            animateFrame(target,
                         duration: 0.24,
                         timing: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
                guard let self, self.isVisible, self.hostingView != nil else { return }
                completion?()
            }
            return
        }
        animateFrame(target,
                     duration: 0.24,
                     timing: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
            guard let self, self.isVisible, let hosting = self.hostingView else { return }
            hosting.rootView = self.makeContent(item: self.currentItem, initialPreview: self.miniPreview)
            completion?()
        }
    }

    func updateContent(item: ClipboardItem) {
        guard presentation == .large else { return }
        guard currentItemId != item.id else { return }
        currentItemId = item.id
        currentItem = item

        hostingView?.rootView = makeContent(item: item, initialPreview: nil)
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
        dismissState.duration = 0.15
        dismissState.scale = 1.04
        dismissState.blur = 16.0

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
        guard abs(newSize.width - oldSize.width) > 0.5 || abs(newSize.height - oldSize.height) > 0.5 else { return }
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

    static func miniSize(for item: ClipboardItem) -> NSSize {
        switch item {
        case .image(_, _, let w, let h, _, _, _, _, _):
            guard w > 0, h > 0 else { return NSSize(width: 220, height: 160) }
            let scale = min(miniMaxWidth / CGFloat(w), miniMaxHeight / CGFloat(h), 2)
            return NSSize(width: CGFloat(w) * scale,
                          height: CGFloat(h) * scale)
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
            with: NSSize(width: width - 18, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let contentHeight = min(ceil(rect.height), 96)
        return NSSize(width: width, height: contentHeight + 18)
    }

    private static func alignedWidth(_ width: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (width * scale).rounded() / scale
    }

    private static func contentSize(for item: ClipboardItem, screenFrame: NSRect) -> NSSize {
        let maxW = screenFrame.width * 0.85
        let maxH = screenFrame.height * 0.85

        switch item {
        case .text(let entryId, _, _, _, _, _, let text, _):
            let prepared = PreviewTextLayout.prepare(text)
            let pad: CGFloat = 26
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

            let verticalOverhead: CGFloat = 51
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
                return NSSize(width: PreviewFooterBar.minimumWidth, height: 160)
            }
            let chrome: CGFloat = 1 + PreviewFooterBar.height
            let maxContentW = maxW
            let maxContentH = max(min(maxH - chrome, 720), 50)
            let scale = min(1, maxContentW / CGFloat(w), maxContentH / CGFloat(h))
            let displayW = Self.alignedWidth(CGFloat(w) * scale)
            let displayH = CGFloat(h) * scale
            return NSSize(width: max(displayW, PreviewFooterBar.minimumWidth),
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
