import SwiftUI

// MARK: - Tab Switching & Filtering

extension HistoryPopupContent {
    /// Adaptive filter-switch motion: the duration scales with how much of the
    /// list actually changes. A near-identical refilter stays snappy (0.15s);
    /// a big one — many rows dissolving and/or materializing — gets up to
    /// 0.28s. The control feedback (tab pill) snaps instantly and the swipe
    /// commits mid-gesture, so the content animation reads as readable, not
    /// as lag — a fixed short duration makes fade-heavy switches (e.g. 图片 →
    /// 文本, where rows materialize into mostly-empty space and there is
    /// little collapse motion to anchor perception) read as instant.
    private func filterSwitchAnimation(removed: Int, added: Int) -> Animation {
        let visibleChange = min(removed, filterSwitchChangeCap) + min(added, filterSwitchChangeCap)
        let duration = min(filterSwitchMaxDuration,
                           filterSwitchBaseDuration + filterSwitchPerChange * Double(visibleChange))
        return .easeOut(duration: duration)
    }

    /// Switch to a specific filter tab. The tabs re-filter the same data pool,
    /// so this is a simple identity-preserving diff: `withAnimation` animates
    /// row removals/insertions (`filterRowTransition`) and the layout collapse,
    /// while surviving rows never leave their identity. The duration adapts to
    /// the measured change (see `filterSwitchAnimation(removed:added:)`).
    func switchToFilterTab(_ target: FilterMode, animated: Bool) {
        guard target != filterMode else { return }
        // Scroll to the top BEFORE switching the filter. A scroll issued in
        // the same transaction as the content change races the LazyVStack's
        // row-height estimation and the scroll view's offset-preservation
        // (the list shrinks under a deep viewport), and can be lost or land
        // off-target. The anchor is an always-laid-out view at offset 0, so
        // this scroll is exact; once the viewport sits at the top, the
        // filter change has no offset to preserve and lands clean.
        if selectedIndex > 0 {
            scrollTarget = listTopAnchorID
        }
        let (removed, added) = countFilterChange(from: filterMode, to: target)
        // Switch on the next runloop turn so the scroll lands (a layout
        // pass) before the content changes.
        DispatchQueue.main.async {
            if animated {
                withAnimation(filterSwitchAnimation(removed: removed, added: added)) {
                    filterMode = target
                }
            } else {
                filterMode = target
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

    /// Rows that leave (removed) and enter (added) the list when switching
    /// from `source` to `target`, counted in a single pass over the base with
    /// early exit once both saturate at `filterSwitchChangeCap` (the animation
    /// caps both counts anyway). Replaces the previous two full `Set` builds
    /// per switch, which ran synchronously on the swipe/key/tap path.
    private func countFilterChange(from source: FilterMode, to target: FilterMode) -> (removed: Int, added: Int) {
        let base = effectiveSearchText.isEmpty ? backend.items : searchResults
        var removed = 0
        var added = 0
        for item in base {
            let inSource = matches(item, filterMode: source)
            let inTarget = matches(item, filterMode: target)
            if inSource != inTarget {
                if inSource { removed += 1 } else { added += 1 }
                if removed >= filterSwitchChangeCap, added >= filterSwitchChangeCap { break }
            }
        }
        return (removed, added)
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
