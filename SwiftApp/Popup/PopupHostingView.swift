import AppKit
import SwiftUI

let deleteKeyNotification = Notification.Name("PopupDeleteKeyPressed")
let controlKeyNotification = Notification.Name("PopupControlKeyChanged")
let commandKeyNotification = Notification.Name("PopupCommandKeyChanged")
let commandNumberNotification = Notification.Name("PopupCommandNumberPressed")
let focusSearchNotification = Notification.Name("PopupFocusSearch")
let undoKeyNotification = Notification.Name("PopupUndoKeyPressed")
let favoriteToggleNotification = Notification.Name("PopupFavoriteToggle")
let startInlineEditNotification = Notification.Name("PopupStartInlineEdit")
let arrowKeyFromSearchNotification = Notification.Name("PopupArrowKeyFromSearch")
let focusSearchAndBackspaceNotification = Notification.Name("PopupFocusSearchAndBackspace")
let escapeKeyNotification = Notification.Name("PopupEscapeKeyPressed")
let popupContextMenuNotification = Notification.Name("PopupContextMenuRequested")
let popupSwipeNotification = Notification.Name("PopupSwipe")
let popupWillDismissNotification = Notification.Name("PopupWillDismiss")
let popupCancelDismissNotification = Notification.Name("PopupCancelDismiss")
let queueToggleNotification = Notification.Name("PopupQueueTogglePressed")

struct PopupContextMenuRequest {
    let entryId: Int?
    let viewPoint: NSPoint
    let windowPoint: NSPoint
}

class PopupHostingView: NSHostingView<AnyView> {
    private let windowDragBorder: CGFloat = 3

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= windowDragBorder || point.x >= bounds.maxX - windowDragBorder ||
              point.y <= windowDragBorder || point.y >= bounds.maxY - windowDragBorder else {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }

    private var arrowMonitor: Any?
    private var escapeMonitor: Any?

    private var isMenuTracking = false
    private var menuTrackingObservers: [NSObjectProtocol] = []

    private var swipeMonitor: Any?
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    private var swipeTracking = false
    private var swipeCommitted = false
    private static let swipeActivationThreshold: CGFloat = 50
    private static let swipeAxisRatio: CGFloat = 1.5

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installArrowMonitor()
            installEscapeMonitor()
            installMenuTrackingObservers()
            installSwipeMonitor()
        } else {
            removeArrowMonitor()
            removeEscapeMonitor()
            removeMenuTrackingObservers()
            removeSwipeMonitor()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        guard self.window != nil else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        NotificationCenter.default.post(
            name: popupContextMenuNotification,
            object: PopupContextMenuRequest(entryId: nil,
                                            viewPoint: viewPoint,
                                            windowPoint: event.locationInWindow)
        )
    }

    private func installMenuTrackingObservers() {
        removeMenuTrackingObservers()
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuTracking = true }
        })
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuTracking = false }
        })
    }

    private func removeMenuTrackingObservers() {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuTrackingObservers.removeAll()
    }

    private func installArrowMonitor() {
        removeArrowMonitor()
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 123 || event.keyCode == 124 else { return event }
            guard let self = self,
                  !self.isMenuTracking,
                  let textView = self.window?.firstResponder as? NSTextView,
                  textView.isEditable,
                  textView.string.isEmpty else { return event }
            let direction: String = event.keyCode == 123 ? "left" : "right"
            NotificationCenter.default.post(name: arrowKeyFromSearchNotification, object: direction)
            return nil
        }
    }

    private func removeArrowMonitor() {
        if let monitor = arrowMonitor {
            NSEvent.removeMonitor(monitor)
            arrowMonitor = nil
        }
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53,
                  let self = self,
                  self.window?.isKeyWindow == true,
                  !self.isMenuTracking else { return event }

            if let textView = self.window?.firstResponder as? NSTextView, textView.hasMarkedText() {
                return event
            }

            NotificationCenter.default.post(name: escapeKeyNotification, object: nil)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func installSwipeMonitor() {
        removeSwipeMonitor()
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, !self.isMenuTracking else { return event }
            return self.handleScrollWheel(event)
        }
    }

    private func removeSwipeMonitor() {
        if let monitor = swipeMonitor {
            NSEvent.removeMonitor(monitor)
            swipeMonitor = nil
        }
        resetSwipeTracking()
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard event.window === self.window else {
            return event
        }

        guard event.phase != [] else {
            if swipeTracking { resetSwipeTracking() }
            return event
        }

        switch event.phase {
        case .mayBegin:
            resetSwipeTracking()
            return event
        case .stationary:
            return event
        case .began:
            swipeTracking = true
            swipeCommitted = false
            swipeAccumX = 0
            swipeAccumY = 0
            accumulateSwipeDelta(event)
            return event
        case .changed:
            guard swipeTracking else { return event }

            let sign = fingerSign(for: event)
            let fingerDx = event.scrollingDeltaX * sign
            let fingerDy = event.scrollingDeltaY * sign
            if !swipeCommitted,
               swipeAccumX != 0,
               abs(fingerDx) >= abs(fingerDy),
               (fingerDx < 0) != (swipeAccumX < 0),
               abs(fingerDx) >= 0.5 * abs(swipeAccumX) {
                swipeAccumX = 0
                swipeAccumY = 0
            }
            accumulateSwipeDelta(event)

            if !swipeCommitted,
               abs(swipeAccumX) >= Self.swipeActivationThreshold,
               abs(swipeAccumX) >= Self.swipeAxisRatio * abs(swipeAccumY) {
                swipeCommitted = true
                NotificationCenter.default.post(
                    name: popupSwipeNotification,
                    object: swipeAccumX < 0 ? "right" : "left"
                )
            }
            return swipeCommitted ? nil : event
        case .ended, .cancelled:
            let wasCommitted = swipeCommitted
            resetSwipeTracking()
            return wasCommitted ? nil : event
        default:
            return event
        }
    }

    private func fingerSign(for event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? 1 : -1
    }

    private func accumulateSwipeDelta(_ event: NSEvent) {
        let sign = fingerSign(for: event)
        swipeAccumX += event.scrollingDeltaX * sign
        swipeAccumY += event.scrollingDeltaY * sign
    }

    private func resetSwipeTracking() {
        swipeTracking = false
        swipeCommitted = false
        swipeAccumX = 0
        swipeAccumY = 0
    }

    deinit {
        MainActor.assumeIsolated {
            removeArrowMonitor()
            removeEscapeMonitor()
            removeMenuTrackingObservers()
            removeSwipeMonitor()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isMenuTracking {
            return super.performKeyEquivalent(with: event)
        }
        if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == 6 && event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return true
        }
        if event.keyCode == 8 && event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            NotificationCenter.default.post(name: queueToggleNotification, object: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isMenuTracking {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 35 && event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: favoriteToggleNotification, object: nil)
            return
        }

        if event.keyCode == 15 && event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: startInlineEditNotification, object: nil)
            return
        }

        if event.modifierFlags.contains(.command) {
            let keyCodeToNumber: [UInt16: Int] = [
                18: 1,
                19: 2,
                20: 3,
                21: 4,
                23: 5,
                22: 6,
                26: 7,
                28: 8,
                25: 9,
            ]
            if let number = keyCodeToNumber[event.keyCode] {
                NotificationCenter.default.post(name: commandNumberNotification, object: number)
                return
            }
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.control) {
                NotificationCenter.default.post(name: deleteKeyNotification, object: nil)
                return
            }
            if !event.modifierFlags.contains(.command) &&
               !event.modifierFlags.contains(.option) &&
               !event.modifierFlags.contains(.shift) {
                if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                    super.keyDown(with: event)
                    return
                }
                NotificationCenter.default.post(name: focusSearchAndBackspaceNotification, object: nil)
                return
            }
        }

        if event.keyCode == 6 && event.modifierFlags.contains(.command) {
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return
        }

        if event.keyCode == 8 && event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: queueToggleNotification, object: nil)
            return
        }

        if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
            super.keyDown(with: event)
            return
        }

        if let chars = event.characters,
           let first = chars.first,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           (first.isLetter || first.isNumber || first.isPunctuation)
        {
            NotificationCenter.default.post(name: focusSearchNotification, object: nil)
            weak let popupWindow = self.window
            DispatchQueue.main.async { [event] in
                popupWindow?.firstResponder?.keyDown(with: event)
            }
            return
        }

        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        NotificationCenter.default.post(name: controlKeyNotification, object: controlPressed)

        let commandPressed = event.modifierFlags.contains(.command)
        NotificationCenter.default.post(name: commandKeyNotification, object: commandPressed)

        super.flagsChanged(with: event)
    }
}
