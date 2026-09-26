import SwiftUI

// MARK: - Actions (delete / select / undo)

extension HistoryPopupContent {
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
