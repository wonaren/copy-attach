import SwiftUI

// MARK: - Tab Switching & Filtering

extension HistoryPopupContent {
    /// Switch to a specific filter tab. Rapid requests are coalesced before
    /// the next layout pass. The original row transition is enabled only for
    /// this one short update, then removed so it cannot accumulate state.
    func switchToFilterTab(_ target: FilterMode, animated: Bool) {
        guard target != filterMode else { return }
        filterSwitchGeneration &+= 1
        let generation = filterSwitchGeneration
        scrollTarget = selectedIndex > 0 ? listTopAnchorID : scrollTarget

        DispatchQueue.main.async {
            guard self.filterSwitchGeneration == generation,
                  target != self.filterMode else { return }
            guard animated else {
                self.animateFilterRows = false
                self.filterMode = target
                return
            }

            self.filterAnimationGeneration &+= 1
            let animationGeneration = self.filterAnimationGeneration
            self.animateFilterRows = true
            withAnimation(.easeOut(duration: 0.20)) {
                self.filterMode = target
            }

            // Transition state is useful only while the diff is settling. It
            // must not remain attached to the list between tab switches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard self.filterAnimationGeneration == animationGeneration else { return }
                self.animateFilterRows = false
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
