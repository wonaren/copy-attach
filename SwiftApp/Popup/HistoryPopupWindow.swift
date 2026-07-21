import AppKit
import SwiftUI

// MARK: - History Popup Window (NSPanel)

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    /// Non-key preview panel managed by the popup content.
    weak var previewPanel: PreviewWindow?

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
        self.isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { return true }

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

        // Auto-close when window loses key status (click outside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    @objc private func didResignKey(_ notification: Notification) {
        debugLog("Popup resigned key, animated close")
        closeWithAnimation()
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
        previewPanel?.close()
        previewPanel = nil
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0 // reset for next open
    }
}
