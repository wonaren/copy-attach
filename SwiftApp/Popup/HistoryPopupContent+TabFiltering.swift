import SwiftUI

// MARK: - Tab Switching & Filtering

extension HistoryPopupContent {
    /// Switch to a specific filter tab. Rapid requests are coalesced before
    /// the next layout pass. The list update stays immediate so LazyVStack
    /// does not retain transition graphs for every entering/leaving row.
    func switchToFilterTab(_ target: FilterMode, animated: Bool) {
        guard target != filterMode else { return }
        filterSwitchGeneration &+= 1
        let generation = filterSwitchGeneration
        scrollTarget = selectedIndex > 0 ? listTopAnchorID : scrollTarget

        DispatchQueue.main.async {
            guard self.filterSwitchGeneration == generation,
                  target != self.filterMode else { return }
            guard animated else {
                self.filterMode = target
                self.listTransitionOpacity = 1
                return
            }

            // Animate one composited list layer instead of every row. This
            // keeps the transition elegant while avoiding per-row retained
            // transition graphs and excessive GPU work during fast swipes.
            withAnimation(.easeOut(duration: 0.08)) {
                self.listTransitionOpacity = 0.72
            }
            self.filterMode = target
            DispatchQueue.main.async {
                guard self.filterSwitchGeneration == generation,
                      self.filterMode == target else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    self.listTransitionOpacity = 1
                }
            }
        }
    }

    /// Whether an entry satisfies a filter tab's predicate. Single source of
    /// truth for the filter definitions — the display memo
    /// (`HistoryPopupContent.currentDisplayMemo`) and the tab-switch
    /// measurement both derive from it, so they can't drift apart.
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
    func switchFilterTab(direction: String, animated: Bool) {
        let modes = FilterMode.allCases
        guard let idx = modes.firstIndex(of: filterMode) else { return }
        let target: FilterMode
        if direction == "left" {
            guard idx > 0 else { return }
            target = modes[idx - 1]
        } else {
            guard idx < modes.count - 1 else { return }
            target = modes[idx + 1]
        }
        switchToFilterTab(target, animated: animated)
    }
}
