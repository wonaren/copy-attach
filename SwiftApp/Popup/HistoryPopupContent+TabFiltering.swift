import SwiftUI

// MARK: - Tab Switching & Filtering

extension HistoryPopupContent {
    /// Queues the latest requested tab for the next run-loop turn. The pending
    /// mode is part of the state machine so rapid gestures are composed from
    /// the latest request instead of repeatedly reading the old committed mode.
    /// The list updates immediately; only the count uses numeric text motion.
    func switchToFilterTab(_ target: FilterMode) {
        let current = pendingFilterMode ?? filterMode
        guard target != current else { return }

        // Reversing a queued switch cancels it instead of enqueueing a second
        // state change. This keeps a rapid left/right gesture lossless.
        if target == filterMode {
            pendingFilterMode = nil
            filterSwitchGeneration &+= 1
            return
        }

        pendingFilterMode = target
        filterSwitchGeneration &+= 1
        let generation = filterSwitchGeneration
        scrollTarget = selectedIndex > 0 ? listTopAnchorID : scrollTarget

        DispatchQueue.main.async {
            guard self.filterSwitchGeneration == generation,
                  self.pendingFilterMode == target else { return }
            self.filterMode = target
            self.pendingFilterMode = nil
        }
    }

    /// Whether an entry satisfies a filter tab's predicate. This is the single
    /// source of truth used by the display memo.
    func matches(_ item: ClipboardItem, filterMode mode: FilterMode) -> Bool {
        switch mode {
        case .all: true
        case .favorites: backend.favoriteIds.contains(item.id)
        case .image: item.isImage
        case .text: item.isText
        }
    }

    /// Shared tab switch used by the trackpad swipe and the ←/→ shortcuts:
    /// direction "left" = previous tab, "right" = next tab (same convention as
    /// the arrow keys).
    func switchFilterTab(direction: String) {
        let modes = FilterMode.allCases
        let current = pendingFilterMode ?? filterMode
        guard let idx = modes.firstIndex(of: current) else { return }
        let target: FilterMode
        if direction == "left" {
            guard idx > 0 else { return }
            target = modes[idx - 1]
        } else {
            guard idx < modes.count - 1 else { return }
            target = modes[idx + 1]
        }
        switchToFilterTab(target)
    }
}
