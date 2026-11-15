import AppKit
import SwiftUI

enum HoverPreviewSource: Equatable {
    case mouse
    case keyboard
}

extension HistoryPopupContent {
    private static let hoverPreviewShowDelay: UInt64 = 180_000_000
    private static let hoverPreviewHideDelay: UInt64 = 220_000_000
    private static let sidePreviewAutoHideDelay: UInt64 = 3_000_000_000

    var hoverPreviewSuppressed: Bool {
        isDismissing
            || editingItemId != nil
            || showPreview
            || OnboardingGuide.shared.isActive
            || popupWindow?.isPresentingModalPanel == true
            || popupWindow?.isItemDragInProgress == true
            || popupWindow?.isOpenOrOpening != true
            || QuickSlotDialWindow.shared.isVisible
    }

    func isSidePreviewEnabled(for item: ClipboardItem) -> Bool {
        switch item {
        case .text: return textSidePreviewEnabled
        case .image: return imageSidePreviewEnabled
        }
    }

    private func canHoverPreview(_ item: ClipboardItem) -> Bool {
        guard isSidePreviewEnabled(for: item) else { return false }
        switch item {
        case .image(_, let dbId, _, _, _, _, _, _, _):
            return dbId != 0
        case .text(_, _, _, _, _, _, let preview, _):
            return !preview.isEmpty
        }
    }

    func handleRowHover(item: ClipboardItem, hovering: Bool, screenRect: NSRect, moved: Bool) {
        guard canHoverPreview(item) else {
            if hovering {
                if hoverPreviewSource == .keyboard { return }
                cancelPendingHoverPreview()
                scheduleHoverPreviewHide(for: hoverPreviewEntryId)
            }
            return
        }

        if hovering {
            guard moved, !hoverPreviewSuppressed else { return }
            hoverPreviewHideTask?.cancel()
            hoverPreviewHideTask = nil

            if popupWindow?.hoverPreviewPanel != nil, hoverPreviewSource == .mouse {
                cancelPendingHoverPreview()
                presentHoverPreview(item: item, screenRect: screenRect, source: .mouse)
                return
            }

            hoverPreviewPendingItem = item
            hoverPreviewPendingRect = screenRect
            sidePreviewAutoHideTask?.cancel()
            sidePreviewAutoHideTask = nil
            hoverPreviewShowTask?.cancel()
            hoverPreviewShowTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.hoverPreviewShowDelay)
                guard !Task.isCancelled else { return }
                hoverPreviewShowTask = nil
                guard let pending = hoverPreviewPendingItem,
                      let rect = hoverPreviewPendingRect,
                      !hoverPreviewSuppressed,
                      (popupWindow?.hoverPreviewPanel == nil || hoverPreviewSource == .keyboard) else { return }
                presentHoverPreview(item: pending, screenRect: rect, source: .mouse)
            }
        } else {
            if hoverPreviewPendingItem?.id == item.id {
                cancelPendingHoverPreview()
            }
            if hoverPreviewSource == .mouse, hoverPreviewEntryId == item.id {
                scheduleHoverPreviewHide(for: item.id)
            }
        }
    }

    func scheduleKeyboardPreview(forItemAt itemIndex: Int) {
        let items = displayItems
        guard items.indices.contains(itemIndex) else { return }
        let item = items[itemIndex]

        guard !hoverPreviewSuppressed, canHoverPreview(item) else {
            closeHoverPreview()
            return
        }

        hoverPreviewHideTask?.cancel()
        hoverPreviewHideTask = nil
        cancelPendingHoverPreview()
        keyboardPreviewTargetId = item.id

        if popupWindow?.hoverPreviewPanel != nil {
            if let anchor = selectedRowAnchor, anchor.entryId == item.id {
                presentKeyboardHoverPreview(item: item, localRect: anchor.rect)
            }
            return
        }

        hoverPreviewShowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.hoverPreviewShowDelay)
            guard !Task.isCancelled else { return }
            hoverPreviewShowTask = nil
            guard !hoverPreviewSuppressed,
                  keyboardPreviewTargetId == item.id,
                  selectedItemId == item.id,
                  let anchor = selectedRowAnchor,
                  anchor.entryId == item.id else { return }
            presentKeyboardHoverPreview(item: item, localRect: anchor.rect)
        }
    }

    func handleSelectedRowAnchorUpdate(_ anchor: SelectedRowAnchor?) {
        guard let anchor,
              !hoverPreviewSuppressed,
              keyboardPreviewTargetId == anchor.entryId,
              selectedItemId == anchor.entryId,
              hoverPreviewShowTask == nil,
              let item = displayItems.first(where: { $0.id == anchor.entryId }) else {
            return
        }
        presentKeyboardHoverPreview(item: item, localRect: anchor.rect)
    }

    func scheduleSidePreviewAutoHide(for entryId: Int) {
        sidePreviewAutoHideTask?.cancel()
        sidePreviewAutoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.sidePreviewAutoHideDelay)
            guard !Task.isCancelled,
                  hoverPreviewEntryId == entryId,
                  popupWindow?.hoverPreviewPanel != nil else { return }
            closeHoverPreview(autoDismiss: true)
        }
    }

    func presentKeyboardHoverPreview(item: ClipboardItem, localRect: CGRect) {
        guard !hoverPreviewSuppressed,
              let popup = popupWindow,
              popup.isOpenOrOpening,
              let hostingView = popup.focusTargetView else { return }
        guard localRect.height > 0,
              localRect.midY >= 0,
              localRect.midY <= popup.frame.height else { return }
        let windowRect = hostingView.convert(localRect, to: nil)
        let screenRect = popup.convertToScreen(windowRect)
        presentHoverPreview(item: item, screenRect: screenRect, source: .keyboard)
    }

    func presentHoverPreview(item: ClipboardItem, screenRect: NSRect, source: HoverPreviewSource) {
        guard hoverPreviewSuppressed == false,
              let popup = popupWindow,
              popup.isOpenOrOpening,
              let frame = PreviewWindow.miniFrame(for: item, anchorRow: screenRect, popupFrame: popup.frame) else {
            return
        }
        hoverPreviewSource = source
        if source == .mouse {
            keyboardPreviewTargetId = nil
        }
        scheduleSidePreviewAutoHide(for: item.id)
        if let existing = popup.hoverPreviewPanel {
            hoverPreviewEntryId = item.id
            hoverPreviewItem = item
            DispatchQueue.main.async {
                guard !hoverPreviewSuppressed,
                      popup.hoverPreviewPanel === existing,
                      hoverPreviewEntryId == item.id else { return }
                existing.updateMini(item: item, frame: frame)
            }
            return
        }
        let mini = PreviewWindow(miniItem: item, frame: frame)
        mini.onExpand = {
            expandHoverPreview()
        }
        mini.onHoverChange = { inside in
            handleMiniHoverChange(inside)
        }
        popup.hoverPreviewPanel = mini
        mini.alphaValue = 0
        mini.orderFrontRegardless()
        mini.fadeIn(duration: 0.12)
        hoverPreviewEntryId = item.id
        hoverPreviewItem = item
    }

    func expandHoverPreview() {
        guard !hoverPreviewSuppressed else {
            closeHoverPreview()
            return
        }
        guard let popup = popupWindow,
              let mini = popup.hoverPreviewPanel,
              let item = hoverPreviewItem else { return }
        let expanded: ClipboardItem
        switch item {
        case .text:
            guard let full = fullTextItem(item) else {
                closeHoverPreview()
                showToast("内容加载失败，请重试", icon: "exclamationmark.triangle.fill")
                return
            }
            expanded = full
        case .image:
            expanded = item
        }
        cancelPendingHoverPreview()
        hoverPreviewHideTask?.cancel()
        hoverPreviewHideTask = nil
        sidePreviewAutoHideTask?.cancel()
        sidePreviewAutoHideTask = nil
        hoverPreviewEntryId = nil
        hoverPreviewItem = nil
        hoverPreviewSource = nil
        keyboardPreviewTargetId = nil
        popup.hoverPreviewPanel = nil
        popup.previewPanel = mini
        showPreview = true
        mini.onExpand = nil
        mini.onPaste = { self.pasteItem(id: $0) }
        mini.onClose = { self.closePreview() }
        mini.onDismiss = { self.closePreview() }
        mini.orderFrontRegardless()
        mini.expandToLarge(item: expanded, centerAt: NSPoint(x: popup.frame.midX, y: popup.frame.midY)) {
            NSApp.activate(ignoringOtherApps: true)
            mini.orderFrontRegardless()
            OnboardingGuide.shared.record(.previewed)
            OnboardingGuide.shared.refreshSpotlight()
        }
    }

    func handleMiniHoverChange(_ inside: Bool) {
        guard !showPreview else { return }
        if inside {
            cancelPendingHoverPreview()
            hoverPreviewHideTask?.cancel()
            hoverPreviewHideTask = nil
            sidePreviewAutoHideTask?.cancel()
            sidePreviewAutoHideTask = nil
        } else if let entryId = hoverPreviewEntryId {
            scheduleSidePreviewAutoHide(for: entryId)
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

    func closeHoverPreview(autoDismiss: Bool = false) {
        cancelPendingHoverPreview()
        hoverPreviewHideTask?.cancel()
        hoverPreviewHideTask = nil
        sidePreviewAutoHideTask?.cancel()
        sidePreviewAutoHideTask = nil
        hoverPreviewEntryId = nil
        hoverPreviewItem = nil
        hoverPreviewSource = nil
        keyboardPreviewTargetId = nil
        guard let mini = popupWindow?.hoverPreviewPanel else { return }
        popupWindow?.hoverPreviewPanel = nil
        if autoDismiss {
            mini.fadeOutAndClose(duration: 0.32, scale: 0.94, blur: 10.0)
        } else {
            mini.fadeOutAndClose()
        }
    }
}
