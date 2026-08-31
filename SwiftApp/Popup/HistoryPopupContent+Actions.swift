import SwiftUI

// MARK: - Actions (delete / select / undo)

extension HistoryPopupContent {
    func deleteItem(at index: Int) {
        let items = displayItems
        guard index < items.count else { return }
        let item = items[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        closePreview()
        var deleted = false
        withAnimation(.easeInOut(duration: 0.2)) {
            deleted = backend.deleteEntry(at: backendIdx)
            // When search is active, displayItems draws from the cached
            // searchResults snapshot. Mutate it inside the animation block
            // so the item removal animates with the same transition.
            // Only mutate searchResults when the delete actually succeeded,
            // otherwise the in-memory cache desyncs from backend.items.
            if deleted, !effectiveSearchText.isEmpty {
                searchResults.removeAll { $0.id == item.id }
            }
        }
        guard deleted else { return }
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
        if backend.selectAndPaste(at: backendIdx, asPath: asPath) {
            closePreview()
            onClose()
        }
    }

    // MARK: - Undo

    /// Undo the most recent deletion. SwiftUI naturally animates the insertion
    /// via identity-based diffing on `\.element.id`.
    func performUndo() {
        guard backend.canUndo() else { return }

        let savedSearchText = searchText

        let success = withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            backend.undoDelete()
        }
        guard success else {
            // Undo failed (DB error, entry gone, etc.). CanUndo returned true but
            // by the time we popped the stack something went wrong.
            // Restore search text — don't leave the user in a changed state.
            searchText = savedSearchText
            return
        }

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
