import AppKit
import SwiftUI

// MARK: - Guide Hosting View

/// Hosting view for the guide panel.
///
/// The panel is deliberately non-key (taking key status would resign the popup
/// and close it), and AppKit normally drops the first mouse-down of a non-key
/// window. Opting in here is what lets the "跳过" button respond on the first
/// click while the popup keeps keyboard focus.
final class OnboardingHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Guide Panel

/// Floating, non-key companion panel parked beside the lit control.
///
/// The history popup is centered, so a side position keeps the instruction
/// readable next to it instead of on top of it. The panel never becomes key or
/// main: the popup keeps focus (and therefore stays open) while the user works
/// through the tour.
@MainActor
final class OnboardingGuidePanel: NSPanel {
    static let contentWidth: CGFloat = 320
    private static let screenMargin: CGFloat = 20

    private var hostingView: OnboardingHostingView?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 240),
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

    /// Rebuild the content view, resize to fit it, and park the card at the
    /// level of the lit control.
    ///
    /// Called on every guide state change: the instruction length varies per
    /// step, and a resized or re-targeted card must be re-parked.
    func update(guide: OnboardingGuide, focus: NSRect?) {
        let content = AnyView(OnboardingGuideView(guide: guide).withAppTheme())
        let hosting: OnboardingHostingView
        if let existing = hostingView {
            existing.rootView = content
            hosting = existing
        } else {
            hosting = OnboardingHostingView(rootView: content)
            contentView = hosting
            hostingView = hosting
        }

        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        if abs(frame.height - height) > 0.5 {
            setContentSize(NSSize(width: Self.contentWidth, height: height))
        }
        reposition(focus: focus)
    }

    /// Keep the card beside the lit control so the eye barely has to leave it:
    /// the card tracks the control's vertical center, clamped into the screen.
    /// With no target (the first two steps) it parks in the bottom corner, which
    /// is also the fallback when the target is on another display.
    private func reposition(focus: NSRect?) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = frame.size
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

        // Ease the slide between targets; the first placement happens before the
        // window is ordered on screen, so it is simply where the card appears.
        let moved = abs(origin.y - frame.origin.y) > 1 || abs(origin.x - frame.origin.x) > 1
        guard isVisible, moved else {
            setFrameOrigin(origin)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrameOrigin(origin)
        }
    }
}
