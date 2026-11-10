import SwiftUI

extension HistoryPopupContent {
    func switchToFilterTab(_ target: FilterMode) {
        let current = pendingFilterMode ?? filterMode
        guard target != current else { return }

        if target == filterMode {
            pendingFilterMode = nil
            filterSwitchGeneration &+= 1
            return
        }

        pendingFilterMode = target
        filterSwitchGeneration &+= 1
        let generation = filterSwitchGeneration
        scrollTarget = 0

        DispatchQueue.main.async {
            guard self.filterSwitchGeneration == generation,
                  self.pendingFilterMode == target else { return }
            self.filterMode = target
            self.pendingFilterMode = nil
        }
    }

    func matches(_ item: ClipboardItem, filterMode mode: FilterMode) -> Bool {
        switch mode {
        case .all: true
        case .favorites: backend.favoriteIds.contains(item.id)
        case .slots: backend.slotByEntryId[item.id] != nil
        case .image: item.isImage
        case .text: item.isText
        case .remarks: item.hasCustomLabel
        }
    }

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
