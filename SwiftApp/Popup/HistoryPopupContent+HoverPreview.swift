import AppKit
import SwiftUI

extension HistoryPopupContent {
    private static let hoverPreviewShowDelay: UInt64 = 180_000_000
    private static let hoverPreviewHideDelay: UInt64 = 220_000_000

    var hoverPreviewSuppressed: Bool {
        isDismissing
            || editingItemId != nil
            || showPreview
            || PasteQueueManager.shared.hasItems
            || popupWindow?.isItemDragInProgress == true
            || popupWindow?.isOpenOrOpening != true
    }

    private func canHoverPreview(_ item: ClipboardItem) -> Bool {
        switch item {
        case .image:
            return true
        case .text(_, _, _, _, _, _, let preview, _):
            return !preview.isEmpty
        }
    }

    func handleRowHover(item: ClipboardItem, hovering: Bool, screenRect: NSRect, moved: Bool) {
        guard canHoverPreview(item) else {
            if hovering {
                cancelPendingHoverPreview()
                scheduleHoverPreviewHide(for: hoverPreviewEntryId)
            }
            return
        }

        if hovering {
            guard moved, !hoverPreviewSuppressed else { return }
            hoverPreviewHideTask?.cancel()
            hoverPreviewHideTask = nil

            if popupWindow?.hoverPreviewPanel != nil {
                cancelPendingHoverPreview()
                presentHoverPreview(item: item, screenRect: screenRect)
                return
            }

            hoverPreviewPendingItem = item
            hoverPreviewPendingRect = screenRect
            hoverPreviewShowTask?.cancel()
            hoverPreviewShowTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.hoverPreviewShowDelay)
                guard !Task.isCancelled,
                      let pending = hoverPreviewPendingItem,
                      let rect = hoverPreviewPendingRect,
                      !hoverPreviewSuppressed,
                      popupWindow?.hoverPreviewPanel == nil else { return }
                presentHoverPreview(item: pending, screenRect: rect)
            }
        } else {
            if hoverPreviewPendingItem?.id == item.id {
                cancelPendingHoverPreview()
            }
            if hoverPreviewEntryId == item.id {
                scheduleHoverPreviewHide(for: item.id)
            }
        }
    }

    func presentHoverPreview(item: ClipboardItem, screenRect: NSRect) {
        guard hoverPreviewSuppressed == false,
              let popup = popupWindow,
              popup.isOpenOrOpening,
              let frame = PreviewWindow.miniFrame(for: item, anchorRow: screenRect, popupFrame: popup.frame) else {
            return
        }
        if let existing = popup.hoverPreviewPanel {
            existing.updateMini(item: item, frame: frame)
        } else {
            let mini = PreviewWindow(miniItem: item, frame: frame)
            mini.onExpand = {
                expandHoverPreview()
            }
            mini.onHoverChange = { inside in
                handleMiniHoverChange(inside)
            }
            popup.hoverPreviewPanel = mini
            mini.orderFront(nil)
            mini.fadeIn(duration: 0.12)
        }
        hoverPreviewEntryId = item.id
        hoverPreviewItem = item
    }

    func expandHoverPreview() {
        guard let popup = popupWindow,
              let mini = popup.hoverPreviewPanel,
              let item = hoverPreviewItem else { return }
        let expanded: ClipboardItem
        switch item {
        case .text:
            guard let full = fullTextItem(item) else { return }
            expanded = full
        case .image:
            expanded = item
        }
        cancelPendingHoverPreview()
        hoverPreviewEntryId = nil
        hoverPreviewItem = nil
        popup.hoverPreviewPanel = nil
        popup.previewPanel = mini
        showPreview = true
        mini.onExpand = nil
        mini.onDismiss = {
            closePreview()
        }
        mini.expandToLarge(item: expanded, centerAt: NSPoint(x: popup.frame.midX, y: popup.frame.midY))
        NSApp.activate(ignoringOtherApps: true)
        OnboardingGuide.shared.record(.previewed)
        OnboardingGuide.shared.refreshSpotlight()
    }

    func handleMiniHoverChange(_ inside: Bool) {
        guard !showPreview else { return }
        if inside {
            hoverPreviewHideTask?.cancel()
            hoverPreviewHideTask = nil
        } else {
            scheduleHoverPreviewHide(for: hoverPreviewEntryId)
        }
    }

    func scheduleHoverPreviewHide(for entryId: Int?) {
        guard let entryId else { return }
        hoverPreviewHideTask?.cancel()
        hoverPreviewHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.hoverPreviewHideDelay)
            guard !Task.isCancelled,
                  hoverPreviewEntryId == entryId,
                  popupWindow?.hoverPreviewPanel != nil else { return }
            closeHoverPreview()
        }
    }

    func cancelPendingHoverPreview() {
        hoverPreviewShowTask?.cancel()
        hoverPreviewShowTask = nil
        hoverPreviewPendingItem = nil
        hoverPreviewPendingRect = nil
    }

    func closeHoverPreview() {
        cancelPendingHoverPreview()
        hoverPreviewHideTask?.cancel()
        hoverPreviewHideTask = nil
        hoverPreviewEntryId = nil
        hoverPreviewItem = nil
        guard let mini = popupWindow?.hoverPreviewPanel else { return }
        popupWindow?.hoverPreviewPanel = nil
        mini.fadeOutAndClose()
    }
}
