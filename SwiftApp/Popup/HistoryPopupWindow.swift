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
    /// Polls `NSEvent.pressedMouseButtons` to detect the end of a drag
    /// (mouse up). Event monitors never see the mouse-up of a drag session:
    /// while dragging, the run loop runs in NSEventTrackingRunLoopMode, which
    /// restricts which sources deliver events. A timer registered for both
    /// common and event-tracking modes observes the button release reliably.
    /// The same ticks also sample the mouse position for anti-occlusion
    /// parking (see `tickDragParking`).
    private var mouseUpWatcher: Timer?
    private var postDragClickMonitor: Any?
    /// closeWithAnimation's 0.4s force-close backstop. Stored so show()/close()
    /// can cancel a pending guarantee when the window is re-shown before it fires.
    private var closeGuaranteeTimer: Timer?

    // MARK: - Drag anti-occlusion parking (智能防遮挡)
    //
    // While an item drag is in flight the popup parks at the screen edge
    // opposite the drag direction — dragging right parks it at the left edge,
    // dragging left at the right edge — so the popup never covers the drop
    // target. Direction is re-evaluated continuously on every watcher tick:
    // reversing the drag by more than `dragOcclusionThreshold` flips the popup
    // to the other edge, so one long drag that changes course keeps the popup
    // out of the way the whole time (持续拖动).
    //
    // The state and constants below are shared with the `+DragParking`
    // extension, which owns the mechanics (tick/park/flip/restore).

    /// Edge the popup is parked at during an item drag (nil = centered).
    var parkedSide: ParkSide?
    /// Net horizontal mouse travel since the last park decision (points).
    var dragDxAccum: CGFloat = 0
    /// Mouse x at the previous parking tick.
    var lastDragMouseX: CGFloat?
    /// Target x of the in-flight park slide (nil when no slide is pending).
    var pendingParkTargetX: CGFloat?
    /// Frame x at the previous tick — progress check for the slide animation.
    var lastParkTickX: CGFloat?
    var parkSlideStallTicks = 0
    /// Horizontal mouse travel that parks the popup at an edge, or flips it
    /// to the opposite edge after a course reversal. Large enough that the
    /// small jitter of picking up a drag never triggers anything; small
    /// enough that the popup is out of the way well before the drop.
    static let dragOcclusionThreshold: CGFloat = 40
    /// Distance from the visible frame edge when the popup is parked.
    static let dragParkMargin: CGFloat = 12
    /// Duration of the park / restore slide.
    static let dragParkDuration: TimeInterval = 0.22

    /// UserDefaults key for the "拖拽后自动关闭弹窗" preference (default ON).
    static let closePopupAfterDragDefaultsKey = "ClosePopupAfterDrag"

    /// Whether the popup should dismiss right after an item drag completes.
    /// Defaults to ON when the user has never touched the preference.
    static var closePopupAfterDragEnabled: Bool {
        UserDefaults.standard.object(forKey: closePopupAfterDragDefaultsKey) as? Bool ?? true
    }

    /// Duration of the popup open fade-in (window alpha 0 → 1).
    /// Matches Spotlight's ~0.2s open; the content scale spring settles in
    /// the same window (see HistoryPopupContent), so the two stay in sync.
    private static let fadeInDuration: TimeInterval = 0.2

    private init() {
        // Match show() — use visibleFrame so first-open position matches
        // subsequent repositioning. Using frame.size (full screen) would
        // place the popup at a different y (menu bar not accounted for),
        // misaligning it with the preview window which uses visibleFrame.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        // Match HistoryPopupContent.popupWidth/popupHeight (500×720). The window
        // must equal the content size so the hosting view's content-driven resize
        // is a no-op and the popup never shifts off-center after placement.
        let popupWidth: CGFloat = 500
        let popupHeight: CGFloat = 720
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

    /// Re-centers the window on the visible frame of the main screen.
    private func centerOnScreen() {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = self.frame
            let x = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2
            let y = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height) / 2
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    func beginItemDrag() {
        itemDragInProgress = true
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
        startMouseUpWatcher()
        // Anti-occlusion: measure the drag run from the moment the item is
        // picked up.
        dragDxAccum = 0
        lastDragMouseX = NSEvent.mouseLocation.x
    }

    func show() {
        debugLog("HistoryPopupWindow.show() called")

        // Cancel a pending close-guarantee from a prior closeWithAnimation: if
        // the user re-opens before its 0.4s deadline, the stale timer must not
        // force-close the freshly re-shown window.
        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil

        // Start invisible before the window is ordered on screen, so the fade-in
        // below always animates from 0 no matter when the content view installs
        // or renders.
        self.alphaValue = 0

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

        // Position at center of screen. The window frame already equals the
        // content size, so no content-driven resize can shift it off-center.
        // Anti-occlusion state must not survive a close/reopen cycle: show()
        // re-centers the window, so a stale parkedSide would leave the popup
        // centered while the parking logic believes it is parked.
        resetDragParking()
        centerOnScreen()

        self.level = .floating

        self.orderFrontRegardless()
        self.makeKey()

        // Fade in immediately. orderFrontRegardless() completes the order-front
        // synchronously, so the window is already on screen here and the alpha
        // animation plays on its first frame — no need to defer past a runloop
        // turn. (095b404's concern was onAppear firing before the window was
        // ordered on screen, dropping the fade; animating from `self` after
        // orderFront is always safe, and a close cannot interleave mid-call.)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        // Watchdog for the fade-in (same pattern as closeWithAnimation's
        // force-close backstop): the animator animation is a CA transaction
        // that is silently dropped if the window's first-frame transaction has
        // not committed when the group runs — the window would then stay on
        // screen at alpha 0 (invisible). Verify the fade landed after its
        // duration and snap the window visible if it did not.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration + 0.1) { [weak self] in
            guard let self, self.isVisible, self.closeGuaranteeTimer == nil,
                  self.alphaValue < 0.5 else { return }
            debugLog("show(): fade-in dropped; snapping window visible")
            self.alphaValue = 1
        }

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
        if itemDragInProgress || awaitingPostDragInteraction {
            if Self.closePopupAfterDragEnabled {
                // The drag left the popup and focus moved elsewhere (a drop
                // into another app activates it). Dismiss now — the same
                // outcome as pressing Esc.
                itemDragInProgress = false
                awaitingPostDragInteraction = false
                stopMouseUpWatcher()
                removePostDragClickMonitor()
                debugLog("Popup resigned key after drag; closing (same as Esc)")
                close()
            } else {
                debugLog("Popup resigned key during item drag; awaiting next interaction")
            }
            return
        }
        debugLog("Popup resigned key; animated close")
        closeWithAnimation()
    }

    /// Drag end detection: while the left button stays pressed the drag is in
    /// progress; the tick that observes the release ends it. The 40 ms cadence
    /// keeps the dismissal feeling immediate. The same cadence drives the
    /// anti-occlusion parking: each tick the park slide progress is checked
    /// first, then the mouse travel is accumulated and may park/flip the popup.
    private func startMouseUpWatcher() {
        stopMouseUpWatcher()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Left button still down → drag still in progress; keep sampling
            // the mouse for anti-occlusion parking.
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                MainActor.assumeIsolated {
                    self.tickParkingSlide()
                    self.tickDragParking()
                }
                return
            }
            MainActor.assumeIsolated { self.completeItemDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        mouseUpWatcher = timer
    }

    private func stopMouseUpWatcher() {
        mouseUpWatcher?.invalidate()
        mouseUpWatcher = nil
    }

    private func completeItemDrag() {
        guard itemDragInProgress else { return }
        itemDragInProgress = false
        stopMouseUpWatcher()

        if Self.closePopupAfterDragEnabled {
            // 拖拽结束（已松手）→ 等同于按一次 Esc：直接关闭弹窗。
            awaitingPostDragInteraction = false
            removePostDragClickMonitor()
            resetDragParking()
            debugLog("Drag ended; closing popup (same as Esc)")
            close()
        } else {
            // 开关关闭：保持弹窗开启，可连续拖拽多个条目；
            // 下一次外部点击正常关闭。
            if parkedSide != nil {
                // The popup parked out of the way during the drag; slide it
                // back to its centered position now that the drag is over.
                debugLog("Drag ended; restoring popup to center")
                restoreFromParking()
            }
            awaitingPostDragInteraction = true
            installPostDragClickMonitor()
        }
    }

    private func installPostDragClickMonitor() {
        removePostDragClickMonitor()
        postDragClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // This monitor observes clicks in other applications only. A click
            // back in this popup is handled by didBecomeKey instead.
            self?.closeWithAnimation()
        }
    }

    private func removePostDragClickMonitor() {
        if let monitor = postDragClickMonitor {
            NSEvent.removeMonitor(monitor)
            postDragClickMonitor = nil
        }
    }

    /// Animated close: popup and preview fade independently, then close.
    /// Closing must NOT depend on an animation completion chain. CA animation
    /// completions are not reliably delivered while the run loop is in event
    /// tracking (mouse-dragging / menu tracking — see NSEventTrackingRunLoopMode),
    /// and a stalled preview fade used to block the popup close entirely,
    /// leaving the window visible without focus. A timer registered for both
    /// tracking and common run loop modes guarantees the close.
    func closeWithAnimation() {
        let preview = previewPanel
        previewPanel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        })

        if let pv = preview {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                pv.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { pv.close() }
            })
        }

        // Guarantee: if the fades above never complete (e.g. their
        // transactions were never serviced), close anyway. Stored so a re-show
        // within the deadline cancels it (see show()).
        closeGuaranteeTimer?.invalidate()
        let guarantee = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.closeGuaranteeTimer = nil
                if self.isVisible {
                    debugLog("closeWithAnimation: forcing close (animation stalled)")
                    self.close()
                }
                if let pv = preview, pv.isVisible {
                    pv.close()
                }
            }
        }
        closeGuaranteeTimer = guarantee
        RunLoop.main.add(guarantee, forMode: .common)
        RunLoop.main.add(guarantee, forMode: .eventTracking)
    }

    override func close() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self)
        itemDragInProgress = false
        awaitingPostDragInteraction = false
        stopMouseUpWatcher()
        removePostDragClickMonitor()
        resetDragParking()
        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil
        previewPanel?.close()
        previewPanel = nil
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0 // reset for next open
    }
}
