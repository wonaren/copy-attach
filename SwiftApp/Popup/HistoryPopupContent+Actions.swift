import SwiftUI

// MARK: - Actions (delete / select / undo)

extension HistoryPopupContent {
    /// What a drag from a queued row carries.
    ///
    /// `payload` is always the queue's FIRST item, not the row the user grabbed:
    /// the badges promise "delivered in this order", so a drag from row ③ must
    /// still land ①②③ in that order. The remaining items follow through
    /// `BatchDispenseRunner` as synthesized keystrokes.
    struct BatchDragPlan {
        let payload: ClipboardItem
        let items: [ClipboardItem]
        var count: Int { items.count }

        /// The drop delivers NOTHING, for text and images alike.
        ///
        /// Measured on TextEdit and on Notes: a receiver SELECTS whatever the
        /// drop inserted (text: AX selection `loc=0 len=9` after a 9-byte drop;
        /// images: a dropped PNG stayed selected), so the next ⌘V of the batch
        /// REPLACED the dropped entry instead of appending after it — the first
        /// item of the batch disappeared. A batch therefore drags an empty
        /// placeholder and every entry arrives the same way, by ⌘V, in queue
        /// order. The `payload` stays here for the drag chip's label.
    }

    /// A batch drag happens only when the grabbed row is part of a queue with
    /// more than one item. Everything else — including a one-item queue — keeps
    /// today's single-item drag path untouched.
    func batchDragPlan(for item: ClipboardItem) -> BatchDragPlan? {
        // Batch dispatch is sequential ⌘V delivery; ClipboardOnly has no
        // keystroke to dispatch, so a drag falls back to the single-item path.
        guard PasteDeliveryMode.current == .keystroke else { return nil }
        let queue = PasteQueueManager.shared
        guard queue.totalCount > 1,
              queue.isQueued(item),
              let payload = queue.queueItems.first else { return nil }
        return BatchDragPlan(payload: payload, items: queue.queueItems)
    }

    /// Arms the drag and returns its payload provider. `batch != nil` means the
    /// whole queued set travels.
    ///
    /// `item` is the row's item captured at body-build time. The single-item
    /// path must use it, not `displayItems[index]`: a capture can prepend a row
    /// between the body pass and `.onDrag`, and re-indexing would drag a
    /// different entry than the one under the cursor.
    func dragProvider(forRow index: Int, item: ClipboardItem, batch: BatchDragPlan?) -> NSItemProvider {
        selectedIndex = index + 1
        popupWindow?.beginItemDrag()
        // Rich text is opt-in per source app: it breaks VS Code chat drops but is
        // required by 思源笔记 / Typora. See `sourceAppNeedsRichTextDrag`.
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
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        // The row is about to disappear: drop the inline editor first, otherwise
        // `editingItemId` would stay set with no row rendering a field, and every
        // popup shortcut is gated behind it being nil.
        if editingItemId == item.id {
            editingItemId = nil
            editingText = ""
        }
        closePreview()
        // The row's removal animates from the list's single
        // `.animation(value: backend.itemsGeneration)` (see
        // itemsListScrollView) — no `withAnimation` here, so this path cannot
        // fight that authority with a second, differently-tuned curve.
        let deleted = backend.deleteEntry(at: backendIdx)
        // When search is active, displayItems draws from the cached
        // searchResults snapshot; keep it in step with backend.items. Only
        // mutate on success, otherwise the in-memory cache desyncs.
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
        // Write the pasteboard first, dismiss the popup, and only then post the
        // paste keystroke — the panel must not be the key window when it
        // arrives (see `selectAndPasteDismissingPopup`).
        backend.selectAndPasteDismissingPopup(at: backendIdx, asPath: asPath) {
            closePreview()
            onClose()
        }
        // The popup is gone; hand the foreground back so the caret returns
        // to whatever the user was typing in.
        backend.restorePasteTargetFocus(force: true)
    }

    // MARK: - Undo

    /// Undo the most recent deletion. SwiftUI naturally animates the insertion
    /// via identity-based diffing on `\.element.id`.
    func performUndo() {
        guard backend.canUndo() else { return }

        let perfUndo = PerfSpan.start("swift", "undo.perform")
        defer { perfUndo?.end() }
        let savedSearchText = searchText

        // The restored row's insertion animates from the list's single
        // `.animation(value: backend.itemsGeneration)` (see itemsListScrollView)
        // — the previous local `withAnimation` is gone so there is exactly one
        // authority for row enter/leave motion.
        let success = backend.undoDelete()
        guard success else {
            // Undo failed (DB error, entry gone, etc.). CanUndo returned true but
            // by the time we popped the stack something went wrong.
            // Restore search text — don't leave the user in a changed state.
            searchText = savedSearchText
            return
        }

        OnboardingGuide.shared.record(.undone)
        showToast("已恢复删除记录", icon: "arrow.uturn.backward.circle.fill")

        // Clear search only on success so the user sees the restored item
        if !searchText.isEmpty {
            searchText = ""
        }

        // Set selection to first item. Must happen AFTER searchText is cleared
        // so selectedIndex is not immediately overwritten by onChange(of: searchText)
        // which sets selectedIndex = 0.
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
