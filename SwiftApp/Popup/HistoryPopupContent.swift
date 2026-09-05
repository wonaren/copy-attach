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

/// A row in the flattened list; separators are not selectable.
private enum PopupRow: Identifiable {
    case separator(timestamp: UInt64, isFirst: Bool)
    case item(index: Int, item: ClipboardItem)

    var id: Int {
        switch self {
        case .separator(let timestamp, _):
            // Stable across filters: changing the first entry of a day must
            // not replace or animate the date separator itself.
            return DayGroup.separatorID(for: timestamp)
        case .item(_, let item):
            return item.id
        }
    }
}

// MARK: - Right-Click Context Menu Support

/// One-shot preference for row frames while resolving a right-click.
private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Retains a closure for the lifetime of an NSMenuItem.
final class ContextMenuItemTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    // `invoke:` avoids colliding with NSObject's `performSelector:` bridging.
    @objc(invoke:) func invoke(_ sender: Any?) { action() }
}

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @State var backend = ClipboardBackend.shared
    @State var selectedIndex: Int = 0  // 0 = search bar, 1+ = items
    @State var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var isCommandPressed: Bool = false
    @Environment(\.appTheme) var theme
    @State var searchText: String = ""
    @State var effectiveSearchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State var scrollTarget: Int?
    /// Zero-height anchor at the top of the list for reliable scroll-to-top.
    let listTopAnchorID = 0

    @State var filterMode: FilterMode = .all
    /// Latest requested mode while a switch is waiting for the next run loop.
    @State var pendingFilterMode: FilterMode?
    /// Invalidates queued tab switches so a fast gesture produces one render.
    @State var filterSwitchGeneration = 0

    /// True while a right-click is waiting for the one-shot row-frame snapshot.
    @State var contextMenuArmed = false
    @State var pendingContextMenuRequest: PopupContextMenuRequest?

    @Namespace private var selectionNamespace

    @State private var openingScale: CGFloat = 1.10

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isContainerFocused: Bool

    /// Cached search results from the debounce task.
    @State var searchResults: [ClipboardItem] = []
    /// Bumped whenever `searchResults` is replaced, to invalidate the display memo.
    @State private var searchResultsGeneration = 0

    // MARK: - Display-list memo
    //
    // Memoize derived rows/counts per data generation to avoid repeated O(n)
    // passes on every body evaluation.

    private struct DisplayMemo {
        let itemsGeneration: Int
        let effectiveSearchText: String
        let searchResultsGeneration: Int
        let filterMode: FilterMode
        /// Start of the current calendar day (invalidates memo at midnight).
        let startOfToday: Date
        let items: [ClipboardItem]   // filter + timestamp-sorted
        let rows: [PopupRow]         // flattened with day separators
        let textCount: Int
        let imageCount: Int
    }

    private final class DisplayMemoBox {
        var memo: DisplayMemo?
    }

    @State private var displayMemoBox = DisplayMemoBox()

    /// The memoized derived list for the current (data, search, filter, day).
    private var currentDisplayMemo: DisplayMemo {
        let today = Calendar.current.startOfDay(for: Date())
        if let memo = displayMemoBox.memo,
           memo.itemsGeneration == backend.itemsGeneration,
           memo.effectiveSearchText == effectiveSearchText,
           memo.searchResultsGeneration == searchResultsGeneration,
           memo.filterMode == filterMode,
           memo.startOfToday == today {
            return memo
        }
        let base = effectiveSearchText.isEmpty ? backend.items : searchResults
        let sorted: [ClipboardItem]
        if filterMode == .all {
            sorted = base.sorted { $0.timestamp > $1.timestamp }
        } else {
            sorted = base
                .filter { matches($0, filterMode: filterMode) }
                .sorted { $0.timestamp > $1.timestamp }
        }
        var rows: [PopupRow] = []
        rows.reserveCapacity(sorted.count * 2)
        var prevDay: UInt64?
        var textCount = 0
        for (index, item) in sorted.enumerated() {
            let needsSeparator = prevDay.map { !DayGroup.isSameDay($0, item.timestamp) } ?? true
            if needsSeparator {
                rows.append(.separator(timestamp: item.timestamp, isFirst: prevDay == nil))
            }
            rows.append(.item(index: index, item: item))
            prevDay = item.timestamp
            if item.isText { textCount += 1 }
        }
        let memo = DisplayMemo(itemsGeneration: backend.itemsGeneration,
                               effectiveSearchText: effectiveSearchText,
                               searchResultsGeneration: searchResultsGeneration,
                               filterMode: filterMode,
                               startOfToday: today,
                               items: sorted,
                               rows: rows,
                               textCount: textCount,
                               imageCount: sorted.count - textCount)
        displayMemoBox.memo = memo
        return memo
    }

    /// Items to display: full history when idle, cached results when searching.
    /// Sorted by timestamp descending so day separators receive a monotonic stream.
    var displayItems: [ClipboardItem] { currentDisplayMemo.items }

    /// The highest valid selectedIndex (search bar + item count).
    var maxIndex: Int { displayItems.count }

    // Design Tokens
    private let popupWidth: CGFloat = 500
    private let popupHeight: CGFloat = 720

    var popupWindow: HistoryPopupWindow? {
        NSApp.windows.first(where: { $0 is HistoryPopupWindow }) as? HistoryPopupWindow
    }

    var body: some View {
        ZStack {
            theme.popupBackground
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if backend.items.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 4) {
                    searchField
                        .padding(.horizontal, 5)
                        .padding(.top, 6)

                    filterModeTabs
                        .padding(.horizontal, 5)

                    filterPageContent
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
        .onKeyPress(keys: [.return], phases: .down) { press in
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1, asPath: press.modifiers.contains(.shift))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .onKeyPress(.space) {
            if selectedIndex == 0 { return .ignored }
            togglePreview()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "left")
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "right")
            return .handled
        }
        .onAppear {
            // Reset transient state in place; the hosting view is reused across sessions.
            selectedIndex = backend.items.isEmpty ? 0 : 1
            searchText = ""
            effectiveSearchText = ""
            searchResults = []
            searchResultsGeneration &+= 1
            searchTask?.cancel()
            searchTask = nil
            filterMode = .all
            pendingFilterMode = nil
            filterSwitchGeneration &+= 1
            showPreview = false
            scrollTarget = nil
            contextMenuArmed = false
            pendingContextMenuRequest = nil
            displayMemoBox.memo = nil
            openingScale = 1.10
            isControlPressed = NSEvent.modifierFlags.contains(.control)
            isCommandPressed = NSEvent.modifierFlags.contains(.command)

            // Spotlight opening: scale 1.10 → 1.0 with a spring that settles in
            // the same ~0.2s window as the window alpha fade (see
            // HistoryPopupWindow.fadeInDuration). Damping 0.85 keeps the scale
            // from visibly overshooting — Spotlight settles smoothly, no bounce.
            let openDuration = 0.2
            withAnimation(.spring(response: openDuration,
                                  dampingFraction: 0.85,
                                  blendDuration: 0)) {
                openingScale = 1.0
            }

            // Focus first item (or search bar if empty) after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + openDuration + 0.05) {
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
        .onReceive(NotificationCenter.default.publisher(for: escapeKeyNotification)) { _ in
            handleEscape()
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
        .onReceive(NotificationCenter.default.publisher(for: popupContextMenuNotification)) { note in
            guard let request = note.object as? PopupContextMenuRequest else { return }
            // Arm the one-shot frame snapshot: rows report their frames on the
            // next layout pass, and the preference callback resolves the row
            // under the cursor. Frames are measured on demand (right-click
            // only) instead of continuously, so scrolling never pays per-row
            // geometry reporting.
            pendingContextMenuRequest = request
            contextMenuArmed = true
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
            switchFilterTab(direction: direction)
        }
        .onReceive(NotificationCenter.default.publisher(for: popupSwipeNotification)) { note in
            guard let direction = note.object as? String else { return }
            switchFilterTab(direction: direction)
        }
        .onChange(of: filterMode) { _, newMode in
            closePreview()
            // A tab switch re-anchors the selection to the new list's first
            // row. The list transition is a single composited fade, not a
            // transition per row, so a large history stays cheap to render.
            if selectedIndex != 0 {
                selectedIndex = displayItems.isEmpty ? 0 : 1
                guard !displayItems.isEmpty else { return }
                DispatchQueue.main.async {
                    guard self.filterMode == newMode, self.selectedIndex > 0 else { return }
                    self.scrollTarget = self.scrollTargetForItem(at: 0)
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            selectedIndex = 0
            searchTask?.cancel()
            if newValue.isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    effectiveSearchText = ""
                }
                searchResults = []
                searchResultsGeneration &+= 1
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

                // Full-text matching runs in Rust against the FTS5 index (the
                // in-memory history no longer holds full text). Label and
                // source-name matching stay here — the backend never had them
                // for the list row, and images are findable only via their
                // generated label ("Image (WxH)") / source name.
                let filtered = await Task.detached(priority: .userInitiated) { [items, backend] in
                    let matchIds = backend.searchIds(newValue)
                    return items.filter {
                        matchIds.contains($0.id) ||
                        $0.label.localizedCaseInsensitiveContains(newValue) ||
                        $0.sourceName.localizedCaseInsensitiveContains(newValue) ||
                        DayGroup.label(for: $0.timestamp)
                            .localizedCaseInsensitiveContains(newValue)
                    }
                }.value

                // Task.detached is not auto-cancelled with this task — if the
                // query changed while the search ran, discard the stale result
                // instead of overwriting the newer search's output.
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        effectiveSearchText = newValue
                        searchResults = filtered
                        searchResultsGeneration &+= 1
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
                .onSubmit {
                    if !displayItems.isEmpty {
                        selectItem(at: 0, asPath: NSEvent.modifierFlags.contains(.shift))
                    }
                }

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

    private func emptyMessageView(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(theme.popupDimText)
            Text(title)
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
                    switchToFilterTab(mode)
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
        // The pill is the CONTROL: it snaps instantly (0.08s) so the operation
        // feels acknowledged the moment it is issued, while the list content
        // below animates at its own adaptive, readable pace.
        .animation(.easeOut(duration: 0.08), value: filterMode)
    }

    // MARK: - Items List

    /// The region that reacts to the filter mode: the item list + bottom bar,
    /// or the per-tab empty state. Rows keep their `entry_id` identity across
    /// filter changes.
    @ViewBuilder
    private var filterPageContent: some View {
        if displayItems.isEmpty && !effectiveSearchText.isEmpty {
            emptyMessageView(icon: "magnifyingglass", title: "无匹配结果")
        } else if displayItems.isEmpty && filterMode == .favorites {
            emptyMessageView(icon: "star.slash", title: "暂无收藏")
        } else if displayItems.isEmpty && filterMode == .image {
            emptyMessageView(icon: "photo", title: "暂无图片")
        } else if displayItems.isEmpty && filterMode == .text {
            emptyMessageView(icon: "doc.text", title: "暂无文本")
        } else {
            VStack(spacing: 4) {
                itemsList
                bottomBar
            }
        }
    }

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
            VStack(spacing: 0) {
                // Top anchor: always laid out (outside the LazyVStack), so
                // its position (0) never depends on lazy row-height
                // estimation. Tab switches scroll to it before changing the
                // filter — the one scroll that must be exact.
                Color.clear
                    .frame(height: 0)
                    .id(listTopAnchorID)
                LazyVStack(spacing: 3) {
                ForEach(popupRows, id: \.id) { row in
                    switch row {
                    case .separator(let timestamp, let isFirst):
                        DateSeparatorView(timestamp: timestamp)
                            .padding(.top, isFirst ? 2 : 8)
                            .padding(.bottom, 1)
                            // Date separators keep their stable day identity;
                            // only their text is allowed to update.
                            .id(row.id)
                    case .item(let index, let item):
                        let shortcut: String? = isCommandPressed && index < 9 ? "⌘\(index + 1)" : nil
                        ItemRowView(
                            item: item,
                            isSelected: selectedIndex == index + 1,
                            isDeleteModifierPressed: isControlPressed,
                            shortcutHint: shortcut,
                            isFavorite: backend.favoriteIds.contains(item.id),
                            selectionNamespace: selectionNamespace
                        )
                        // Rows exclusively own drag gestures. PopupHostingView
                        // exposes only its outer 3 pt border for moving the
                        // window, so this native drag cannot move the popup.
                        .onDrag {
                            selectedIndex = index + 1
                            popupWindow?.beginItemDrag()
                            return ClipboardDragProvider.provider(for: item)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let itemIdx = index + 1
                            if selectedIndex == itemIdx {
                                selectItem(at: index)
                            } else {
                                selectedIndex = itemIdx
                            }
                        }
                        // Report the row's frame ONLY while a right-click is
                        // being resolved (one-shot snapshot). Normally the row
                        // carries no geometry observer — scrolling never pays
                        // per-row GeometryReader/preference work.
                        .background {
                            if contextMenuArmed {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowFramePreferenceKey.self,
                                        value: [item.id: geo.frame(in: .global)]
                                    )
                                }
                            }
                        }
                        .id(item.id)
                    }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.all, 2)
            // Slide the selection highlight between rows when the selection
            // moves. Applied to the rows container (not the ScrollView) so
            // scrolling stays instant while only the highlight glides.
            // Fast spring: low response = snappy; text color is decoupled in
            // ItemRowView so it doesn't ride this spring's settle tail.
            .animation(.spring(response: 0.18, dampingFraction: 0.82, blendDuration: 0),
                       value: selectedIndex)
        }
        .onPreferenceChange(RowFramePreferenceKey.self) { frames in
            // Resolve the armed right-click against the fresh snapshot, then
            // disarm — rows stop reporting until the next right-click.
            guard contextMenuArmed, let request = pendingContextMenuRequest else { return }
            contextMenuArmed = false
            pendingContextMenuRequest = nil
            resolveContextMenu(frames: frames, request: request)
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
    /// Built once per data generation inside the display memo, not per body
    /// evaluation (see `currentDisplayMemo`).
    private var popupRows: [PopupRow] { currentDisplayMemo.rows }

    /// Returns the id to target for `scrollPosition` so that both the item at
    /// `itemIndex` and any date separator above it are visible after the scroll.
    func scrollTargetForItem(at itemIndex: Int) -> Int? {
        let items = displayItems
        guard itemIndex >= 0, itemIndex < items.count else { return nil }
        let hasSeparator = itemIndex == 0
            || !DayGroup.isSameDay(items[itemIndex - 1].timestamp, items[itemIndex].timestamp)
        if hasSeparator {
            return DayGroup.separatorID(for: items[itemIndex].timestamp)
        }
        return items[itemIndex].id
    }

    // MARK: - Bottom Bar (item count + shortcuts, single row)

    /// Item count is the only animated feedback for tab filtering. The list
    /// and date separators retain their identities and update immediately.
    private var bottomBar: some View {
        let memo = currentDisplayMemo
        return HStack(spacing: 0) {
            // --- Left: item count stats ---
            Text("\(memo.items.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.popupSecondaryText)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.18), value: memo.items.count)
            Text(" 项")
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
            Text("\(memo.textCount) 文本")
                .font(.system(size: 10))
                .foregroundColor(theme.popupMutedText)
            Text("\(memo.imageCount) 图片")
                .font(.system(size: 10))
                .foregroundColor(theme.popupMutedText)

            Spacer()

            // --- Right: shortcut hints ---
            shortcutHint(key: "⌥P", label: "收藏/取消")
            shortcutHint(key: "Space", label: "预览")
            shortcutHint(key: "⌃⌫", label: "删除")
            shortcutHint(key: "⌘Z", label: "撤销")
            shortcutHint(key: "⌘1~9", label: "快速选择")
            shortcutHint(key: "右键", label: "菜单")
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
}
