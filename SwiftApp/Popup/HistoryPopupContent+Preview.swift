import AppKit
import SwiftUI

// MARK: - Preview Management

extension HistoryPopupContent {
    func handleEscape() {
        if showPreview {
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
        let itemIndex = selectedIndex - 1
        guard itemIndex < displayItems.count, let popup = popupWindow else { return }
        let item = displayItems[itemIndex]
        let popupCenter = NSPoint(x: popup.frame.midX, y: popup.frame.midY)
        guard let previewItem = fullTextItem(item) else { return }
        let preview = PreviewWindow(item: previewItem, centerAt: popupCenter)
        popup.previewPanel = preview
        preview.orderFront(nil)
        // Trackpad pinch (magnify) events are delivered only to the truly
        // frontmost application. This LSUIElement agent app never receives
        // applicationDidBecomeActive while its nonactivating panels are up —
        // NSApp.isActive reports true, but the window server keeps routing
        // magnify gestures to the previous app, so ZoomableImageNSView's
        // magnify monitor never fires. Real activation makes gesture delivery
        // work for the preview. Deactivation is automatic when the
        // popup/preview closes or another app is clicked; the paste target
        // pid is protected in ClipboardBackend.updateSourceApp.
        NSApp.activate(ignoringOtherApps: true)
        showPreview = true
    }

    func closePreview() {
        guard showPreview else { return }
        showPreview = false
        popupWindow?.previewPanel?.close()
        popupWindow?.previewPanel = nil
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
        case .text(let entryId, _, let timestamp, let label, let sourceName, let sourceBundleId, _):
            guard let full = item.fullText else {
                debugLog("fullTextItem: failed to load full text for entry \(entryId)")
                return nil
            }
            return .text(entryId: entryId, text: full, timestamp: timestamp,
                         label: label, sourceName: sourceName, sourceBundleId: sourceBundleId, preview: full)
        default:
            return item
        }
    }
}
