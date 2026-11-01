import AppKit
import SwiftUI

enum SpotlightTarget: Hashable {
    case searchField
    case selectedRow
    case list

    var cornerRadius: CGFloat {
        switch self {
        case .searchField: return 7
        case .selectedRow, .list: return 10
        }
    }
}

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

@MainActor
final class SpotlightOverlayWindow: NSPanel {
    private static let dimAlpha: CGFloat = 0.38
    private static let cutoutPadding: CGFloat = 4
    private static let revealDuration: TimeInterval = 0.34
    private static let travelDuration: TimeInterval = 0.32
    private static let fadeInDuration: TimeInterval = 0.22

    private let scrimView = NSView()
    private let fillLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()

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
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none

        scrimView.wantsLayer = true

        fillLayer.fillColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
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

    func present(on screen: NSScreen, focus: NSRect, cornerRadius: CGFloat, animated: Bool) {
        let screenFrame = screen.visibleFrame
        if self.frame != screenFrame {
            setFrame(screenFrame, display: false)
        }
        scrimView.frame = NSRect(origin: .zero, size: screenFrame.size)
        fillLayer.frame = scrimView.bounds
        edgeLayer.frame = scrimView.bounds

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

    private func applyGeometry(cutout: NSRect, radius: CGFloat) {
        fillLayer.path = scrimPath(cutout: cutout, radius: radius)
        edgeLayer.path = rimPath(cutout: cutout, radius: radius)
    }

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

    private func rimPath(cutout: NSRect, radius: CGFloat) -> CGPath {
        CGPath(
            roundedRect: cutout,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }
}
