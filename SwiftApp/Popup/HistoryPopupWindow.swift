import AppKit
import SwiftUI

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    static var existing: HistoryPopupWindow? {
        NSApp.windows.lazy.compactMap { $0 as? HistoryPopupWindow }.first
    }

    weak var previewPanel: PreviewWindow?
    weak var hoverPreviewPanel: PreviewWindow?

    private var itemDragInProgress = false
    private var awaitingPostDragInteraction = false

    var isItemDragInProgress: Bool {
        itemDragInProgress || awaitingPostDragInteraction
    }

    var isPresentingModalPanel = false
    private var mouseUpWatcher: Timer?
    private var postDragClickMonitor: Any?
    private var closeGuaranteeTimer: Timer?

    private var popupHostingView: PopupHostingView?

    var parkedSide: ParkSide?
    var pendingParkTargetX: CGFloat?
    var lastParkTickX: CGFloat?
    var parkSlideStallTicks = 0
    static let dragParkLeftZoneRatio: CGFloat = 0.45
    static let dragParkRightZoneRatio: CGFloat = 0.55
    static let dragParkMargin: CGFloat = 12
    static let dragParkDuration: TimeInterval = 0.22

    static let continuousDragDefaultsKey = "ContinuousDrag"

    static var continuousDragEnabled: Bool {
        UserDefaults.standard.object(forKey: continuousDragDefaultsKey) as? Bool ?? false
    }

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

    private static let fadeInDuration: TimeInterval = 0.2

    private static let fadeOutDuration: TimeInterval = 0.15

    private var closeSessionGeneration: UInt64 = 0

    func toggle() {
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
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
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
        self.isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { return true }

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

        ClipboardBackend.shared.recordFrontmostApp()

        ClipboardBackend.shared.setPopupVisible(true)

        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil

        self.alphaValue = 0

        let contentView = AnyView(HistoryPopupContent(onClose: { [weak self] in
            debugLog("HistoryPopupContent onClose callback")
            self?.close()
        }).withAppTheme())
        let hosting = PopupHostingView(rootView: contentView)
        popupHostingView = hosting
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        hosting.layer?.cornerRadius = 14
        hosting.layer?.cornerCurve = .continuous

        self.contentView = hosting

        applyContentScale(1.06, to: hosting, layer: hosting.layer!)

        resetDragParking()
        centerOnScreen()

        self.level = .floating
        self.acceptsMouseMovedEvents = true

        self.orderFrontRegardless()
        self.makeKey()

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

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDuration + 0.1) { [weak self] in
            guard let self, self.closeSessionGeneration == session,
                  self.lifecycleState == .opening,
                  self.closeGuaranteeTimer == nil,
                  self.alphaValue < 0.5 else { return }
            debugLog("show(): fade-in dropped; snapping window visible")
            self.alphaValue = 1
            self.lifecycleState = .open
        }

        DispatchQueue.main.async {
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

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

        perfShow?.end()
    }

    private func reverseToOpen() {
        debugLog("HistoryPopupWindow.reverseToOpen() called — interrupting close animation")
        closeSessionGeneration &+= 1
        let session = closeSessionGeneration
        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil
        lifecycleState = .opening

        ClipboardBackend.shared.recordFrontmostApp()
        ClipboardBackend.shared.setPopupVisible(true)

        NotificationCenter.default.post(name: popupCancelDismissNotification, object: nil)

        hoverPreviewPanel?.close()
        hoverPreviewPanel = nil

        if let pv = previewPanel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                pv.animator().alphaValue = 1
            }
        }

        if let hosting = popupHostingView {
            self.makeKey()
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

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
        awaitingPostDragInteraction = false
        removePostDragClickMonitor()
        popupHostingView?.resyncCommandSides()
    }

    @objc private func didResignKey(_ notification: Notification) {
        if isPresentingModalPanel {
            debugLog("Popup resigned key for a modal panel; retaining popup")
            return
        }
        if itemDragInProgress || awaitingPostDragInteraction {
            let batchActive = BatchDragController.shared.isActive
            if batchActive {
                BatchDragController.shared.dragEnded(at: NSEvent.mouseLocation, popupFrame: self.frame)
            }
            if Self.continuousDragEnabled && !batchActive {
                debugLog("Popup resigned key during item drag; awaiting next interaction")
            } else {
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

    private func startMouseUpWatcher() {
        stopMouseUpWatcher()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
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

        let batchActive = BatchDragController.shared.isActive
        if batchActive {
            BatchDragController.shared.dragEnded(at: NSEvent.mouseLocation, popupFrame: self.frame)
        }

        if Self.continuousDragEnabled && !batchActive {
            if parkedSide != nil {
                debugLog("Drag ended; restoring popup to center")
                restoreFromParking()
            }
            awaitingPostDragInteraction = true
            installPostDragClickMonitor()
        } else {
            awaitingPostDragInteraction = false
            removePostDragClickMonitor()
            resetDragParking()
            debugLog("Drag ended; closing popup (same as Esc)")
            close()
        }
    }

    private func reportItemDragFinished() {
        OnboardingGuide.shared.setItemDragInProgress(false)
        OnboardingGuide.shared.record(.dragged)
    }

    private func installPostDragClickMonitor() {
        removePostDragClickMonitor()
        postDragClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeWithAnimation()
        }
    }

    private func removePostDragClickMonitor() {
        if let monitor = postDragClickMonitor {
            NSEvent.removeMonitor(monitor)
            postDragClickMonitor = nil
        }
    }

    func setContentScale(_ scale: CGFloat) {
        guard let host = popupHostingView, let layer = host.layer else { return }
        layer.removeAnimation(forKey: "contentScale")
        applyContentScale(scale, to: host, layer: layer)
    }

    func animateContentScale(to scale: CGFloat, response: TimeInterval, damping: CGFloat) {
        guard let host = popupHostingView, let layer = host.layer else { return }
        let size = host.bounds.size
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = centerAnchoredTransform(scale: currentContentScale(of: layer), size: size)
        animation.toValue = centerAnchoredTransform(scale: scale, size: size)
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / response, 2)
        animation.damping = 2 * damping * sqrt(animation.stiffness)
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration
        layer.removeAnimation(forKey: "contentScale")
        layer.transform = centerAnchoredTransform(scale: scale, size: size)
        layer.add(animation, forKey: "contentScale")
    }

    private func centerAnchoredTransform(scale: CGFloat, size: CGSize) -> CATransform3D {
        let cx = size.width / 2
        let cy = size.height / 2
        var t = CATransform3DMakeTranslation(cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -cx, -cy, 0)
    }

    private func currentContentScale(of layer: CALayer) -> CGFloat {
        let transform = layer.presentation()?.transform ?? layer.transform
        return CGFloat(sqrt(transform.m11 * transform.m11 + transform.m12 * transform.m12))
    }

    private func applyContentScale(_ scale: CGFloat, to host: NSView, layer: CALayer) {
        layer.transform = centerAnchoredTransform(scale: scale, size: host.bounds.size)
    }

    func closeWithAnimation() {
        guard lifecycleState != .closing && lifecycleState != .closed else { return }
        lifecycleState = .closing

        let preview = previewPanel

        closeSessionGeneration &+= 1
        let session = closeSessionGeneration

        self.makeFirstResponder(nil)

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

        if let pv = preview {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                pv.animator().alphaValue = 0
            }
        }

        if let hp = hoverPreviewPanel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                hp.animator().alphaValue = 0
            }
        }

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
        ClipboardBackend.shared.setPopupVisible(false)

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: self)
        itemDragInProgress = false
        awaitingPostDragInteraction = false
        stopMouseUpWatcher()
        removePostDragClickMonitor()
        resetDragParking()
        BatchDragController.shared.cancel()
        closeGuaranteeTimer?.invalidate()
        closeGuaranteeTimer = nil
        previewPanel?.close()
        previewPanel = nil
        hoverPreviewPanel?.close()
        hoverPreviewPanel = nil

        self.makeFirstResponder(nil)

        super.close()
        self.orderOut(nil)

        self.contentView = nil
        popupHostingView = nil

        OnboardingGuide.shared.setItemDragInProgress(false)
        OnboardingGuide.shared.refreshSpotlight()

        if let appDelegate = AppDelegate.shared,
           !appDelegate.hasVisibleAppWindow,
           !appDelegate.isPresentingAppWindow {
            ClipboardBackend.shared.restorePasteTargetFocus()
        }

        perfClose?.end()
    }
}
