import AppKit
import SwiftUI

// MARK: - Guide Hosting View

/// Hosting view for the tour window.
///
/// The window is deliberately non-key (taking key status would resign the popup
/// and close it), and AppKit normally drops the first mouse-down of a non-key
/// window. Opting in here is what lets 「开始引导」/「跳过」 respond on the first
/// click while the popup keeps keyboard focus.
final class OnboardingHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Guide Panel

/// The single window the whole tour lives in.
///
/// It has two shapes: a centered welcome card and a corner progress card parked
/// beside the lit control. The panel never becomes key or main — the popup keeps
/// focus (and therefore stays open) while the user works through the tour.
///
/// Both sizes are explicit constants rather than measured from the content. The
/// morph is one frame animation, so the destination has to be known up front;
/// a fixed card height also stops the card from resizing between steps.
@MainActor
final class OnboardingGuidePanel: NSPanel {
    /// Corner progress card: parked beside the lit control.
    static let cardSize = NSSize(width: 320, height: 244)
    /// Welcome card: centered, before the tour starts.
    static let welcomeSize = NSSize(width: 380, height: 272)

    private static let screenMargin: CGFloat = 20
    /// Welcome card → progress card. Long enough to read as one movement.
    private static let morphDuration: TimeInterval = 0.42
    /// Card sliding to stay level with a newly lit control.
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
        // Above the spotlight scrim (+1) so the card is never dimmed.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovableByWindowBackground = false
        animationBehavior = .none
    }

    /// Show the current phase's content and put the window in its place.
    ///
    /// `morph` animates the frame instead of assigning it — used only for the
    /// welcome → progress transition.
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

        // Only a phase change resizes the window; within a phase the card just
        // slides to stay level with the control that is lit.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = morph ? Self.morphDuration : Self.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }
    }

    // MARK: - Placement

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

    /// The progress card tracks the lit control's vertical center so the eye
    /// barely has to leave it. With no target (nothing lit yet) it parks in the
    /// bottom corner, which is also the fallback when the target is on another
    /// display.
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
        // The centered popup is 500×720, so on narrow displays it can reach the
        // right edge. Flip to the other side rather than covering the list.
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
