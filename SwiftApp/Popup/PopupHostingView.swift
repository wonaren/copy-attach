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
let arrowKeyFromSearchNotification = Notification.Name("PopupArrowKeyFromSearch")
let focusSearchAndBackspaceNotification = Notification.Name("PopupFocusSearchAndBackspace")
let escapeKeyNotification = Notification.Name("PopupEscapeKeyPressed")
let popupContextMenuNotification = Notification.Name("PopupContextMenuRequested")

/// Payload for `popupContextMenuNotification`: which history row was
/// right-clicked and where (window base coordinates). The receiver uses the
/// entry id to re-resolve the row and the point to position the NSMenu.
struct PopupContextMenuRequest {
    let entryId: Int
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installArrowMonitor()
            installEscapeMonitor()
            installMenuTrackingObservers()
        } else {
            removeArrowMonitor()
            removeEscapeMonitor()
            removeMenuTrackingObservers()
        }
    }

    /// Right-click on a history row: select the row under the cursor and ask
    /// the content view to present its context menu at the click location.
    /// Row frames come from `PopupRowFrameStore` (reported by SwiftUI rows via
    /// a preference key in global/screen coordinates). Right-clicks elsewhere
    /// (search field, separators, empty space) fall through untouched — the
    /// search NSTextField handles its own editing menu as a subview.
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        guard self.window != nil else { return }
        // Row frames are reported in SwiftUI's root coordinate space
        // (`geo.frame(in: .global)`): origin at the hosting view's top-left,
        // y pointing DOWN. NSHostingView is flipped (`isFlipped == true`), so
        // `convert(_:from: nil)` yields the click in exactly that same space —
        // matching frames against it needs no further conversion.
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let (entryId, _) = PopupRowFrameStore.shared.frames
            .first(where: { $0.value.contains(viewPoint) }) else { return }
        NotificationCenter.default.post(
            name: popupContextMenuNotification,
            object: PopupContextMenuRequest(entryId: entryId,
                                            windowPoint: event.locationInWindow)
        )
    }

    private func installMenuTrackingObservers() {
        removeMenuTrackingObservers()
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isMenuTracking = true })
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isMenuTracking = false })
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

    deinit {
        removeArrowMonitor()
        removeEscapeMonitor()
        removeMenuTrackingObservers()
    }

    /// Intercept ⌘Z before the search field's NSTextView swallows it for text undo.
    /// This catches the key-equivalent event regardless of which responder is first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isMenuTracking {
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
            // Let the event pass through when the search bar is focused
            // so the user can type characters like π via Opt+P.
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: favoriteToggleNotification, object: nil)
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

        // Command + Z: undo deletion
        if event.keyCode == 6 && event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return
        }

        // Printable character while on an item: switch focus to search bar
        // and re-send the event so the search field's IME can process it
        // (e.g. Chinese/Japanese IME composition).
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
