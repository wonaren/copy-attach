import AppKit
import SwiftUI

// MARK: - Popup Notification Names

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

/// Payload for `popupContextMenuNotification`: where the user right-clicked
/// and where to position the NSMenu. `entryId` is nil on the raw click — the
/// content view resolves the row under the cursor from a one-shot frame
/// snapshot (measured on demand, see `HistoryPopupContent`) and fills it in
/// before presenting the menu. The receiver re-resolves the row by entry id
/// and uses `windowPoint` to position the NSMenu.
struct PopupContextMenuRequest {
    let entryId: Int?
    /// Click location in the SwiftUI root coordinate space (hosting view
    /// top-left origin, y down) — matches `geo.frame(in: .global)` frames.
    let viewPoint: NSPoint
    let windowPoint: NSPoint
}

// MARK: - Popup Hosting View

/// NSHostingView subclass that accepts first responder for keyboard events
class PopupHostingView: NSHostingView<AnyView> {
    /// Keep the outer 3 pt chrome as an explicit window-drag region. The
    /// content area—including every history row—never forwards a mouse drag to
    /// NSWindow, so an item drag cannot move the popup as well.
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

    /// Local event monitor to intercept ←/→ from the empty search field
    /// before NSTextView swallows them for cursor movement.
    private var arrowMonitor: Any?
    /// Escape must work while the embedded search NSTextView is first responder;
    /// it therefore needs AppKit-level interception rather than relying on the
    /// SwiftUI container's focus alone.
    private var escapeMonitor: Any?

    /// True while any NSMenu (including this app's context menus) is tracking.
    /// Menu navigation must not leak into popup shortcuts: Esc should dismiss
    /// only the menu, and ←/→ must not move the list selection underneath it.
    /// Set via `NSMenu.didBegin/EndTrackingNotification` — guaranteed for the
    /// explicit `NSMenu.popUp` used by the right-click context menu.
    private var isMenuTracking = false
    private var menuTrackingObservers: [NSObjectProtocol] = []

    /// Trackpad two-finger swipe → tab switching (see `handleScrollWheel`).
    private var swipeMonitor: Any?
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    private var swipeTracking = false
    private var swipeCommitted = false
    /// Horizontal distance (points) a two-finger swipe must cross to commit a
    /// tab switch.
    private static let swipeActivationThreshold: CGFloat = 50
    /// Minimum |horizontal|:|vertical| ratio to treat a gesture as a swipe
    /// instead of vertical list scrolling.
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

    /// Right-click on a history row: ask the content view to present its
    /// context menu at the click location. Row frames are NOT tracked
    /// continuously — the content view measures them on demand (one-shot
    /// snapshot on the next layout pass) and resolves the row under the
    /// cursor, so scrolling never pays per-row geometry reporting. Right-
    /// clicks elsewhere (search field, separators, empty space) resolve to no
    /// row and fall through untouched — the search NSTextField handles its
    /// own editing menu as a subview.
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        guard self.window != nil else { return }
        // Row frames live in SwiftUI's root coordinate space
        // (`geo.frame(in: .global)`): origin at the hosting view's top-left,
        // y pointing DOWN. NSHostingView is flipped (`isFlipped == true`), so
        // `convert(_:from: nil)` yields the click in exactly that same space —
        // matching frames against it needs no further conversion.
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
            // Only intercept when the search field (editable NSTextView) is
            // first responder and its string is empty — no cursor to move.
            // Skip entirely while a context menu is tracking: ←/→ belong to
            // menu navigation then, not list selection.
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
            // While a context menu tracks, Esc belongs to the menu (dismisses
            // only the menu) — never close the popup underneath it.
            guard event.keyCode == 53,
                  let self = self,
                  self.window?.isKeyWindow == true,
                  !self.isMenuTracking else { return event }

            // If the search field editor (NSTextView) is actively composing text with an IME
            // (e.g. Chinese/Japanese marked text with candidate window), allow the input method
            // to consume Escape to cancel composition instead of closing the popup.
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

    /// Two-finger swipe recognition on the scroll wheel stream. NSEvent
    /// scrollWheel events deliver both trackpad finger gestures (with a
    /// `phase`) and mouse-wheel/inertial momentum (phase == []); only the
    /// former can be a tab swipe. The tab switch is committed MID-GESTURE
    /// once the accumulated horizontal distance crosses the threshold — the
    /// content starts reacting while the fingers are still moving, so the
    /// interaction never waits for the release to begin. Events are swallowed
    /// only AFTER a commit, so a sub-threshold flick or a diagonal gesture
    /// that never qualifies passes through and the list just scrolls — there
    /// is no frozen dead-zone between "activated" and "committed".
    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        // Local monitors observe every window of the app — popup, preview
        // panel, settings. Only events aimed at the popup can be a tab swipe;
        // a swipe over a sibling window (e.g. the preview) must pass through
        // untouched so that window scrolls normally.
        guard event.window === self.window else {
            return event
        }

        // Mouse wheels and inertial momentum never carry a phase — never a swipe.
        guard event.phase != [] else {
            if swipeTracking { resetSwipeTracking() }
            return event
        }

        switch event.phase {
        case .mayBegin:
            // Fingers down but not yet moving; wait for the real `.began`.
            resetSwipeTracking()
            return event
        case .stationary:
            // Fingers paused mid-gesture. Keep the accumulated state — a
            // momentary pause must not discard progress (`.began` arrives once
            // per gesture), or a near-threshold swipe would never commit and
            // the resumed motion would leak into the ScrollView.
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

            // A decisive mid-gesture reversal re-targets the swipe. Once the
            // current event's horizontal motion opposes the accumulated run
            // beyond a jitter floor, discard the stale net and measure the
            // new run — otherwise a gesture that reverses before committing
            // locks the tab to the direction it first travelled (net
            // displacement), or nets below the threshold entirely even though
            // it moved decisively one way.
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
                // Commit the switch MID-GESTURE, while the fingers are still
                // moving — the content reacts under the hand instead of only
                // after release, which is what makes the swipe feel 跟手.
                // The page travels with the fingers: a left swipe advances to
                // the next tab, a right swipe steps back (the posted direction
                // keeps the ←/→ key convention: "left" = previous, "right" =
                // next).
                swipeCommitted = true
                NotificationCenter.default.post(
                    name: popupSwipeNotification,
                    object: swipeAccumX < 0 ? "right" : "left"
                )
            }
            // Swallow only after the commit: the switch already happened, so
            // the residual deltas must not nudge the newly shown tab. Before
            // the commit every event passes through — a vertical or diagonal
            // gesture that never qualifies simply scrolls the list.
            return swipeCommitted ? nil : event
        case .ended, .cancelled:
            // The switch, if any, was already committed mid-gesture in
            // `.changed`; this phase only cleans up and swallows the final
            // event when the gesture committed, so its residual delta cannot
            // nudge the history list.
            let wasCommitted = swipeCommitted
            resetSwipeTracking()
            return wasCommitted ? nil : event
        default:
            return event
        }
    }

    /// Sign factor that converts `scrollingDeltaX/Y` (inverted per the
    /// natural-scrolling setting) into the direction of the FINGER movement —
    /// the direction the user perceives the swipe in.
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

    /// Intercept ⌘Z before the search field's NSTextView swallows it for text undo.
    /// This catches the key-equivalent event regardless of which responder is first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isMenuTracking {
            return super.performKeyEquivalent(with: event)
        }
        // When an editable text view is focused (search field or inline remark editor),
        // let the text system handle Command+Z for text undo rather than clipboard undo.
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
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // A tracking menu owns keyboard input; do not reinterpret its keys.
        if isMenuTracking {
            super.keyDown(with: event)
            return
        }
        // Option + P: toggle favorite (must intercept before text input
        // system converts it to π character)
        if event.keyCode == 35 && event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            // Let the event pass through when an editable field is focused
            // so the user can type characters like π via Opt+P.
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: favoriteToggleNotification, object: nil)
            return
        }

        // Option + R: toggle inline remark editing (must intercept before text input
        // system converts it to ® character)
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

        // Command + number (1-9): quick select item
        if event.modifierFlags.contains(.command) {
            // kVK_ANSI key codes are NOT sequential — use a direct map.
            let keyCodeToNumber: [UInt16: Int] = [
                18: 1,  // kVK_ANSI_1
                19: 2,  // kVK_ANSI_2
                20: 3,  // kVK_ANSI_3
                21: 4,  // kVK_ANSI_4
                23: 5,  // kVK_ANSI_5
                22: 6,  // kVK_ANSI_6
                26: 7,  // kVK_ANSI_7
                28: 8,  // kVK_ANSI_8
                25: 9,  // kVK_ANSI_9
            ]
            if let number = keyCodeToNumber[event.keyCode] {
                NotificationCenter.default.post(name: commandNumberNotification, object: number)
                return
            }
        }
        // Delete / Backspace (keyCode 51) and Forward Delete (keyCode 117)
        if event.keyCode == 51 || event.keyCode == 117 {
            // Control + Delete: delete the selected item
            if event.modifierFlags.contains(.control) {
                NotificationCenter.default.post(name: deleteKeyNotification, object: nil)
                return
            }
            // Plain Delete while the search field is NOT focused: focus the
            // search bar and remove the last character. When the search field
            // IS focused, let the NSTextView handle it normally.
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

        // Command + Z: undo deletion (only when an editable text view is not focused)
        if event.keyCode == 6 && event.modifierFlags.contains(.command) {
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return
        }

        // Printable character while on an item: switch focus to search bar
        // and re-send the event so the search field's IME can process it
        // (e.g. Chinese/Japanese IME composition).
        // Let it pass through untouched when an editable text field is already focused
        // (such as inline remark editing).
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
            // After focus switches to search bar, re-send the original event
            // so the search field's NSTextView handles it with full IME support.
            // Use a weak reference to self.window rather than NSApp.keyWindow
            // to prevent keystroke injection into other apps if the popup
            // loses key status during the async gap.
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
