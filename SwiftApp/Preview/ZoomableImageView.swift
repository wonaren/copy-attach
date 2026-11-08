import AppKit
import SwiftUI

final class ZoomableImageNSView: NSView {

    private let imageView = NSImageView()

    private let transformAnimationKey = "com.copyattach.zoom.transform"

    private var scale: CGFloat = 1.0

    private var panOffset: CGPoint = .zero

    private var isInScrollGesture: Bool = false

    private var gestureMonitor: Any?

    private var currentDbId: Int = 0

    var image: NSImage? {
        get { imageView.image }
        set {
            setImage(newValue, dbId: 0)
        }
    }

    func setImage(_ newImage: NSImage?, dbId: Int) {
        let isDifferentItem = (currentDbId != dbId || dbId == 0)
        currentDbId = dbId

        if imageView.image !== newImage {
            imageView.image = newImage
            if isDifferentItem {
                resetZoom()
            } else {
                commitTransform()
            }
        } else if isDifferentItem {
            resetZoom()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.layerContentsRedrawPolicy = .never
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        MainActor.assumeIsolated {
            removeGestureMonitor()
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installGestureMonitor()
        } else {
            removeGestureMonitor()
        }
    }

    private func installGestureMonitor() {
        removeGestureMonitor()
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let localPoint = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(localPoint) else { return event }

            switch event.type {
            case .magnify:
                self.applyMagnify(event)
                return nil
            case .scrollWheel:
                if event.phase != [] || event.momentumPhase != [], self.scale > 1.01 {
                    self.applyTrackpadScroll(event)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeGestureMonitor() {
        if let monitor = gestureMonitor {
            NSEvent.removeMonitor(monitor)
            gestureMonitor = nil
        }
    }

    override func magnify(with event: NSEvent) {
        applyMagnify(event)
    }

    private func applyMagnify(_ event: NSEvent) {
        if event.phase == .began {
            imageView.layer?.removeAllAnimations()
        }

        let oldScale = scale
        let newScale = (oldScale * (1.0 + event.magnification)).clamped(to: 0.5...5.0)

        if oldScale != newScale {
            let r = newScale / oldScale
            let pinchPoint = convert(event.locationInWindow, from: nil)
            let cx = bounds.midX
            let cy = bounds.midY
            panOffset.x = panOffset.x * r + (pinchPoint.x - cx) * (1 - r)
            panOffset.y = panOffset.y * r + (pinchPoint.y - cy) * (1 - r)
        }

        scale = newScale
        clampPanToBounds()
        commitTransform()

        if event.phase == .ended, abs(scale - 1.0) < 0.05 {
            resetZoom()
        }
    }

    private func applyTrackpadScroll(_ event: NSEvent) {
        if event.phase == .began {
            imageView.layer?.removeAllAnimations()
            isInScrollGesture = true
        }

        panOffset.x += event.scrollingDeltaX
        panOffset.y -= event.scrollingDeltaY

        let bounds = computePanBounds()
        panOffset.x = rubberBand(panOffset.x, max: bounds.maxX)
        panOffset.y = rubberBand(panOffset.y, max: bounds.maxY)

        commitTransform()

        let gestureEnded = event.phase == .ended && event.momentumPhase == []
        let momentumEnded = event.phase == [] && event.momentumPhase == .ended
        if gestureEnded || momentumEnded {
            isInScrollGesture = false
            snapPanToBounds()
        }
    }

    var onTapWhenUnzoomed: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return frame.contains(point) ? self : nil
    }

    private var mouseDownAtRest = false
    private var mouseDownLocation: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownAtRest = false
        mouseDownLocation = nil
        if scale > 1.01 {
            if event.clickCount == 2 {
                resetZoom()
            } else {
                super.mouseDown(with: event)
            }
        } else {
            mouseDownAtRest = true
            mouseDownLocation = event.locationInWindow
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownAtRest {
            mouseDownAtRest = false
            let down = mouseDownLocation
            mouseDownLocation = nil
            if let down,
               hypot(event.locationInWindow.x - down.x,
                     event.locationInWindow.y - down.y) > 3 {
                return
            }
            onTapWhenUnzoomed?()
        } else {
            super.mouseUp(with: event)
        }
    }

    private func buildTransform() -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx + panOffset.x, cy + panOffset.y, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    private func commitTransform() {
        CATransaction.setDisableActions(true)
        imageView.layer?.transform = buildTransform()
    }

    private func commitTransformAnimated(duration: CFTimeInterval = 0.35) {
        let currentTransform = imageView.layer?.presentation()?.transform
            ?? imageView.layer?.transform
            ?? CATransform3DIdentity
        let targetTransform = buildTransform()

        guard !CATransform3DEqualToTransform(currentTransform, targetTransform) else { return }

        imageView.layer?.removeAnimation(forKey: transformAnimationKey)

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = currentTransform
        anim.toValue = targetTransform
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.layer?.transform = targetTransform
        CATransaction.commit()
        imageView.layer?.add(anim, forKey: transformAnimationKey)
    }

    private func computePanBounds() -> (maxX: CGFloat, maxY: CGFloat) {
        guard let img = imageView.image, scale > 1.0 else {
            return (0, 0)
        }
        let viewW = bounds.width
        let viewH = bounds.height
        guard viewW > 0, viewH > 0 else { return (0, 0) }

        let imgW = img.size.width
        let imgH = img.size.height
        guard imgW > 0, imgH > 0 else { return (0, 0) }

        let imgAspect = imgW / imgH
        let viewAspect = viewW / viewH

        let displayW: CGFloat
        let displayH: CGFloat
        if imgAspect > viewAspect {
            displayW = viewW
            displayH = viewW / imgAspect
        } else {
            displayH = viewH
            displayW = viewH * imgAspect
        }

        let zoomedW = displayW * scale
        let zoomedH = displayH * scale

        return (
            maxX: max(0, (zoomedW - viewW) / 2),
            maxY: max(0, (zoomedH - viewH) / 2)
        )
    }

    private func rubberBand(_ value: CGFloat, max: CGFloat, resistance: CGFloat = 0.3) -> CGFloat {
        guard max > 0 else { return value }
        let absValue = abs(value)
        if absValue <= max { return value }
        let sign: CGFloat = value > 0 ? 1 : -1
        let overflow = absValue - max
        return sign * (max + overflow * resistance)
    }

    private func clampPanToBounds() {
        guard scale > 1.0, imageView.image != nil else {
            panOffset = .zero
            return
        }
        let bounds = computePanBounds()
        panOffset.x = panOffset.x.clamped(to: -bounds.maxX...bounds.maxX)
        panOffset.y = panOffset.y.clamped(to: -bounds.maxY...bounds.maxY)
    }

    private func snapPanToBounds() {
        let bounds = computePanBounds()
        let clampedX = panOffset.x.clamped(to: -bounds.maxX...bounds.maxX)
        let clampedY = panOffset.y.clamped(to: -bounds.maxY...bounds.maxY)

        guard clampedX != panOffset.x || clampedY != panOffset.y else { return }

        panOffset.x = clampedX
        panOffset.y = clampedY
        commitTransformAnimated(duration: 0.25)
    }

    private func resetZoom() {
        scale = 1.0
        panOffset = .zero
        commitTransformAnimated()
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    var dbId: Int = 0
    var onTapWhenUnzoomed: (() -> Void)?

    func makeNSView(context: Context) -> ZoomableImageNSView {
        let view = ZoomableImageNSView()
        view.setImage(image, dbId: dbId)
        view.onTapWhenUnzoomed = onTapWhenUnzoomed
        return view
    }

    func updateNSView(_ nsView: ZoomableImageNSView, context: Context) {
        nsView.onTapWhenUnzoomed = onTapWhenUnzoomed
        nsView.setImage(image, dbId: dbId)
    }
}
