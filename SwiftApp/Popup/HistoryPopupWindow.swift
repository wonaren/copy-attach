import AppKit
import SwiftUI

// MARK: - History Popup Window (NSPanel)

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    /// Non-key preview panel managed by the popup content.
    weak var previewPanel: PreviewWindow?

    /// A native item drag necessarily hands key status to the destination app.
    /// Suppress only that focus transition. Once the drag has ended, the next
    /// deliberate click outside the popup dismisses it normally.
    private var itemDragInProgress = false
    private var awaitingPostDragInteraction = false
    private var dragMouseUpMonitor: Any?
    private var dragLocalMouseUpMonitor: Any?
    private var postDragClickMonitor: Any?

    private init() {
        // Match show() — use visibleFrame so first-open position matches
        // subsequent repositioning. Using frame.size (full screen) would
        // place the popup at a different y (menu bar not accounted for),
        // misaligning it with the preview window which uses visibleFrame.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let popupWidth: CGFloat = 520
        let popupHeight: CGFloat = 744
        let x = screenFrame.origin.x + (screenFrame.size.width - popupWidth) / 2
        let y = screenFrame.origin.y + (screenFrame.size.height - popupHeight) / 2

        super.init(
            contentRect: NSRect(x: x, y: y, width: popupWidth, height: popupHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.title = "CopyAttach"
        // A panel with movable-background enabled wins the initial mouse drag
        // before SwiftUI can start a row drag. PopupHostingView owns a narrow
        // explicit border drag region instead, leaving list rows exclusively
        // responsible for their native drag sessions.
        self.isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { return true }

    func beginItemDrag() {
        itemDragInProgress = true
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
        installDragCompletionMonitors()
    }

    func show() {
        debugLog("HistoryPopupWindow.show() called")

        let contentView = AnyView(HistoryPopupContent(onClose: { [weak self] in
            debugLog("HistoryPopupContent onClose callback")
            self?.close()
        }).withAppTheme())
        let hosting = PopupHostingView(rootView: contentView)
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.cornerCurve = .continuous

        self.contentView = hosting

        // Position at center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = self.frame
            let x = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2
            let y = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height) / 2
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.level = .floating

        // Start invisible: window alpha handles the entire fade (including shadow),
        // while SwiftUI handles the scale pop. Together they match Spotlight's
        // unified window + content appearance.
        self.alphaValue = 0
        self.orderFrontRegardless()
        self.makeKey()

        // Give the hosting view keyboard focus
        DispatchQueue.main.async {
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: self
        )
    }

    @objc private func didBecomeKey(_ notification: Notification) {
        // Returning to the popup consumes the retained post-drag state; a
        // subsequent ordinary focus loss must again close immediately.
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
    }

    @objc private func didResignKey(_ notification: Notification) {
        guard !itemDragInProgress && !awaitingPostDragInteraction else {
            debugLog("Popup resigned key during item drag; awaiting next interaction")
            return
        }
        debugLog("Popup resigned key; animated close")
        closeWithAnimation()
    }

    private func installDragCompletionMonitors() {
        removeDragCompletionMonitors()
        let complete: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.completeItemDrag()
            return event
        }
        // A local monitor handles drops back inside this app; a global monitor
        // handles drops in another application. Mouse events need no
        // accessibility permission for global observation.
        dragLocalMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: complete)
        dragMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.completeItemDrag()
        }
    }

    private func completeItemDrag() {
        guard itemDragInProgress else { return }
        itemDragInProgress = false
        awaitingPostDragInteraction = true
        removeDragCompletionMonitors()
        installPostDragClickMonitor()
    }

    private func installPostDragClickMonitor() {
        removePostDragClickMonitor()
        postDragClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // This monitor observes clicks in other applications only. A click
            // back in this popup is handled by didBecomeKey instead.
            self?.closeWithAnimation()
        }
    }

    private func removeDragCompletionMonitors() {
        if let monitor = dragMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            dragMouseUpMonitor = nil
        }
        if let monitor = dragLocalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            dragLocalMouseUpMonitor = nil
        }
    }

    private func removePostDragClickMonitor() {
        if let monitor = postDragClickMonitor {
            NSEvent.removeMonitor(monitor)
            postDragClickMonitor = nil
        }
    }

    /// Animated close: popup fades → preview fades → both close.
    func closeWithAnimation() {
        let preview = previewPanel
        previewPanel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if let pv = preview {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.1
                    pv.animator().alphaValue = 0
                }, completionHandler: {
                    pv.close()
                    self.close()
                })
            } else {
                self.close()
            }
        })
    }

    override func close() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self)
        itemDragInProgress = false
        awaitingPostDragInteraction = false
        removeDragCompletionMonitors()
        removePostDragClickMonitor()
        previewPanel?.close()
        previewPanel = nil
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0 // reset for next open
    }
}
