import AppKit
import SwiftUI

extension HistoryPopupContent {
    func handleEscape() {
        if editingItemId != nil {
            cancelInlineEditing()
        } else if PasteQueueManager.shared.hasItems {
            withAnimation(AppleMotion.snappy) {
                PasteQueueManager.shared.cancel()
            }
        } else if showPreview {
            closePreview()
        } else {
            searchText = ""
            if let popup = popupWindow {
                popup.closeWithAnimation()
            } else {
                onClose()
            }
        }
    }

    func togglePreview() {
        if showPreview { closePreview(); return }
        let itemIndex = selectedIndex - 1
        guard itemIndex >= 0, itemIndex < displayItems.count else { return }
        openPreview(item: displayItems[itemIndex])
    }

    func openPreview(item: ClipboardItem) {
        let perfPreview = PerfSpan.start("swift", "preview.open")
        guard let popup = popupWindow else { return }
        closeHoverPreview()
        let popupCenter = NSPoint(x: popup.frame.midX, y: popup.frame.midY)
        guard let previewItem = fullTextItem(item) else { return }
        let preview = PreviewWindow(item: previewItem, centerAt: popupCenter)
        popup.previewPanel = preview
        preview.alphaValue = 0
        preview.orderFront(nil)
        preview.fadeIn()
        NSApp.activate(ignoringOtherApps: true)
        showPreview = true
        OnboardingGuide.shared.record(.previewed)
        OnboardingGuide.shared.refreshSpotlight()
        perfPreview?.end()
    }

    func closePreview() {
        var changed = false
        if showPreview {
            showPreview = false
            popupWindow?.previewPanel?.fadeOutAndClose()
            popupWindow?.previewPanel = nil
            changed = true
        }
        if popupWindow?.hoverPreviewPanel != nil {
            closeHoverPreview()
            changed = true
        }
        if changed {
            OnboardingGuide.shared.refreshSpotlight()
        }
    }

    func updatePreviewContent(item: ClipboardItem) {
        guard showPreview, let preview = popupWindow?.previewPanel else { return }
        guard let previewItem = fullTextItem(item) else {
            closePreview()
            return
        }
        preview.updateContent(item: previewItem)
    }

    func fullTextItem(_ item: ClipboardItem) -> ClipboardItem? {
        switch item {
        case .text(let entryId, let timestamp, let customLabel, let label, let sourceName, let sourceBundleId, _, let displayPreview):
            let perfText = PerfSpan.start("swift", "preview.load_full_text")
            if let span = perfText { span.val = Int64(entryId) }
            defer { perfText?.end() }
            guard let full = item.fullText else {
                debugLog("fullTextItem: failed to load full text for entry \(entryId)")
                return nil
            }
            return .text(entryId: entryId, timestamp: timestamp,
                         customLabel: customLabel,
                         label: label, sourceName: sourceName, sourceBundleId: sourceBundleId,
                         preview: full, displayPreview: displayPreview)
        default:
            return item
        }
    }
}
