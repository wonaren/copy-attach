import AppKit
import ApplicationServices

struct CaretAnchor {
    let rect: NSRect
    let source: String
}

extension CaretAnchor {
    private static let callTimeout: Float = 0.025

    private static let totalBudget: CFTimeInterval = 0.06

    static func locate(in pid: pid_t) -> CaretAnchor? {
        guard pid > 0 else { return nil }
        let deadline = CACurrentMediaTime() + totalBudget
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, callTimeout)
        var focusedRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusedErr == .success, let focusedRef else {
            if focusedErr == .apiDisabled {
                debugLog("CaretAnchor: accessibility permission unavailable (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
            } else {
                debugLog("CaretAnchor: pid \(pid) focused element err=\(focusedErr.rawValue)")
            }
            return nil
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            debugLog("CaretAnchor: pid \(pid) focused attribute is not an AXUIElement")
            return nil
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        if let rect = caretRect(of: element) {
            return CaretAnchor(rect: rect, source: "range")
        }
        guard CACurrentMediaTime() < deadline else {
            debugLog("CaretAnchor: pid \(pid) out of budget after range tier")
            return nil
        }
        if let rect = textMarkerCaretRect(of: element) {
            return CaretAnchor(rect: rect, source: "marker")
        }
        guard CACurrentMediaTime() < deadline else {
            debugLog("CaretAnchor: pid \(pid) out of budget after marker tier")
            return nil
        }
        if let rect = elementFrame(of: element) {
            return CaretAnchor(rect: rect, source: "element")
        }
        return nil
    }

    private static func caretRect(of element: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            debugLog("CaretAnchor: selected text range err=\(rangeErr.rawValue)")
            return nil
        }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &selection) else { return nil }

        var caret = CFRange(location: selection.location, length: 0)
        guard let caretValue = AXValueCreate(.cfRange, &caret) else { return nil }
        var boundsRef: CFTypeRef?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            caretValue,
            &boundsRef
        )
        guard boundsErr == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            debugLog("CaretAnchor: bounds for range err=\(boundsErr.rawValue)")
            return nil
        }
        var axRect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsRef, to: AXValue.self), .cgRect, &axRect) else { return nil }
        guard axRect.width > 0 || axRect.height > 0 else {
            debugLog("CaretAnchor: bounds for range returned an empty rect")
            return nil
        }
        return cocoaRect(axRect)
    }

    private static func textMarkerCaretRect(of element: AXUIElement) -> NSRect? {
        var markerRef: CFTypeRef?
        let markerErr = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRef)
        guard markerErr == .success, let markerRef else { return nil }
        var boundsRef: CFTypeRef?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRef,
            &boundsRef
        )
        guard boundsErr == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            debugLog("CaretAnchor: bounds for text marker range err=\(boundsErr.rawValue)")
            return nil
        }
        var axRect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(boundsRef, to: AXValue.self), .cgRect, &axRect) else { return nil }
        guard axRect.width > 0 || axRect.height > 0 else {
            debugLog("CaretAnchor: bounds for text marker range returned an empty rect")
            return nil
        }
        return cocoaRect(axRect)
    }

    private static let maxElementAnchorHeight: CGFloat = 240

    private static func elementFrame(of element: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        guard size.height <= maxElementAnchorHeight else {
            debugLog("CaretAnchor: focused element is \(Int(size.width))x\(Int(size.height)), too tall to be an input box")
            return nil
        }
        return cocoaRect(CGRect(origin: point, size: size))
    }

    private static func cocoaRect(_ axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            debugLog("CaretAnchor: no screen at the AX coordinate origin")
            return nil
        }
        return NSRect(x: axRect.minX,
                      y: primary.frame.maxY - axRect.maxY,
                      width: axRect.width,
                      height: axRect.height)
    }
}
