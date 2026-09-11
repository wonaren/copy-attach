import AppKit
import SwiftUI

// MARK: - Spotlight Target

/// A control inside the popup that the tour lights up.
enum SpotlightTarget: Hashable {
    case searchField
    /// The row the cursor is on. Falls back to `list` when nothing is selected.
    case selectedRow
    case list

    /// Corner radius matching the control's own shape, so the cutout follows it.
    var cornerRadius: CGFloat {
        switch self {
        case .searchField: return 7
        // Matches the row's own selection highlight (`ItemRowView`).
        case .selectedRow, .list: return 10
        }
    }
}

// MARK: - Spotlight Frame Reporting

/// Spotlight geometry reported by the popup, in the hosting view's SwiftUI
/// coordinate space (`.global`: origin top-left, y down).
///
/// `hasSelectedRow` carries the one piece of state the frames cannot express:
/// a row scrolled out of the lazy stack stops reporting, which looks identical
/// to "nothing is selected". The guide needs to tell those apart to know
/// whether to hold the cutout on the last known row or fall back to the list.
struct SpotlightGeometry: Equatable {
    var frames: [SpotlightTarget: CGRect] = [:]
    var hasSelectedRow: Bool = false
}

struct SpotlightFramePreferenceKey: PreferenceKey {
    static let defaultValue = SpotlightGeometry()
    static func reduce(value: inout SpotlightGeometry, nextValue: () -> SpotlightGeometry) {
        let next = nextValue()
        value.frames.merge(next.frames) { $1 }
        value.hasSelectedRow = value.hasSelectedRow || next.hasSelectedRow
    }
}

extension View {
    /// Report this view's frame as a spotlight target while the tour is active.
    ///
    /// The geometry reader is attached only during the tour: measuring every
    /// layout pass for a feature that runs once is exactly the kind of cost the
    /// popup avoids elsewhere (see `RowFramePreferenceKey`).
    @ViewBuilder
    func reportSpotlightFrame(_ target: SpotlightTarget, hasSelectedRow: Bool = false) -> some View {
        if OnboardingGuide.shared.isActive {
            background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SpotlightFramePreferenceKey.self,
                        value: SpotlightGeometry(
                            frames: [target: geo.frame(in: .global)],
                            hasSelectedRow: hasSelectedRow
                        )
                    )
                }
            }
        } else {
            self
        }
    }
}

// MARK: - Spotlight Overlay

/// Full-screen dimming scrim for the guided tour.
///
/// One translucent layer covers the display with a single rounded cutout over
/// the control the current step is about — the search field, the list, or the
/// preview panel. `ignoresMouseEvents` keeps the layer purely visual: every
/// click still reaches the real control underneath, which is what lets the user
/// perform the very operation being highlighted.
///
/// The cutout is the thing that steers the eye, so it is animated rather than
/// snapped: it grows out of its own center when the spotlight first turns on,
/// glides between targets as the tour advances, and re-lights its rim on
/// arrival. Both layers animate the same geometry, so the rim stays welded to
/// the cutout.
///
/// The window sits one level above the popup (and therefore above the preview,
/// which shares the popup's level) and two below the guide card.
@MainActor
final class SpotlightOverlayWindow: NSPanel {
    /// Scrim opacity. Deliberately below half: the popup's list stays readable
    /// outside the cutout, which the user still needs while typing a query.
    private static let dimAlpha: CGFloat = 0.38
    /// Breathing room between the cutout and the control's own bounds.
    private static let cutoutPadding: CGFloat = 4
    /// Cutout reveal (spotlight turning on) and travel durations.
    private static let revealDuration: TimeInterval = 0.34
    private static let travelDuration: TimeInterval = 0.32
    /// Scrim fade-in when the spotlight first turns on.
    private static let fadeInDuration: TimeInterval = 0.22

    private let scrimView = NSView()
    /// Dims everything outside the cutout (even-odd: screen rect minus cutout).
    private let fillLayer = CAShapeLayer()
    /// Accent rim tracing the cutout.
    private let edgeLayer = CAShapeLayer()

    /// Cutout in the scrim view's coordinates, for change detection.
    private var currentCutout: NSRect?
    private var currentRadius: CGFloat = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // Above the popup/preview (.floating), below the guide card (+2).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none

        scrimView.wantsLayer = true

        fillLayer.fillColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
        // Even-odd: the screen rect is the scrim, the cutout subtracts from it.
        fillLayer.fillRule = .evenOdd
        scrimView.layer?.addSublayer(fillLayer)

        edgeLayer.fillColor = nil
        edgeLayer.strokeColor = NSColor.controlAccentColor.cgColor
        edgeLayer.lineWidth = 2
        edgeLayer.lineJoin = .round
        edgeLayer.shadowColor = NSColor.controlAccentColor.cgColor
        edgeLayer.shadowRadius = 7
        edgeLayer.shadowOpacity = 0.7
        edgeLayer.shadowOffset = .zero
        scrimView.layer?.addSublayer(edgeLayer)

        contentView = scrimView
    }

    /// Cover `screen`, lighting `focus` (screen coordinates).
    ///
    /// `animated` asks for the travel transition between two cutouts; the caller
    /// passes false whenever the same target merely moved (dragging the popup,
    /// following the selected row), where easing would make the cutout trail
    /// what it is framing. The first presentation always reveals regardless.
    func present(on screen: NSScreen, focus: NSRect, cornerRadius: CGFloat, animated: Bool) {
        let screenFrame = screen.visibleFrame
        if self.frame != screenFrame {
            setFrame(screenFrame, display: false)
        }
        scrimView.frame = NSRect(origin: .zero, size: screenFrame.size)
        fillLayer.frame = scrimView.bounds
        edgeLayer.frame = scrimView.bounds

        // The scrim view is unflipped, so its origin is the window's
        // bottom-left corner — exactly the screen frame's origin.
        let cutout = NSRect(
            x: focus.minX - screenFrame.minX,
            y: focus.minY - screenFrame.minY,
            width: focus.width,
            height: focus.height
        ).insetBy(dx: -Self.cutoutPadding, dy: -Self.cutoutPadding)
        let radius = cornerRadius + Self.cutoutPadding

        let isFirstPresentation = !isVisible
        let previous = currentCutout
        let previousRadius = currentRadius
        currentCutout = cutout
        currentRadius = radius

        if previous == nil || isFirstPresentation {
            // Spotlight turning on: grow the cutout out of its own center so the
            // eye is pulled to the control instead of onto a static hole. Any
            // animation left over from a previous session is dropped first —
            // `presentation()` below would otherwise start from that stale state.
            fillLayer.removeAllAnimations()
            edgeLayer.removeAllAnimations()
            let seed = NSRect(x: cutout.midX - 1, y: cutout.midY - 1, width: 2, height: 2)
            applyGeometry(cutout: seed, radius: radius)
            animate(from: (seed, radius), to: cutout, radius: radius, duration: Self.revealDuration)
            fadeScrimIn()
        } else if previous != cutout || previousRadius != radius {
            animate(from: nil, to: cutout, radius: radius,
                    duration: animated ? Self.travelDuration : 0)
        }

        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
        currentCutout = nil
        scrimView.layer?.removeAnimation(forKey: "fadeIn")
        scrimView.layer?.opacity = 1
    }

    /// Fade the scrim in on first show: the layer appears instantly otherwise,
    /// which reads as a flash.
    ///
    /// The model opacity is 1 the whole time and only the animation starts at 0,
    /// so a transaction dropped before the window's first frame commits leaves
    /// the scrim visible rather than stuck invisible — the failure mode
    /// `HistoryPopupWindow` guards against with a watchdog.
    private func fadeScrimIn() {
        guard let layer = scrimView.layer else { return }
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeInDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
    }

    // MARK: - Geometry

    private func applyGeometry(cutout: NSRect, radius: CGFloat) {
        fillLayer.path = scrimPath(cutout: cutout, radius: radius)
        edgeLayer.path = rimPath(cutout: cutout, radius: radius)
    }

    /// Animate both layers to `cutout`.
    ///
    /// `from` overrides the starting geometry. When it is nil the animation
    /// starts from what is *currently on screen* (`presentation()`), not from
    /// `layer.path` — that property already holds the previous animation's
    /// target, so using it would snap the cutout forward whenever a new change
    /// arrives before the previous transition finished.
    private func animate(
        from start: (cutout: NSRect, radius: CGFloat)?,
        to cutout: NSRect,
        radius: CGFloat,
        duration: TimeInterval
    ) {
        let target = (fill: scrimPath(cutout: cutout, radius: radius),
                      rim: rimPath(cutout: cutout, radius: radius))

        guard duration > 0 else {
            fillLayer.removeAllAnimations()
            edgeLayer.removeAllAnimations()
            fillLayer.path = target.fill
            edgeLayer.path = target.rim
            return
        }

        let explicit = start.map {
            (fill: scrimPath(cutout: $0.cutout, radius: $0.radius),
             rim: rimPath(cutout: $0.cutout, radius: $0.radius))
        }
        let steps: [(layer: CAShapeLayer, from: CGPath?, to: CGPath)] = [
            (fillLayer, explicit?.fill ?? fillLayer.presentation()?.path ?? fillLayer.path, target.fill),
            (edgeLayer, explicit?.rim ?? edgeLayer.presentation()?.path ?? edgeLayer.path, target.rim),
        ]

        for step in steps {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = step.from
            animation.toValue = step.to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            step.layer.path = step.to
            step.layer.add(animation, forKey: "path")
        }

        // Arrival cue: the rim lights up as the cutout settles.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.3
        pulse.toValue = 1.0
        pulse.duration = 0.55
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        edgeLayer.add(pulse, forKey: "pulse")
    }

    private func scrimPath(cutout: NSRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(scrimView.bounds)
        path.addPath(rimPath(cutout: cutout, radius: radius))
        return path
    }

    /// Single rounded rect: keeping the cutout to one subpath is what makes the
    /// `path` interpolation between two states smooth.
    private func rimPath(cutout: NSRect, radius: CGFloat) -> CGPath {
        CGPath(
            roundedRect: cutout,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }
}
