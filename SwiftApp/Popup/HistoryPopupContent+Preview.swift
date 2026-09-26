import AppKit
import SwiftUI

// MARK: - Preview Management

extension HistoryPopupContent {
    func handleEscape() {
        if editingItemId != nil {
            cancelInlineEditing()
        } else if showPreview {
            closePreview()
        } else {
            searchText = ""
            onClose()
        }
    }

    func togglePreview() {
        if showPreview { closePreview() } else { openPreview() }
    }

    func openPreview() {
        let perfPreview = PerfSpan.start("swift", "preview.open")
        let itemIndex = selectedIndex - 1
        guard itemIndex < displayItems.count, let popup = popupWindow else { return }
        let item = displayItems[itemIndex]
        let popupCenter = NSPoint(x: popup.frame.midX, y: popup.frame.midY)
        guard let previewItem = fullTextItem(item) else { return }
        // A fresh window per preview session. (A reused window was tried for
        // small-zone churn savings, but its lifecycle — content detach,
        // re-mount on an ordered-out window, alpha/fade state — proved too
        // fragile: previews silently stopped appearing after the first one.
        // The measured cost of rebuilding is bounded: repeated preview
        // sessions accumulate nothing beyond a one-time decode-pool resize.)
        let preview = PreviewWindow(item: previewItem, centerAt: popupCenter)
        popup.previewPanel = preview
        // Start transparent before ordering on screen so the fade always runs
        // from 0 (same ordering the popup window uses for its own fade).
        preview.alphaValue = 0
        preview.orderFront(nil)
        preview.fadeIn()
        // Trackpad pinch (magnify) events are delivered only to the truly
        // frontmost application. This LSUIElement agent app never receives
        // applicationDidBecomeActive while its nonactivating panels are up —
        // NSApp.isActive reports true, but the window server keeps routing
        // magnify gestures to the previous app, so ZoomableImageNSView's
        // magnify monitor never fires. Real activation makes gesture delivery
        // work for the preview.
        //
        // The foreground is NOT handed back by the system: closing the preview
        // leaves this app activated. `ClipboardBackend.restorePasteTargetFocus()`
        // returns it after a paste; the target pid itself is protected in
        // `updateSourceApp`.
        NSApp.activate(ignoringOtherApps: true)
        showPreview = true
        OnboardingGuide.shared.record(.previewed)
        // The preview panel has its own level, so the tour has to light it too.
        OnboardingGuide.shared.refreshSpotlight()
        perfPreview?.end()
    }

    func closePreview() {
        guard showPreview else { return }
        showPreview = false
        // Fade the panel out rather than snapping it away. The panel retains
        // itself through the fade's completion; `nil`ing the popup's reference
        // only drops the popup's own handle.
        popupWindow?.previewPanel?.fadeOutAndClose()
        popupWindow?.previewPanel = nil
        OnboardingGuide.shared.refreshSpotlight()
    }

    func updatePreviewContent() {
        let itemIndex = selectedIndex - 1
        guard showPreview, itemIndex >= 0, itemIndex < displayItems.count,
              let preview = popupWindow?.previewPanel else { return }
        guard let previewItem = fullTextItem(displayItems[itemIndex]) else {
            closePreview()
            return
        }
        preview.updateContent(item: previewItem)
    }

    private func fullTextItem(_ item: ClipboardItem) -> ClipboardItem? {
        switch item {
        case .text(let entryId, let timestamp, let customLabel, let label, let sourceName, let sourceBundleId, _, let displayPreview):
            let perfText = PerfSpan.start("swift", "preview.load_full_text")
            if let span = perfText { span.val = Int64(entryId) }
            defer { perfText?.end() }
            guard let full = item.fullText else {
                debugLog("fullTextItem: failed to load full text for entry \(entryId)")
                return nil
            }
            // `preview` becomes the full text (LargeTextView renders it), but the row's
            // display form is carried over: the preview panel never renders it, and
            // recomputing it here would scan the whole document to produce nothing.
            return .text(entryId: entryId, timestamp: timestamp,
                         customLabel: customLabel,
                         label: label, sourceName: sourceName, sourceBundleId: sourceBundleId,
                         preview: full, displayPreview: displayPreview)
        default:
            return item
        }
    }
}
