import AppKit
import SwiftUI

final class PasteQueueHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PasteQueueHUDWindow: NSPanel {
    static let shared = PasteQueueHUDWindow()

    static let pillSize = NSSize(width: 330, height: 42)
    static let windowPadding: CGFloat = 16
    static var windowSize: NSSize {
        NSSize(width: pillSize.width + windowPadding * 2, height: pillSize.height + windowPadding * 2)
    }

    private var hostingView: PasteQueueHostingView?

    private var visibilityGeneration: UInt64 = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    func show() {
        visibilityGeneration &+= 1

        let content = AnyView(PasteQueueHUDView().withAppTheme())
        if hostingView == nil {
            let host = PasteQueueHostingView(rootView: content)
            self.contentView = host
            self.hostingView = host
        } else {
            hostingView?.rootView = content
        }

        if !isVisible {
            positionAtTopCenter()
            alphaValue = 0
            orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func dismiss() {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
                self.contentView = nil
                self.hostingView = nil
            }
        })
    }

    private func positionAtTopCenter() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (Self.windowSize.width / 2)
        let y = visibleFrame.maxY - Self.windowSize.height - 12
        setFrame(NSRect(x: x, y: y, width: Self.windowSize.width, height: Self.windowSize.height), display: true)
    }
}
