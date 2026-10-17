import AppKit
import SwiftUI

// MARK: - History Popup Window (NSPanel)

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    /// The panel if it has already been created, without forcing the singleton
    /// into existence. Consumers that only need to *react* to the popup (the
    /// onboarding tour lights it up) must not allocate a window the user may
    /// never open.
    static var existing: HistoryPopupWindow? {
        NSApp.windows.lazy.compactMap { $0 as? HistoryPopupWindow }.first
    }

    /// Non-key preview panel managed by the popup content.
    weak var previewPanel: PreviewWindow?

    /// A native item drag necessarily hands key status to the destination app.
    /// Suppress only that focus transition. Once the drag has ended, the next
    /// deliberate click outside the popup dismisses it normally.
    private var itemDragInProgress = false
    private var awaitingPostDragInteraction = false

    /// True while this popup presents a modal panel of its own (the right-click
    /// 「另存为…」 NSSavePanel). The modal window necessarily takes key status
    /// from this nonactivating panel; that resign-key is a focus transfer, not
    /// a dismissal — the popup is deliberately retained behind the panel and
    /// regains key when the modal loop ends.
    var isPresentingModalPanel = false
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

    /// The hosting view is released on close so the SwiftUI view graph, state
    /// storage, and image references have an unambiguous lifetime per session.
    private var popupHostingView: PopupHostingView?

    // MARK: - Drag anti-occlusion parking (智能防遮挡)
    //
    // While an item drag is in flight the popup parks at the screen edge
    // opposite the mouse position — mouse in right 45% parks popup at left edge,
    // mouse in left 45% parks popup at right edge — so the popup never covers
    // the drop target. The center 10% (45%..55%) serves as a deadband where
    // no window movement is triggered.
    //
    // The state and constants below are shared with the `+DragParking`
    // extension, which owns the mechanics (tick/park/restore).

    /// Edge the popup is parked at during an item drag (nil = centered).
    var parkedSide: ParkSide?
    /// Target x of the in-flight park slide (nil when no slide is pending).
    var pendingParkTargetX: CGFloat?
    /// Frame x at the previous tick — progress check for the slide animation.
    var lastParkTickX: CGFloat?
    var parkSlideStallTicks = 0
    /// Left zone boundary ratio (0% .. 45%) for anti-occlusion parking.
    static let dragParkLeftZoneRatio: CGFloat = 0.45
    /// Right zone boundary ratio (55% .. 100%) for anti-occlusion parking.
    static let dragParkRightZoneRatio: CGFloat = 0.55
    /// Distance from the visible frame edge when the popup is parked.
    static let dragParkMargin: CGFloat = 12
    /// Duration of the park / restore slide.
    static let dragParkDuration: TimeInterval = 0.22

    /// UserDefaults key for the "连续拖拽" preference (default OFF).
    static let continuousDragDefaultsKey = "ContinuousDrag"

    /// Whether the popup stays open after an item drag completes so the user
    /// can drag several items in a row. Defaults to OFF when the user has never
    /// touched the preference — i.e. the popup dismisses right after a drag.
    static var continuousDragEnabled: Bool {
        UserDefaults.standard.object(forKey: continuousDragDefaultsKey) as? Bool ?? false
    }

    /// Explicit window lifecycle states for fully interruptible animation.
    enum LifecycleState: Equatable {
        case closed
        case opening
        case open
        case closing
    }

    private(set) var lifecycleState: LifecycleState = .closed

    var isOpenOrOpening: Bool {
        lifecycleState == .open || lifecycleState == .opening
    }

    /// Duration of the popup open fade-in (window alpha 0 → 1).
    /// Matches Spotlight's ~0.2s open; the content scale spring settles in
    /// the same window (see HistoryPopupContent), so the two stay in sync.
    private static let fadeInDuration: TimeInterval = 0.2

    /// Duration of the popup close fade-out (window alpha 1 → 0).
    private static let fadeOutDuration: TimeInterval = 0.15

    /// Generation token to discard stale async close animation completions
    /// if the window is re-shown before the fade-out finishes.
    private var closeSessionGeneration: UInt64 = 0

    /// Toggle window with interruptible animation support.
    func toggle() {
        // Reconcile the state machine with reality first: AppKit can order the
        // panel out without going through `close()` (display reconfiguration,
        // space change, a system-initiated hide). Trusting the stale `.open`
        // state would make the next hotkey press animate a close on an invisible
        // window, i.e. swallow one press.
        if lifecycleState != .closed && !isVisible {
            debugLog("HistoryPopupWindow.toggle: state \(lifecycleState) but panel hidden — resetting to .closed")
            lifecycleState = .closed
        }
        switch lifecycleState {
        case .closed:
            show()
        case .opening, .open:
            closeWithAnimation()
        case .closing:
            reverseToOpen()
        }
    }

    private init() {
        // Match show() — use visibleFrame so first-open position matches
        // subsequent repositioning. Using frame.size (full screen) would
        // place the popup at a different y (menu bar not accounted for),
        // misaligning it with the preview window which uses visibleFrame.
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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

    /// Re-centers the window on the visible frame of the screen where the mouse cursor resides,
    /// clamped within the visible area so menus and docks never clip the window on compact screens.
    private func centerOnScreen() {
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        if let screen = targetScreen {
            let screenFrame = screen.visibleFrame
            let windowFrame = self.frame
            let rawX = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2
            let rawY = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height) / 2
            let clampedX = max(screenFrame.minX, min(rawX, screenFrame.maxX - windowFrame.size.width))
            let clampedY = max(screenFrame.minY, min(rawY, screenFrame.maxY - windowFrame.size.height))
            self.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        }
    }

    func beginItemDrag() {
        itemDragInProgress = true
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
        startMouseUpWatcher()
        // The tour steps its scrim aside for the duration of the drag: the user
        // needs the whole screen to pick a drop target.
        OnboardingGuide.shared.setItemDragInProgress(true)
    }

    func show() {
        if lifecycleState == .closing {
            reverseToOpen()
            return
        }
        if lifecycleState == .open || lifecycleState == .opening {
            return
        }

        debugLog("HistoryPopupWindow.show() called")
        Perf.instant("swift", "popup.show_begin")
        let perfShow = PerfSpan.start("swift", "popup.show")
        closeSessionGeneration &+= 1
        let session = closeSessionGeneration
        lifecycleState = .opening

        // Record the app the user was interacting with before the popup surfaces.
        ClipboardBackend.shared.recordFrontmostApp()

        // Start the popup-driven history waiter — event-driven off the Rust
        // revision counter, with a 3s lifeline that only bounds a missed
        // publish — and refresh the accessibility-permission state with it.
        ClipboardBackend.shared.setPopupVisible(true)

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
        // A fresh hosting view per session. `close()` releases `popupHostingView`
        // unconditionally, so reusing a previous instance is not an available
        // branch — the view graph, its State storage and its image references
        // all have exactly one session's lifetime by construction.
        let hosting = PopupHostingView(rootView: contentView)
        popupHostingView = hosting
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.closeSessionGeneration == session, self.lifecycleState == .opening else { return }
                self.lifecycleState = .open
            }
        })

        // Watchdog for the fade-in (same pattern as closeWithAnimation's
        // force-close backstop): the animator animation is a CA transaction
        // that is silently dropped if the window's first-frame transaction has
        // not committed when the group runs — the window would then stay on
        // screen at alpha 0 (invisible). Verify the fade landed after its
        // duration and snap the window visible if it did not.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration + 0.1) { [weak self] in
            guard let self, self.closeSessionGeneration == session,
                  self.lifecycleState == .opening,
                  self.closeGuaranteeTimer == nil,
                  self.alphaValue < 0.5 else { return }
            debugLog("show(): fade-in dropped; snapping window visible")
            self.alphaValue = 1
            self.lifecycleState = .open
        }

        // Give the hosting view keyboard focus
        DispatchQueue.main.async {
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

        // The tour keeps this window lit while it is guiding through it.
        OnboardingGuide.shared.refreshSpotlight()

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

        // Synchronous span end: window ordered, key, alpha animation started.
        perfShow?.end()
    }

    /// Interrupt in-flight closing animation and smoothly reverse back to open.
    private func reverseToOpen() {
        debugLog("HistoryPopupWindow.reverseToOpen() called — interrupting close animation")
        closeSessionGeneration &+= 1
        let session = closeSessionGeneration
        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil
        lifecycleState = .opening

        // Keep backend waiter warm and attribution current
        ClipboardBackend.shared.recordFrontmostApp()
        ClipboardBackend.shared.setPopupVisible(true)

        // Cancel the SwiftUI optical dismissal (reverses blur and scale)
        NotificationCenter.default.post(name: popupCancelDismissNotification, object: nil)

        // Put an open preview back the way it was: closeWithAnimation only faded
        // it, so the SwiftUI side still thinks it is open and the panel must be
        // visible again to match.
        if let pv = previewPanel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                pv.animator().alphaValue = 1
            }
        }

        // Re-focus hosting view
        if let hosting = popupHostingView {
            self.makeKey()
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

        // Animate alpha from current position back to 1.0 smoothly
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.closeSessionGeneration == session, self.lifecycleState == .opening else { return }
                self.lifecycleState = .open
            }
        })

        // Watchdog for reverseToOpen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration + 0.1) { [weak self] in
            guard let self, self.closeSessionGeneration == session,
                  self.lifecycleState == .opening,
                  self.closeGuaranteeTimer == nil,
                  self.alphaValue < 0.5 else { return }
            debugLog("reverseToOpen(): fade-in dropped; snapping window visible")
            self.alphaValue = 1.0
            self.lifecycleState = .open
        }
    }

    @objc private func didBecomeKey(_ notification: Notification) {
        // Returning to the popup consumes the retained post-drag state; a
        // subsequent ordinary focus loss must again close immediately.
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
    }

    @objc private func didResignKey(_ notification: Notification) {
        // Our own modal panel is key now: the popup stays behind it (see
        // `isPresentingModalPanel`) instead of being dismissed.
        if isPresentingModalPanel {
            debugLog("Popup resigned key for a modal panel; retaining popup")
            return
        }
        if itemDragInProgress || awaitingPostDragInteraction {
            if Self.continuousDragEnabled {
                debugLog("Popup resigned key during item drag; awaiting next interaction")
            } else {
                // The drag left the popup and focus moved elsewhere (a drop
                // into another app activates it). Dismiss now — the same
                // outcome as pressing Esc.
                itemDragInProgress = false
                awaitingPostDragInteraction = false
                stopMouseUpWatcher()
                reportItemDragFinished()
                removePostDragClickMonitor()
                debugLog("Popup resigned key after drag; closing (same as Esc)")
                close()
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
        reportItemDragFinished()

        if Self.continuousDragEnabled {
            // 连续拖拽开启：保持弹窗开启，可继续拖拽下一个条目；
            // 下一次外部点击正常关闭。
            if parkedSide != nil {
                // The popup parked out of the way during the drag; slide it
                // back to its centered position now that the drag is over.
                debugLog("Drag ended; restoring popup to center")
                restoreFromParking()
            }
            awaitingPostDragInteraction = true
            installPostDragClickMonitor()
        } else {
            // 拖拽结束（已松手）→ 等同于按一次 Esc：直接关闭弹窗。
            awaitingPostDragInteraction = false
            removePostDragClickMonitor()
            resetDragParking()
            debugLog("Drag ended; closing popup (same as Esc)")
            close()
        }
    }

    /// Tell the tour an item drag finished: it is the guided tour's last step,
    /// and the scrim it parked during the drag comes back (or the tour ends).
    private func reportItemDragFinished() {
        OnboardingGuide.shared.setItemDragInProgress(false)
        OnboardingGuide.shared.record(.dragged)
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
        guard lifecycleState != .closing && lifecycleState != .closed else { return }
        lifecycleState = .closing

        // Keep the preview reference: this close can be reversed (see
        // reverseToOpen), and nilling it here left the SwiftUI side believing a
        // preview was open (showPreview stays true) while `previewPanel` was gone.
        // The panel is only really torn down in close(), which is the commit point.
        let preview = previewPanel

        closeSessionGeneration &+= 1
        let session = closeSessionGeneration

        // Drop first responder before fading out so the active text insertion
        // cursor (NSTextInsertionIndicator in macOS 15+) stops its 120Hz
        // CADisplayLink UpdateCycle ticks immediately.
        self.makeFirstResponder(nil)

        // Inform the SwiftUI content to play the Spotlight optical outward dispersion blur exit
        NotificationCenter.default.post(name: popupWillDismissNotification, object: nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.closeSessionGeneration == session, self.lifecycleState == .closing else { return }
                self.close()
            }
        })

        // Fade the preview out in step with the popup, but do not close it: a
        // reversal restores its alpha, and close() disposes of it for real.
        if let pv = preview {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                pv.animator().alphaValue = 0
            }
        }

        // Guarantee: if the fades above never complete (e.g. their
        // transactions were never serviced), close anyway. Stored so a re-show
        // within the deadline cancels it (see show()).
        closeGuaranteeTimer?.invalidate()
        let guarantee = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                guard self.closeSessionGeneration == session, self.lifecycleState == .closing else { return }
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
        let perfClose = PerfSpan.start("swift", "popup.close")
        lifecycleState = .closed
        // Stop the popup-driven history waiter: the list is no longer visible.
        ClipboardBackend.shared.setPopupVisible(false)

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

        // Drop first responder before ordering out so the active text cursor
        // (NSTextInsertionIndicator) stops its 120Hz CADisplayLink UpdateCycle ticks.
        self.makeFirstResponder(nil)

        super.close()
        self.orderOut(nil)

        // Release the hosting view itself. Replacing rootView with EmptyView is
        // not a complete lifecycle boundary for SwiftUI's internal graph, so
        // the window must not retain the session's view graph across opens.
        self.contentView = nil
        popupHostingView = nil

        // Nothing left to light up. Releasing the drag flag first also covers a
        // drag cut short by the popup closing, which would otherwise leave the
        // tour's scrim stuck in its hidden state.
        OnboardingGuide.shared.setItemDragInProgress(false)
        OnboardingGuide.shared.refreshSpotlight()

        // Hand the foreground back if this app took activation (e.g. preview pinch
        // gesture required NSApp.activate), provided no interactive app window
        // (Settings, Stress Test, etc.) is visible or presenting.
        if let appDelegate = AppDelegate.shared,
           !appDelegate.hasVisibleAppWindow,
           !appDelegate.isPresentingAppWindow {
            ClipboardBackend.shared.restorePasteTargetFocus()
        }

        perfClose?.end()
    }
}
