import AppKit
import SwiftUI

@MainActor
final class QuickSlotDialWindow {
    static let shared = QuickSlotDialWindow()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var currentBoundSlots: Set<Int> = []

    private static let dialSize = NSSize(width: 100, height: 100)
    private static let gap: CGFloat = 8

    private init() {}

    func show(boundSlots: Set<Int>, popupFrame: NSRect, anchorY: CGFloat) {
        let panel = ensurePanel()
        if boundSlots != currentBoundSlots {
            currentBoundSlots = boundSlots
            hosting?.rootView = AnyView(QuickSlotDialView(boundSlots: boundSlots).withAppTheme())
        }
        let visible = (NSScreen.screens.first(where: { $0.frame.intersects(popupFrame) }) ?? NSScreen.main)?
            .visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = popupFrame.maxX + Self.gap
        var y = anchorY - Self.dialSize.height / 2
        x = min(x, visible.maxX - Self.dialSize.width - 4)
        y = max(visible.minY + 4, min(y, visible.maxY - Self.dialSize.height - 4))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: Self.dialSize), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.dialSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: AnyView(QuickSlotDialView(boundSlots: []).withAppTheme()))
        hosting.frame = NSRect(origin: .zero, size: Self.dialSize)
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}
