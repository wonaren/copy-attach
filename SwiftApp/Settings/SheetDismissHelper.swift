import AppKit
import SwiftUI

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

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let sheetWindow = self.window else { return event }

            if NSApp.modalWindow != nil {
                return event
            }
            if let eventWindow = event.window {
                if eventWindow is NSOpenPanel || eventWindow is NSSavePanel {
                    return event
                }
                let className = String(describing: type(of: eventWindow))
                if className.contains("Menu") || className.contains("Popover") {
                    return event
                }
            }

            if event.window === sheetWindow {
                return event
            }

            DispatchQueue.main.async {
                self.onDismiss?()
            }

            if event.window === sheetWindow.sheetParent {
                return nil
            }
            return event
        }

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

struct SheetDismissOnOutsideClickModifier: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .background(SheetOutsideClickDetector(onDismiss: onDismiss))
            .background(
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
    func sheetDismissOnOutsideClick(onDismiss: @escaping () -> Void) -> some View {
        modifier(SheetDismissOnOutsideClickModifier(onDismiss: onDismiss))
    }
}
