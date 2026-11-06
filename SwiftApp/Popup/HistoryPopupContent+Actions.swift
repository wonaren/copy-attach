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
        guard queue.totalCount > 1,
              queue.isQueued(item),
              let payload = queue.queueItems.first else { return nil }
        return BatchDragPlan(payload: payload, items: queue.queueItems)
    }

    func dragProvider(forRow index: Int, item: ClipboardItem, batch: BatchDragPlan?) -> NSItemProvider {
        selectedIndex = index + 1
        popupWindow?.beginItemDrag()
        let richText = backend.sourceAppNeedsRichTextDrag
        if let batch {
            BatchDragController.shared.begin(items: batch.items)
            return ClipboardDragProvider.placeholderProvider()
        }
        BatchDragController.shared.cancel()
        return ClipboardDragProvider.provider(for: item, richText: richText)
    }

    func deleteItem(at index: Int) {
        let items = displayItems
        guard index < items.count else { return }
        let item = items[index]
        guard confirmUndoEvictionIfNeeded(for: item) else { return }
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        if editingItemId == item.id {
            editingItemId = nil
            editingText = ""
        }
        closePreview()
        let deleted = backend.deleteEntry(at: backendIdx)
        if deleted, !effectiveSearchText.isEmpty {
            searchResults.removeAll { $0.id == item.id }
        }
        guard deleted else { return }
        OnboardingGuide.shared.record(.deleted)
        if backend.items.isEmpty {
            selectedIndex = 0
            searchText = ""
        } else if selectedIndex > maxIndex {
            selectedIndex = max(0, maxIndex)
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

        let success = backend.undoDelete()
        guard success else {
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
            if self.displayItems.isEmpty {
                self.selectedIndex = 0
            } else {
                self.selectedIndex = 1
                self.scrollTarget = self.scrollTargetForItem(at: 0)
            }
        }
    }
}
