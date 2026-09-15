import AppKit
import SwiftUI

// MARK: - Sheet Outside Click Dismissal (Apple HIG)

/// An NSViewRepresentable that attaches to a sheet's view hierarchy, monitors
/// mouse-down events, and dismisses the sheet when a click occurs outside the
/// sheet's window frame or outside the application.
struct SheetOutsideClickDetector: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> SheetDetectorNSView {
        let view = SheetDetectorNSView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: SheetDetectorNSView, context: Context) {
        nsView.onDismiss = onDismiss
    }
}

@MainActor
final class SheetDetectorNSView: NSView {
    var onDismiss: (() -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupMonitors()
        } else {
            removeMonitors()
        }
    }

    private func setupMonitors() {
        removeMonitors()

        // 1. Local monitor: detects clicks within this app
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let sheetWindow = self.window else { return event }

            // If an NSOpenPanel/NSSavePanel modal session is running, let it handle events
            if NSApp.modalWindow != nil {
                return event
            }
            if let eventWindow = event.window {
                if eventWindow is NSOpenPanel || eventWindow is NSSavePanel {
                    return event
                }
                // Allow internal popup menus and popovers without dismissing the sheet
                let className = String(describing: type(of: eventWindow))
                if className.contains("Menu") || className.contains("Popover") {
                    return event
                }
            }

            // If the click is inside the sheet window, allow normal interaction
            if event.window === sheetWindow {
                return event
            }

            // Click is outside the sheet window!
            DispatchQueue.main.async {
                self.onDismiss?()
            }

            // If click was on the parent window, consume it so background controls aren't triggered
            if event.window === sheetWindow.sheetParent {
                return nil
            }
            return event
        }

        // 2. Global monitor: detects clicks outside the application (desktop, other apps)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.window != nil else { return }
            if NSApp.modalWindow != nil { return }
            DispatchQueue.main.async {
                self.onDismiss?()
            }
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    isolated deinit {
        removeMonitors()
    }
}

// MARK: - View Modifier

struct SheetDismissOnOutsideClickModifier: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .background(SheetOutsideClickDetector(onDismiss: onDismiss))
            .background(
                // Support Escape key to dismiss as well (macOS HIG standard)
                Button("") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
            )
    }
}

extension View {
    /// Dismisses the sheet when clicking outside the sheet window or pressing Escape.
    func sheetDismissOnOutsideClick(onDismiss: @escaping () -> Void) -> some View {
        modifier(SheetDismissOnOutsideClickModifier(onDismiss: onDismiss))
    }
}
