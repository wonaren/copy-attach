import AppKit
import SwiftUI

// MARK: - Filter Mode

enum FilterMode: String, CaseIterable {
    case favorites
    case all
    case image
    case text

    var icon: String {
        switch self {
        case .favorites: return "star.fill"
        case .all: return "line.3.horizontal"
        case .image: return "photo"
        case .text: return "doc.text"
        }
    }
}

// MARK: - Popup Row (item or date separator)

/// A row in the flattened list stream. `selectedIndex` indexes into the real
/// items only, so separators never occupy a selectable position.
private enum PopupRow: Identifiable {
    case separator(timestamp: UInt64, isFirst: Bool)
    case item(index: Int, item: ClipboardItem)

    var id: Int {
        switch self {
        case .separator(let timestamp, _):
            // Negative ids: -timestamp-1 so id is never 0 and always
            // distinct from positive entry_ids. (timestamp=0 → -1)
            return -Int(Int64(bitPattern: timestamp)) - 1
        case .item(_, let item):
            return item.id
        }
    }
}

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0  // 0 = search bar, 1+ = items
    @State private var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var isCommandPressed: Bool = false
    @Environment(\.appTheme) private var theme
    @State private var searchText: String = ""
    @State private var effectiveSearchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var scrollTarget: Int?

    @State private var filterMode: FilterMode = .all

    // Spotlight opening animation: start slightly larger, spring in
    @State private var openingScale: CGFloat = 1.10

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isContainerFocused: Bool

    /// Cached search results, computed off the main thread in the debounce task.
    /// When effectiveSearchText is empty, the view uses backend.items directly.
    @State private var searchResults: [ClipboardItem] = []

    /// Items to display: full history when idle, cached results when searching.
    /// Sorted by timestamp descending so day separators receive a monotonic stream.
    private var displayItems: [ClipboardItem] {
        let base = effectiveSearchText.isEmpty ? backend.items : searchResults
        let filtered = switch filterMode {
        case .all: base
        case .favorites: base.filter { backend.favoriteIds.contains($0.id) }
        case .image: base.filter { $0.isImage }
        case .text: base.filter { $0.isText }
        }
        return filtered.sorted { $0.timestamp > $1.timestamp }
    }

    /// The highest valid selectedIndex (search bar + item count).
    private var maxIndex: Int { displayItems.count }

    // Design Tokens
    private let popupWidth: CGFloat = 500
    private let popupHeight: CGFloat = 720

    private var popupWindow: HistoryPopupWindow? {
        NSApp.windows.first(where: { $0 is HistoryPopupWindow }) as? HistoryPopupWindow
    }

    var body: some View {
        ZStack {
            // === Layer 0: Dark Translucent Background (HUD look) ===
            theme.popupBackground
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            // === Layer 1: Content ===
            if backend.items.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 4) {
                    searchField
                        .padding(.horizontal, 5)
                        .padding(.top, 6)

                    filterModeTabs
                        .padding(.horizontal, 5)

                    if displayItems.isEmpty && !effectiveSearchText.isEmpty {
                        noResultsView
                    } else if displayItems.isEmpty && filterMode == .favorites {
                        emptyFavoritesView
                    } else if displayItems.isEmpty && filterMode == .image {
                        emptyImageView
                    } else if displayItems.isEmpty && filterMode == .text {
                        emptyTextView
                    } else {
                        itemsList
                        bottomBar
                    }
                }
                .padding(.all, 3)
            }
        }
        .scaleEffect(openingScale, anchor: .center)
        .frame(width: popupWidth, height: popupHeight)
        .focusable()
        .focusEffectDisabled()
        .focused($isContainerFocused)
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < maxIndex {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if showPreview {
                closePreview()
            } else {
                searchText = ""
                onClose()
            }
            return .handled
        }
        .onKeyPress(.space) {
            if selectedIndex == 0 { return .ignored }
            togglePreview()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard selectedIndex > 0 else { return .ignored }
            let modes = FilterMode.allCases
            if let idx = modes.firstIndex(of: filterMode), idx > 0 {
                filterMode = modes[idx - 1]
                selectedIndex = min(selectedIndex, maxIndex)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard selectedIndex > 0 else { return .ignored }
            let modes = FilterMode.allCases
            if let idx = modes.firstIndex(of: filterMode), idx < modes.count - 1 {
                filterMode = modes[idx + 1]
                selectedIndex = min(selectedIndex, maxIndex)
            }
            return .handled
        }
        .onAppear {
            selectedIndex = backend.items.isEmpty ? 0 : 1
            searchText = ""
            isControlPressed = NSEvent.modifierFlags.contains(.control)
            isCommandPressed = NSEvent.modifierFlags.contains(.command)

            // Spotlight opening: spring scale with slight overshoot
            let animDuration = 0.3
            withAnimation(.spring(response: animDuration * 0.7,
                                  dampingFraction: 0.62,
                                  blendDuration: 0)) {
                openingScale = 1.0
            }

            // Sync window alpha fade with the SwiftUI scale animation,
            // so the entire window (including shadow) appears as one unit.
            if let w = popupWindow {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = animDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    w.animator().alphaValue = 1
                }
            }

            // Focus first item (or search bar if empty) after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + animDuration + 0.05) {
                if self.backend.items.isEmpty {
                    // Empty state: focus container so onKeyPress (e.g. Escape)
                    // works even without a search field or items.
                    self.isContainerFocused = true
                } else if self.selectedIndex == 0 {
                    self.isSearchFocused = true
                } else {
                    self.isContainerFocused = true
                }
            }
        }
        .onDisappear {
            closePreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: controlKeyNotification)) { note in
            let pressed = (note.object as? Bool) ?? NSEvent.modifierFlags.contains(.control)
            if pressed != isControlPressed {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isControlPressed = pressed
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: deleteKeyNotification)) { _ in
            // When the search bar is focused (selectedIndex == 0), delete the
            // first visible item in the filtered results so ⌃⌫ still works
            // while the user is typing a search query.
            let itemIndex: Int
            if selectedIndex > 0 {
                itemIndex = selectedIndex - 1
            } else if !displayItems.isEmpty {
                itemIndex = 0
            } else {
                return
            }
            deleteItem(at: itemIndex)
        }
        .onReceive(NotificationCenter.default.publisher(for: commandKeyNotification)) { note in
            let pressed = (note.object as? Bool) ?? NSEvent.modifierFlags.contains(.command)
            if pressed != isCommandPressed {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCommandPressed = pressed
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: commandNumberNotification)) { note in
            guard let number = note.object as? Int,
                  number >= 1 && number <= displayItems.count else { return }
            selectItem(at: number - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: focusSearchNotification)) { _ in
            selectedIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: focusSearchAndBackspaceNotification)) { _ in
            // Plain Delete pressed while an item is selected (not the search
            // bar): focus search and remove the last character. PopupHostingView
            // intercepts this at the AppKit level before NSHostingView can
            // consume the delete key internally.
            selectedIndex = 0
            if !searchText.isEmpty {
                searchText.removeLast()
            }
            // NSTextField auto-selects all text on focus gain. The onChange(of:
            // selectedIndex) above tries to move the cursor but runs before the
            // NSTextView becomes first responder. Fix it here after the focus
            // transfer and text mutation have settled in the next render pass.
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                   editor.isEditable {
                    let end = editor.string.count
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: undoKeyNotification)) { _ in
            performUndo()
        }
        .onReceive(NotificationCenter.default.publisher(for: favoriteToggleNotification)) { _ in
            if selectedIndex > 0 {
                let itemIdx = selectedIndex - 1
                if itemIdx < displayItems.count {
                    let item = displayItems[itemIdx]
                    backend.toggleFavorite(item.id)
                }
            }
            // Reclamp after favorites change: displayItems may have shrunk
            if selectedIndex > maxIndex {
                selectedIndex = max(0, maxIndex)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: arrowKeyFromSearchNotification)) { note in
            guard let direction = note.object as? String else { return }
            let modes = FilterMode.allCases
            if let idx = modes.firstIndex(of: filterMode) {
                if direction == "left" && idx > 0 {
                    filterMode = modes[idx - 1]
                } else if direction == "right" && idx < modes.count - 1 {
                    filterMode = modes[idx + 1]
                }
            }
        }
        .onChange(of: filterMode) { _, _ in
            closePreview()
            if selectedIndex > maxIndex {
                selectedIndex = max(0, maxIndex)
            }
            scrollTarget = scrollTargetForItem(at: 0)
        }
        .onChange(of: searchText) { _, newValue in
            selectedIndex = 0
            searchTask?.cancel()
            if newValue.isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    effectiveSearchText = ""
                }
                searchResults = []
                scrollTarget = scrollTargetForItem(at: 0)
                return
            }

            // Longer debounce for CJK: IME produces intermediate characters
            // rapidly (pinyin syllables, tone marks, candidates), so fewer
            // filter passes reduce main-thread jank from Unicode normalization.
            let hasCJK = newValue.unicodeScalars.contains { $0.value > 0x2E80 }
            let debounceNs: UInt64 = hasCJK ? 150_000_000 : 80_000_000

            searchTask = Task { [items = backend.items] in
                try? await Task.sleep(nanoseconds: debounceNs)
                guard !Task.isCancelled else { return }

                // localizeCaseInsensitiveContains for CJK is 10-50× slower
                // than ASCII — compute off the main thread.
                let filtered = await Task.detached(priority: .userInitiated) { [items] in
                    items.filter {
                        $0.label.localizedCaseInsensitiveContains(newValue) ||
                        $0.sourceName.localizedCaseInsensitiveContains(newValue) ||
                        $0.fullText.localizedCaseInsensitiveContains(newValue) ||
                        DayGroup.label(for: $0.timestamp)
                            .localizedCaseInsensitiveContains(newValue)
                    }
                }.value

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        effectiveSearchText = newValue
                        searchResults = filtered
                    }
                    if selectedIndex == 0 {
                        scrollTarget = scrollTargetForItem(at: 0)
                    }
                }
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            if newValue == 0 && !backend.items.isEmpty {
                isSearchFocused = true
                isContainerFocused = false
                // Move cursor to end — NSTextField selects all on focus by default.
                // This runs synchronously before the keyDown re-dispatch, so the
                // character lands at the correct position.
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    let end = editor.string.count
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            } else {
                isSearchFocused = false
                isContainerFocused = true
            }
        }
    }

    // MARK: - Search Field (item 0)

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.popupDimText)

            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: 12.5))
                .foregroundColor(theme.popupPrimaryText)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.popupDimText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.popupSearchBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    selectedIndex == 0
                        ? Color(nsColor: .controlAccentColor)
                        : theme.popupRowHover,
                    lineWidth: selectedIndex == 0 ? 2.5 : 1
                )
        )
        .onTapGesture {
            selectedIndex = 0
            isSearchFocused = true
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(theme.popupDimText)
            Text("无匹配结果")
                .font(.system(size: 14))
                .foregroundColor(theme.popupDimText)
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Filter Mode Tabs

    private var filterModeTabs: some View {
        HStack(spacing: 8) {
            ForEach(FilterMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        filterMode = mode
                    }
                }) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 13, weight: .medium))
                        .frame(height: 16)
                        .foregroundColor(mode == filterMode
                            ? Color(nsColor: .controlAccentColor)
                            : theme.popupDimText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mode == filterMode
                                    ? Color(nsColor: .controlAccentColor).opacity(0.15)
                                    : theme.popupFilterTabBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    mode == filterMode
                                        ? Color(nsColor: .controlAccentColor).opacity(0.3)
                                        : theme.popupFilterTabBackground,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var emptyFavoritesView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "star.slash")
                .font(.system(size: 28))
                .foregroundColor(theme.popupDimText)
            Text("暂无收藏")
                .font(.system(size: 14))
                .foregroundColor(theme.popupDimText)
            Spacer()
        }
        .transition(.opacity)
    }

    private var emptyImageView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundColor(theme.popupDimText)
            Text("暂无图片")
                .font(.system(size: 14))
                .foregroundColor(theme.popupDimText)
            Spacer()
        }
        .transition(.opacity)
    }

    private var emptyTextView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundColor(theme.popupDimText)
            Text("暂无文本")
                .font(.system(size: 14))
                .foregroundColor(theme.popupDimText)
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Preview Management

    private func togglePreview() {
        if showPreview { closePreview() } else { openPreview() }
    }

    private func openPreview() {
        let itemIndex = selectedIndex - 1
        guard itemIndex < displayItems.count, let popup = popupWindow else { return }
        let item = displayItems[itemIndex]
        let popupCenter = NSPoint(x: popup.frame.midX, y: popup.frame.midY)
        guard let previewItem = fullTextItem(item) else { return }
        let preview = PreviewWindow(item: previewItem, centerAt: popupCenter)
        popup.previewPanel = preview
        preview.orderFront(nil)
        showPreview = true
    }

    private func closePreview() {
        guard showPreview else { return }
        showPreview = false
        popupWindow?.previewPanel?.close()
        popupWindow?.previewPanel = nil
    }

    private func updatePreviewContent() {
        let itemIndex = selectedIndex - 1
        guard showPreview, itemIndex >= 0, itemIndex < displayItems.count,
              let preview = popupWindow?.previewPanel else { return }
        guard let previewItem = fullTextItem(displayItems[itemIndex]) else {
            closePreview()
            return
        }
        preview.updateContent(item: previewItem)
    }

    private func fullTextItem(_ item: ClipboardItem) -> ClipboardItem? {
        switch item {
        case .text(let entryId, _, let timestamp, let label, let sourceName, let sourceBundleId, _):
            guard let full = ClipboardBackend.shared.getTextByEntryId(entryId) else {
                debugLog("fullTextItem: failed to load full text for entry \(entryId)")
                return nil
            }
            return .text(entryId: entryId, text: full, timestamp: timestamp,
                         label: label, sourceName: sourceName, sourceBundleId: sourceBundleId, fullText: full)
        default:
            return item
        }
    }

    // MARK: - Bottom Bar (item count + shortcuts, single row)

    private var bottomBar: some View {
        let items = displayItems
        return HStack(spacing: 0) {
            // --- Left: item count stats ---
            Text("\(items.count) 项")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.popupSecondaryText)
            if !effectiveSearchText.isEmpty {
                Text("/ \(backend.items.count) 项")
                    .font(.system(size: 10))
                    .foregroundColor(theme.popupMutedText)
            }
            Text(" · ")
                .font(.system(size: 10))
                .foregroundColor(theme.popupDimText)
            let textCount = items.filter { $0.isText }.count
            let imageCount = items.filter { $0.isImage }.count
            Text("\(textCount) 文本")
                .font(.system(size: 10))
                .foregroundColor(theme.popupMutedText)
            Text("\(imageCount) 图片")
                .font(.system(size: 10))
                .foregroundColor(theme.popupMutedText)

            Spacer()

            // --- Right: shortcut hints ---
            shortcutHint(key: "⌥P", label: "收藏/取消")
            shortcutHint(key: "Space", label: "预览")
            shortcutHint(key: "⌃⌫", label: "删除")
            shortcutHint(key: "⌘Z", label: "撤销")
            shortcutHint(key: "⌘1~9", label: "快速选择")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.popupMutedText)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(theme.popupDimText)
        }
        .padding(.leading, 4)
    }

    // MARK: - Items List

    @ViewBuilder
    private var itemsList: some View {
        itemsListScrollView
            .scrollPosition(id: $scrollTarget)
            .onChange(of: selectedIndex) { _, newValue in
                if newValue == 0 {
                    if showPreview { closePreview() }
                    // Don't set scrollTarget here — the searchText onChange
                    // handler sets it after the debounced search is applied.
                    // Setting it now would scroll to pre-search item 0 first,
                    // then correct 80ms later, causing visible flicker.
                    return
                }
                let itemIndex = newValue - 1
                if itemIndex < displayItems.count {
                    scrollTarget = scrollTargetForItem(at: itemIndex)
                }
                updatePreviewContent()
            }
    }

    private var itemsListScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(popupRows, id: \.id) { row in
                    switch row {
                    case .separator(let timestamp, let isFirst):
                        DateSeparatorView(timestamp: timestamp)
                            .padding(.top, isFirst ? 2 : 8)
                            .padding(.bottom, 1)
                            .transition(.opacity)
                            .id(row.id)
                    case .item(let index, let item):
                        let shortcut: String? = isCommandPressed && index < 9 ? "⌘\(index + 1)" : nil
                        ItemRowView(
                            item: item,
                            isSelected: selectedIndex == index + 1,
                            isDeleteModifierPressed: isControlPressed,
                            shortcutHint: shortcut,
                            isFavorite: backend.favoriteIds.contains(item.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let itemIdx = index + 1
                            if selectedIndex == itemIdx {
                                selectItem(at: index)
                            } else {
                                selectedIndex = itemIdx
                            }
                        }
                        .id(item.id)
                        .transition(.opacity)
                    }
                }
            }
            .padding(.all, 2)
        }
        .background(theme.popupRowDefault)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.popupRowBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Flattens `displayItems` into a row stream, inserting a `DateSeparatorView`
    /// before any item whose calendar day differs from the preceding item's.
    /// Separators are purely visual — they carry no selection index, so
    /// `selectedIndex` keeps mapping to real item positions (index + 1).
    private var popupRows: [PopupRow] {
        var rows: [PopupRow] = []
        var prevDay: UInt64? = nil
        for (index, item) in displayItems.enumerated() {
            let needsSeparator = prevDay.map { !DayGroup.isSameDay($0, item.timestamp) } ?? true
            if needsSeparator {
                rows.append(.separator(timestamp: item.timestamp, isFirst: prevDay == nil))
            }
            rows.append(.item(index: index, item: item))
            prevDay = item.timestamp
        }
        return rows
    }

    /// Returns the id to target for `scrollPosition` so that both the item at
    /// `itemIndex` and any date separator above it are visible after the scroll.
    private func scrollTargetForItem(at itemIndex: Int) -> Int? {
        let items = displayItems
        guard itemIndex >= 0, itemIndex < items.count else { return nil }
        let hasSeparator = itemIndex == 0
            || !DayGroup.isSameDay(items[itemIndex - 1].timestamp, items[itemIndex].timestamp)
        if hasSeparator {
            return -Int(Int64(bitPattern: items[itemIndex].timestamp)) - 1
        }
        return items[itemIndex].id
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 44))
                .foregroundColor(theme.popupDimText)
            Text("剪贴板记录为空")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.popupPrimaryText)
            Text("复制文本或图片后将自动出现在这里")
                .font(.system(size: 12))
                .foregroundColor(theme.popupMutedText)
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func deleteItem(at index: Int) {
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

    private func selectItem(at index: Int) {
        let items = displayItems
        guard index < items.count else { return }
        let item = items[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        if backend.selectAndPaste(at: backendIdx) {
            closePreview()
            onClose()
        }
    }

    // MARK: - Undo

    /// Undo the most recent deletion. SwiftUI naturally animates the insertion
    /// via identity-based diffing on `\.element.id`.
    private func performUndo() {
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
