import AppKit
import SwiftUI

struct InlineRemarkField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var textColor: NSColor = .white
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.textColor = textColor
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1

        DispatchQueue.main.async {
            if let window = field.window {
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.textColor != textColor {
            nsView.textColor = textColor
        }
        if nsView.stringValue != text && nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRemarkField
        var didCommitOrCancel = false

        init(_ parent: InlineRemarkField) {
            self.parent = parent
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     shouldChangeTextIn affectedCharRange: NSRange,
                     replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            return MainActor.assumeIsolated {
                let current = textView.string as NSString
                guard affectedCharRange.location != NSNotFound,
                      affectedCharRange.location + affectedCharRange.length <= current.length else {
                    return true
                }
                let proposed = current.replacingCharacters(in: affectedCharRange, with: replacement)
                return proposed.unicodeScalars.count <= ClipboardBackend.maxCustomLabelScalars
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                if !didCommitOrCancel {
                    didCommitOrCancel = true
                    control.window?.makeFirstResponder((control.window as? HistoryPopupWindow)?.focusTargetView)
                    parent.onCommit(control.stringValue)
                }
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !didCommitOrCancel {
                    didCommitOrCancel = true
                    control.window?.makeFirstResponder((control.window as? HistoryPopupWindow)?.focusTargetView)
                    parent.onCancel()
                }
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if !didCommitOrCancel {
                didCommitOrCancel = true
                field.window?.makeFirstResponder((field.window as? HistoryPopupWindow)?.focusTargetView)
                parent.onCommit(field.stringValue)
            }
        }
    }
}
