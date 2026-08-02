import AppKit
import SwiftUI

// MARK: - Zoomable Image NSView

/// Native NSView that handles macOS trackpad pinch-to-zoom via magnification events.
///
/// ## Why a local event monitor instead of `magnify(with:)` only?
///
/// `ZoomableImageNSView` lives inside an `NSHostingView` (SwiftUI's AppKit bridge).
/// `NSHostingView`'s internal hit-testing does not deliver `NSEvent.EventTypeMagnify`
/// to `NSViewRepresentable`-backed subviews — the event is consumed by SwiftUI's
/// gesture layer before reaching the underlying NSView.
///
/// The fix: `NSEvent.addLocalMonitorForEvents(matching: .magnify)` intercepts
/// magnification events at the application level. We then check whether the cursor
/// is over *this* view's bounds. If yes, we handle the zoom and consume the event;
/// otherwise we pass it through. This is the same pattern used by `PopupHostingView`
/// for arrow-key interception.
///
/// ## Design constraints
///
/// - **No memory overhead**: `CATransform3D` is a GPU-composited transform, not a
///   bitmap operation. The original image buffer is unchanged.
/// - **No performance loss**: `CATransaction.setDisableActions(true)` during gesture
///   skips implicit animations for sub-frame latency. The monitor's per-event cost
///   is a single `convert(_:from:)` + `bounds.contains(_:)` — negligible.
/// - **No fallback**: only the native magnification event path is used. If the
///   hardware doesn't support the gesture, the image is simply not zoomable.
final class ZoomableImageNSView: NSView {

    // MARK: - Subviews

    private let imageView = NSImageView()

    /// Key for the explicit `CABasicAnimation` used by snap-back / reset.
    private let transformAnimationKey = "com.copyattach.zoom.transform"

    // MARK: - State

    /// Cumulative scale factor from pinch gestures. Range: [0.5, 5.0].
    private var scale: CGFloat = 1.0

    /// Pan offset in screen points (post-scale space).
    private var panOffset: CGPoint = .zero

    /// Whether a trackpad scroll gesture is in progress (not momentum).
    private var isInScrollGesture: Bool = false

    /// Local event monitor for magnification + scroll-wheel events.
    private var gestureMonitor: Any?

    // MARK: - Image property

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            resetZoom()
        }
    }

    // MARK: - Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Prevent NSImageView from repainting its layer contents when the
        // transform changes — NSImageView's own display cycle conflicts with
        // CATransform3D, causing screen tearing. With this policy, only our
        // explicit transform writes control the visual output.
        imageView.layerContentsRedrawPolicy = .never
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    // MARK: - Gesture event monitor (magnify + trackpad scroll)

    private func installGestureMonitor() {
        removeGestureMonitor()
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            let localPoint = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(localPoint) else { return event }

            switch event.type {
            case .magnify:
                self.applyMagnify(event)
                return nil // consume
            case .scrollWheel:
                // Only handle trackpad scroll (gesture phase present), not
                // physical mouse wheels. Also only when zoomed in — otherwise
                // let the event pass through so the window can be dragged.
                if event.phase != [] || event.momentumPhase != [], self.scale > 1.01 {
                    self.applyTrackpadScroll(event)
                    return nil // consume
                }
                return event // pass through (mouse wheel, or not zoomed)
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

    // MARK: - Pinch-to-zoom

    override func magnify(with event: NSEvent) {
        applyMagnify(event)
    }

    private func applyMagnify(_ event: NSEvent) {
        // Interrupt any in-flight animation so the gesture takes over immediately.
        if event.phase == .began {
            imageView.layer?.removeAllAnimations()
        }

        let oldScale = scale
        let newScale = (oldScale * (1.0 + event.magnification)).clamped(to: 0.5...5.0)

        // Pinch toward cursor: keep the pixel under the user's fingers
        // stationary through the scale change.
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

    // MARK: - Trackpad scroll → pan (only when zoomed in)

    /// Two-finger trackpad swipe translates the zoomed image.
    ///
    /// During an active gesture the pan can overshoot bounds with resistance
    /// (rubber-band), then springs back when the user lifts their fingers —
    /// matching the tactile feel of iOS/macOS scroll views.
    private func applyTrackpadScroll(_ event: NSEvent) {
        // Interrupt any in-flight animation.
        if event.phase == .began {
            imageView.layer?.removeAllAnimations()
            isInScrollGesture = true
        }

        // Accumulate deltas.
        panOffset.x += event.scrollingDeltaX
        panOffset.y -= event.scrollingDeltaY

        // Apply rubber-band resistance beyond bounds during active gesture.
        let bounds = computePanBounds()
        panOffset.x = rubberBand(panOffset.x, max: bounds.maxX)
        panOffset.y = rubberBand(panOffset.y, max: bounds.maxY)

        commitTransform()

        // Gesture ended — snap back to bounds if overshot.
        let gestureEnded = event.phase == .ended && event.momentumPhase == []
        let momentumEnded = event.phase == [] && event.momentumPhase == .ended
        if gestureEnded || momentumEnded {
            isInScrollGesture = false
            snapPanToBounds()
        }
    }

    // MARK: - Double-click → reset zoom

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Transform composition

    /// Build the scale+pan `CATransform3D` for the current state.
    private func buildTransform() -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx + panOffset.x, cy + panOffset.y, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    /// Write the current transform to the layer synchronously, without
    /// animation. No explicit `CATransaction.begin/commit` — the property
    /// change is batched into AppKit's implicit transaction, which coalesces
    /// multiple writes within one event dispatch. Combined with
    /// `layerContentsRedrawPolicy = .never` on the imageView, this eliminates
    /// the double-render path that caused tearing.
    private func commitTransform() {
        CATransaction.setDisableActions(true)
        imageView.layer?.transform = buildTransform()
    }

    /// Apply the transform with animation — for discrete actions such as
    /// double-click reset and rubber-band snap-back.
    ///
    /// Reads the *presentation* layer's current transform as the animation
    /// start point, so the transition always begins from what's actually on
    /// screen — no visual jump. Uses explicit `CABasicAnimation` rather than
    /// `NSAnimationContext` + `animator()` because the animator proxy's
    /// NSView→CALayer indirection can read a stale model value, causing the
    /// tearing/oscillation reported during snap-back.
    private func commitTransformAnimated(duration: CFTimeInterval = 0.35) {
        let currentTransform = imageView.layer?.presentation()?.transform
            ?? imageView.layer?.transform
            ?? CATransform3DIdentity
        let targetTransform = buildTransform()

        guard !CATransform3DEqualToTransform(currentTransform, targetTransform) else { return }

        // Kill any in-progress animated transition so overlapping calls
        // (e.g. snap-back followed quickly by double-click reset) don't fight.
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

    // MARK: - Pan bounds & rubber-band

    /// Returns the (±maxX, ±maxY) range within which `panOffset` keeps the
    /// zoomed image fully visible. Zero if the image fits within the view.
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

    /// Rubber-band resistance: values within `[-max, max]` pass through
    /// unchanged. Beyond that, overflow is dampened by `resistance` (default
    /// 0.3 → 30% of the excess displacement is kept, 70% absorbed).
    private func rubberBand(_ value: CGFloat, max: CGFloat, resistance: CGFloat = 0.3) -> CGFloat {
        guard max > 0 else { return value }
        let absValue = abs(value)
        if absValue <= max { return value }
        let sign: CGFloat = value > 0 ? 1 : -1
        let overflow = absValue - max
        return sign * (max + overflow * resistance)
    }

    /// Hard-clamp for use during pinch (no overshoot desired) and initial setup.
    private func clampPanToBounds() {
        guard scale > 1.0, imageView.image != nil else {
            panOffset = .zero
            return
        }
        let bounds = computePanBounds()
        panOffset.x = panOffset.x.clamped(to: -bounds.maxX...bounds.maxX)
        panOffset.y = panOffset.y.clamped(to: -bounds.maxY...bounds.maxY)
    }

    /// Animate `panOffset` back within bounds after a rubber-band overshoot.
    private func snapPanToBounds() {
        let bounds = computePanBounds()
        let clampedX = panOffset.x.clamped(to: -bounds.maxX...bounds.maxX)
        let clampedY = panOffset.y.clamped(to: -bounds.maxY...bounds.maxY)

        guard clampedX != panOffset.x || clampedY != panOffset.y else { return }

        panOffset.x = clampedX
        panOffset.y = clampedY
        commitTransformAnimated(duration: 0.25)
    }

    // MARK: - Reset

    private func resetZoom() {
        scale = 1.0
        panOffset = .zero
        commitTransformAnimated()
    }
}

// MARK: - CGFloat Clamping

extension CGFloat {
    /// Clamp the value to a closed range.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - SwiftUI Bridge

/// `NSViewRepresentable` wrapper that embeds `ZoomableImageNSView` in a SwiftUI hierarchy.
///
/// The view resets zoom automatically when `image` changes identity (different `NSImage` object),
/// which happens naturally when navigating between items in the preview window.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?

    func makeNSView(context: Context) -> ZoomableImageNSView {
        let view = ZoomableImageNSView()
        view.image = image
        return view
    }

    func updateNSView(_ nsView: ZoomableImageNSView, context: Context) {
        // Identity check: only reset if the image object actually changed.
        // `image` becoming nil (during async load) is also a change.
        if nsView.image !== image {
            nsView.image = image
        }
    }
}
