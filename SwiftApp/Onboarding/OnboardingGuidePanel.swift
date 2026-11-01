import AppKit
import SwiftUI

final class OnboardingHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OnboardingGuidePanel: NSPanel {
    static let cardSize = NSSize(width: 320, height: 244)
    static let welcomeSize = NSSize(width: 380, height: 272)

    private static let screenMargin: CGFloat = 20
    private static let morphDuration: TimeInterval = 0.42
    private static let slideDuration: TimeInterval = 0.28

    private var hostingView: OnboardingHostingView?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.welcomeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    func update(guide: OnboardingGuide, focus: NSRect?, morph: Bool) {
        let content = AnyView(OnboardingStageView(guide: guide).withAppTheme())
        let hosting: OnboardingHostingView
        if let existing = hostingView {
            existing.rootView = content
            hosting = existing
        } else {
            hosting = OnboardingHostingView(rootView: content)
            contentView = hosting
            hostingView = hosting
        }

        let target = targetFrame(for: guide.phase ?? .guiding, focus: focus)
        guard isVisible else {
            setFrame(target, display: false)
            return
        }
        guard target.size != frame.size || target.origin != frame.origin else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = morph ? Self.morphDuration : Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }
    }

    private func targetFrame(for phase: OnboardingPhase, focus: NSRect?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: Self.cardSize)
        }

        switch phase {
        case .welcome:
            let size = Self.welcomeSize
            return NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )

        case .guiding:
            return cardFrame(in: visible, focus: focus)
        }
    }

    private func cardFrame(in visible: NSRect, focus: NSRect?) -> NSRect {
        let size = Self.cardSize
        let margin = Self.screenMargin

        let centerY: CGFloat
        if let focus, visible.intersects(focus) {
            let lowest = visible.minY + size.height / 2 + margin
            let highest = visible.maxY - size.height / 2 - margin
            centerY = min(max(focus.midY, lowest), max(highest, lowest))
        } else {
            centerY = visible.minY + size.height / 2 + margin
        }

        var origin = NSPoint(x: visible.maxX - size.width - margin, y: centerY - size.height / 2)
        if let popup = HistoryPopupWindow.existing,
           popup.isVisible,
           NSRect(origin: origin, size: size).intersects(popup.frame) {
            let flipped = NSPoint(x: visible.minX + margin, y: origin.y)
            if !NSRect(origin: flipped, size: size).intersects(popup.frame) {
                origin = flipped
            }
        }
        return NSRect(origin: origin, size: size)
    }
}
