import AppKit
import SwiftUI

extension HistoryPopupContent {
    struct BatchDragPlan {
        let payload: ClipboardItem
        let items: [ClipboardItem]
        var count: Int { items.count }

    }

    func batchDragPlan(for item: ClipboardItem) -> BatchDragPlan? {
        guard PasteDeliveryMode.current == .keystroke else { return nil }
        let queue = PasteQueueManager.shared
        guard queue.hasItems,
              queue.isQueued(item),
              let payload = queue.queueItems.first else { return nil }
        return BatchDragPlan(payload: payload, items: queue.queueItems)
    }

    func dragProvider(item: ClipboardItem, batch: BatchDragPlan?) -> NSItemProvider {
        closeHoverPreview()
        popupWindow?.beginItemDrag()
        let richText = backend.sourceAppNeedsRichTextDrag
        if let batch {
            BatchDragController.shared.begin(items: batch.items)
            return ClipboardDragProvider.placeholderProvider()
        }
        BatchDragController.shared.cancel()
        return ClipboardDragProvider.provider(for: item, richText: richText)
    }

    var selectedItemId: Int? {
        guard selectedIndex > 0 else { return nil }
        let index = selectedIndex - 1
        guard index < displayItems.count else { return nil }
        return displayItems[index].id
    }

    func restoreSelection(_ id: Int?) {
        guard let id else { return }
        if let index = displayItems.firstIndex(where: { $0.id == id }) {
            selectedIndex = index + 1
        } else if selectedIndex > maxIndex {
            selectedIndex = max(0, maxIndex)
        }
    }

    func deleteItem(at index: Int) {
        let items = displayItems
        guard index < items.count else { return }
        let item = items[index]
        let anchorId = selectedItemId
        guard confirmUndoEvictionIfNeeded(for: item) else { return }
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        if editingItemId == item.id {
            editingItemId = nil
            editingText = ""
        }
        if popupWindow?.previewPanel?.itemId == item.id { closePreview() }
        if popupWindow?.hoverPreviewPanel?.itemId == item.id { closeHoverPreview() }
        let deleted = backend.deleteEntry(at: backendIdx)
        if deleted, !effectiveSearchText.isEmpty {
            searchResults.removeAll { $0.id == item.id }
        }
        guard deleted else { return }
        OnboardingGuide.shared.record(.deleted)
        if backend.items.isEmpty {
            selectedIndex = 0
            searchText = ""
        } else if anchorId == item.id {
            selectedIndex = min(index + 1, maxIndex)
        } else {
            restoreSelection(anchorId)
        }
    }

    func selectItem(at index: Int, asPath: Bool = false) {
        let items = displayItems
        guard index < items.count else { return }
        let item = items[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        backend.selectAndPasteDismissingPopup(at: backendIdx, asPath: asPath) {
            closePreview()
            onClose()
        }
        backend.restorePasteTargetFocus(force: true)
    }

    func pasteItem(id: Int) {
        guard let index = displayItems.firstIndex(where: { $0.id == id }) else {
            closePreview()
            showToast("内容已失效", icon: "exclamationmark.triangle.fill")
            return
        }
        selectItem(at: index)
    }

    func startPasteQueue() {
        guard !isDismissing, editingItemId == nil else { return }
        guard PasteQueueManager.shared.hasItems else {
            showToast("粘贴队列已空", icon: "exclamationmark.triangle.fill")
            return
        }
        guard PasteDeliveryMode.current == .keystroke else {
            showToast("当前为「仅复制到剪贴板」模式，无法顺序粘贴",
                      icon: "doc.on.clipboard")
            return
        }
        let outcome = PasteQueueManager.shared.startDispensing {
            closePreview()
            onClose()
            backend.restorePasteTargetFocus(force: true)
        }
        switch outcome {
        case .started:
            OnboardingGuide.shared.record(.queueStarted)
        case .eventTapUnavailable:
            showToast("无法接管 ⌘V，请检查辅助功能权限",
                      icon: "exclamationmark.triangle.fill")
        case .emptyQueue:
            showToast("粘贴队列已空", icon: "exclamationmark.triangle.fill")
        case .allEntriesStale:
            showToast("所选条目已失效，队列已清空",
                      icon: "exclamationmark.triangle.fill")
        }
    }

    func confirmUndoEvictionIfNeeded(for item: ClipboardItem) -> Bool {
        guard !Self.undoEvictionWarningDisabled else { return true }
        guard let evicted = backend.undoEvictionPreview(entryId: item.id), evicted > 0 else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "撤销记录将被清理"
        alert.informativeText = "继续删除后，\(evicted) 条撤销记录将无法恢复。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "继续删除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提醒"

        let popup = popupWindow
        popup?.isPresentingModalPanel = true
        defer { popup?.isPresentingModalPanel = false }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if let popup, popup.isVisible { popup.makeKey() }
        if alert.suppressionButton?.state == .on {
            Self.undoEvictionWarningDisabled = true
        }
        return response == .alertFirstButtonReturn
    }

    static var undoEvictionWarningDisabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.undoEvictionWarningKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.undoEvictionWarningKey) }
    }
    static let undoEvictionWarningKey = "UndoEvictionWarningDisabled"

    func performUndo() {
        guard backend.undoDepth() > 0 else { return }

        let perfUndo = PerfSpan.start("swift", "undo.perform")
        defer { perfUndo?.end() }
        let savedSearchText = searchText

        let restoredId = backend.undoDelete()
        guard restoredId > 0 else {
            searchText = savedSearchText
            return
        }

        OnboardingGuide.shared.record(.undone)
        let remaining = backend.undoDepth()
        if remaining > 0 {
            showToast("已恢复删除记录（还可撤销 \(remaining) 步）", icon: "arrow.uturn.backward.circle.fill")
        } else {
            showToast("已恢复删除记录", icon: "arrow.uturn.backward.circle.fill")
        }

        if !searchText.isEmpty {
            searchText = ""
        }

        DispatchQueue.main.async {
            guard let index = self.displayItems.firstIndex(where: { $0.id == restoredId }) else {
                self.selectedIndex = self.displayItems.isEmpty ? 0 : 1
                return
            }
            self.selectedIndex = index + 1
            self.scrollTarget = self.scrollTargetForItem(at: index)
        }
    }
}
