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

    var backend: ClipboardBackend { ClipboardBackend.shared }
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

    /// ID of the entry currently undergoing inline remark editing (nil if none).
    @State var editingItemId: Int? = nil
    @State var editingText: String = ""

    /// False until the open animation has settled. `show()` triggers a backend
    /// reload before this content mounts, so without the gate the first
    /// published list would animate its rows in on top of the deliberate
    /// Spotlight open scale — two entrances fighting in the same 0.2s window.
    /// Row-change animation is armed only after the open spring finishes.
    @State private var rowsReadyForAnimation = false

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
        // base (both backend.items and searchResults) is already sorted by
        // timestamp descending from the backend/DB. Re-sorting is redundant.
        let sorted: [ClipboardItem]
        if filterMode == .all {
            sorted = base
        } else {
            sorted = base.filter { matches($0, filterMode: filterMode) }
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

    /// Entering/leaving the inline editor swaps one row's content. A short
    /// ease-out cross-fade keeps it from popping (the tag badge rides the same
    /// transaction). The field's own focus hop is asynchronous — see
    /// `InlineRemarkField.makeNSView` — and is unaffected by this.
    private static var inlineEditAnimation: Animation { .easeOut(duration: 0.12) }

    func startInlineEditing(for item: ClipboardItem) {
        if showPreview { closePreview() }
        withAnimation(Self.inlineEditAnimation) {
            editingItemId = item.id
            editingText = item.customLabel
        }
    }

    func commitInlineEditing(entryId: Int, newText: String, restoreFocus: Bool = true) {
        guard editingItemId == entryId else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = false
        withAnimation(Self.inlineEditAnimation) {
            editingItemId = nil
            // A failed save must not look like a success: the row would silently
            // revert while the user believes the remark is stored.
            saved = backend.setCustomLabel(entryId: entryId, label: trimmed)
            if saved, !effectiveSearchText.isEmpty,
               let sIdx = searchResults.firstIndex(where: { $0.id == entryId }) {
                searchResults[sIdx] = searchResults[sIdx].withUpdatedCustomLabel(trimmed)
                searchResultsGeneration &+= 1
            }
        }
        if !saved {
            errorLog("commitInlineEditing: remark for entry \(entryId) was not saved")
            NSSound.beep()
        }
        if restoreFocus { restoreContainerFocus() }
    }

    /// Commit whatever is being edited, if anything. Every path that ends the
    /// edit for a reason other than an explicit Escape must go through here:
    /// switching rows/tabs/search used to discard the text, so the same edit was
    /// kept or lost depending on how the user left the field.
    ///
    /// `restoreFocus: false` for callers that hand focus somewhere else right
    /// after (the search field), where restoring the container would steal it.
    func commitPendingInlineEdit(restoreFocus: Bool = true) {
        guard let entryId = editingItemId else { return }
        commitInlineEditing(entryId: entryId, newText: editingText, restoreFocus: restoreFocus)
    }

    func cancelInlineEditing() {
        withAnimation(Self.inlineEditAnimation) {
            editingItemId = nil
        }
        restoreContainerFocus()
    }

    private func restoreContainerFocus() {
        isSearchFocused = false
        isContainerFocused = true
        DispatchQueue.main.async {
            self.isSearchFocused = false
            self.isContainerFocused = true
            if let window = self.popupWindow, let contentView = window.contentView {
                window.makeFirstResponder(contentView)
            }
        }
    }

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
                        // Per-tab empty state <-> list is a structural swap too.
                        // Keyed on emptiness (not on the row count) so ordinary
                        // capture/delete list updates stay un-animated.
                        .animation(.easeOut(duration: 0.18), value: displayItems.isEmpty)
                }
                .padding(.all, 3)
            }
        }
        .scaleEffect(openingScale, anchor: .center)
        .frame(width: popupWidth, height: popupHeight)
        // Empty <-> populated and per-tab empty <-> list are structural swaps:
        // cross-fade them instead of popping. Scoped by value so ordinary list
        // updates never pick up a transition.
        .animation(.easeOut(duration: 0.18), value: backend.items.isEmpty)
        // Spotlight target geometry for the onboarding tour (empty when it is
        // not running — the reporters are only mounted while it is).
        .onPreferenceChange(SpotlightFramePreferenceKey.self) { geometry in
            OnboardingGuide.shared.updateSpotlightGeometry(geometry)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isContainerFocused)
        .onKeyPress(.upArrow) {
            guard editingItemId == nil else { return .ignored }
            Perf.instant("swift", "nav.input", data: "up")
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard editingItemId == nil else { return .ignored }
            Perf.instant("swift", "nav.input", data: "down")
            if selectedIndex < maxIndex {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard editingItemId == nil else { return .ignored }
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
            guard editingItemId == nil else { return .ignored }
            if selectedIndex == 0 { return .ignored }
            togglePreview()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard editingItemId == nil else { return .ignored }
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "left")
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard editingItemId == nil else { return .ignored }
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "right")
            return .handled
        }
        .onAppear {
            // SwiftUI has mounted and is laying out the content: the closest
            // synchronous proxy for "the rows are on screen". Paired with the
            // popup.show_begin instant this is the hotkey -> visible latency.
            Perf.instant("swift", "popup.content_appear",
                         data: backend.items.isEmpty ? "empty" : "rows")
            // Reset transient state in place. The hosting view and content view
            // are rebuilt per session and nilled on close, so this state has
            // exactly one session's lifetime.
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
            editingItemId = nil
            editingText = ""
            rowsReadyForAnimation = false
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
                // The open spring has settled: arm row-change animation. Set
                // outside any animation transaction so arming itself is not
                // animated.
                self.rowsReadyForAnimation = true
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
            isSearchFocused = false
            isContainerFocused = false
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
            // Inline remark editing owns the keyboard: ⌃⌫ belongs to the text
            // field, never to the entry underneath it.
            guard editingItemId == nil else { return }
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
            // ⌘1-⌘9 pastes a result and must stay available while searching,
            // but not while a remark is being edited.
            guard editingItemId == nil,
                  let number = note.object as? Int,
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
        .onReceive(NotificationCenter.default.publisher(for: startInlineEditNotification)) { _ in
            if selectedIndex > 0 {
                let itemIdx = selectedIndex - 1
                if itemIdx < displayItems.count {
                    startInlineEditing(for: displayItems[itemIdx])
                }
            }
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
        .onChange(of: filterMode) { _, _ in
            // Leaving the current list keeps the edit — a tab switch is not a
            // cancel gesture (Escape is).
            commitPendingInlineEdit()
            closePreview()
            // A tab switch re-anchors the selection to the new list's first
            // row. The switch is a plain state change with no animation on the
            // list (cheap by construction); only the tab pill animates.
            if selectedIndex != 0 {
                selectedIndex = displayItems.isEmpty ? 0 : 1
            }
        }
        .onChange(of: searchText) { _, newValue in
            // Focus belongs to the search field right after this; restoring the
            // container would take it back asynchronously.
            commitPendingInlineEdit(restoreFocus: false)
            selectedIndex = 0
            if !newValue.isEmpty { OnboardingGuide.shared.record(.searched) }
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

        let query = newValue
        let perfSearch = PerfSpan.start("swift", "search.end_to_end")
        searchTask = Task { [items = backend.items] in
            do {
                try await Task.sleep(nanoseconds: debounceNs)
                try Task.checkCancellation()

                // Core matching runs in Rust against SQLite (FTS5 trigram + LIKE for
                // full text, label, custom_label, and source_name).
                // Swift only supplements view-local dynamic DayGroup dates.
                let filtered: [ClipboardItem] = await Task.detached(priority: .userInitiated) { [items, backend, query] in
                    guard !Task.isCancelled else { return [ClipboardItem]() }
                    let perfFilter = PerfSpan.start("swift", "search.filter")
                    let matchIDs = backend.searchIds(query)
                    let result = items.filter {
                        matchIDs.contains($0.id) ||
                        DayGroup.label(for: $0.timestamp)
                            .localizedCaseInsensitiveContains(query)
                    }
                    perfFilter?.val = Int64(result.count)
                    perfFilter?.end()
                    return result
                }.value

                // Task.detached is not auto-cancelled with this task — if the
                // query changed while it ran, discard the stale result instead
                // of overwriting the newer search's output.
                try Task.checkCancellation()

                await MainActor.run {
                    // Discarded results are not a latency sample; only a query
                    // that actually lands on screen is timed.
                    guard !Task.isCancelled, self.searchText == query else { return }
                    perfSearch?.val = Int64(filtered.count)
                    perfSearch?.data = hasCJK ? "cjk" : "ascii"
                    perfSearch?.end()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        effectiveSearchText = query
                        searchResults = filtered
                        searchResultsGeneration &+= 1
                    }
                    if selectedIndex == 0 {
                        scrollTarget = scrollTargetForItem(at: 0)
                    }
                }
            } catch {
                return
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
                .foregroundColor(theme.popupMutedText)

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
                        .foregroundColor(theme.popupMutedText)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
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
                        : theme.popupRowBorder,
                    lineWidth: selectedIndex == 0 ? 2.0 : 1.0
                )
        )
        .onTapGesture {
            selectedIndex = 0
            isSearchFocused = true
        }
        // The clear button inserts/removes on emptiness; give its `.transition`
        // a transaction. Scoped to the boolean so typing never animates.
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
        .reportSpotlightFrame(.searchField)
    }

    private func emptyMessageView(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(theme.popupSecondaryText)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.popupPrimaryText)
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
                            : theme.popupFilterTabInactive)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mode == filterMode
                                    ? theme.popupFilterTabBackgroundSelected
                                    : theme.popupFilterTabBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    mode == filterMode
                                        ? Color(nsColor: .controlAccentColor).opacity(0.35)
                                        : theme.popupRowBorder,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        // The pill is the CONTROL: it snaps in 0.08s so the operation feels
        // acknowledged the moment it is issued. This modifier animates the
        // pill bar only; the list switches with no explicit animation.
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
            // Cross-fade against the empty states (which carry .opacity), so
            // neither side pops out of the structural swap.
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        itemsListScrollView
            .scrollPosition(id: $scrollTarget)
            .onChange(of: selectedIndex) { _, newValue in
                // Selection state has been applied and SwiftUI is about to lay
                // the row out; paired with the preceding nav.input instant this
                // yields the input -> applied latency.
                Perf.instant("swift", "nav.applied", data: String(newValue))
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
            // `hasSelectedRow` tells the tour whether a missing row frame means
            // "scrolled out of the viewport" or "nothing is selected".
            .reportSpotlightFrame(.list, hasSelectedRow: selectedIndex > 0)
    }

    /// A row entering/leaving the list on a data change (capture, delete,
    /// undo, restore, favorite). Never from scale(0) — a small scale plus fade
    /// reads as the row growing into place. Applied to both items and date
    /// separators so a new day arrives with its first entry.
    ///
    /// Deliberately NOT applied on search or tab-filter changes: those move
    /// many rows at once and must stay a single composited update. Per-row
    /// transitions there were removed in 0.100.4 after rapid swipes stalled
    /// and retained transition graphs — see the `.animation(value:)` below,
    /// which keys on `itemsGeneration` precisely because it does not bump on
    /// search or filter.
    private static var rowChangeTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96))
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
                            .transition(Self.rowChangeTransition)
                    case .item(let index, let item):
                        let shortcut: String? = isCommandPressed && index < 9 ? "⌘\(index + 1)" : nil
                        let spotlightRowArmed = OnboardingGuide.shared.isActive && selectedIndex == index + 1
                        ItemRowView(
                            item: item,
                            isSelected: selectedIndex == index + 1,
                            isDeleteModifierPressed: isControlPressed,
                            shortcutHint: shortcut,
                            isFavorite: backend.favoriteIds.contains(item.id),
                            isEditingRemark: editingItemId == item.id,
                            editingText: $editingText,
                            onCommitRemark: { newText in
                                commitInlineEditing(entryId: item.id, newText: newText)
                            },
                            onCancelRemark: {
                                cancelInlineEditing()
                            },
                            selectionNamespace: selectionNamespace
                        )
                        // Rows exclusively own drag gestures. PopupHostingView
                        // exposes only its outer 3 pt border for moving the
                        // window, so this native drag cannot move the popup.
                        .onDrag {
                            selectedIndex = index + 1
                            popupWindow?.beginItemDrag()
                            // Rich text is opt-in per source app: it breaks
                            // VS Code chat drops but is required by 思源笔记 /
                            // Typora. See `sourceAppNeedsRichTextDrag`.
                            let richText = backend.sourceAppNeedsRichTextDrag
                            return ClipboardDragProvider.provider(for: item, richText: richText)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editingItemId == item.id { return }
                            let itemIdx = index + 1
                            if selectedIndex == itemIdx {
                                selectItem(at: index)
                            } else {
                                // Switching rows keeps the edit (Escape is the
                                // only way to discard it).
                                commitPendingInlineEdit()
                                selectedIndex = itemIdx
                            }
                        }
                        // Report the row's frame ONLY while something needs it:
                        // a right-click being resolved (one-shot snapshot), or
                        // the onboarding tour framing the selected row. Normally
                        // the row carries no geometry observer — scrolling never
                        // pays per-row GeometryReader/preference work.
                        .background {
                            if contextMenuArmed || spotlightRowArmed {
                                GeometryReader { geo in
                                    let frame = geo.frame(in: .global)
                                    Color.clear
                                        .preference(
                                            key: RowFramePreferenceKey.self,
                                            value: contextMenuArmed ? [item.id: frame] : [:]
                                        )
                                        .preference(
                                            key: SpotlightFramePreferenceKey.self,
                                            value: spotlightRowArmed
                                                ? SpotlightGeometry(frames: [.selectedRow: frame])
                                                : SpotlightGeometry()
                                        )
                                }
                            }
                        }
                        .id(item.id)
                        .transition(Self.rowChangeTransition)
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
            // Row insertion/removal on a data change: a capture lands at the
            // top, a delete collapses its row, undo grows it back. Keyed on
            // `itemsGeneration`, which bumps for data mutations (capture,
            // delete, undo, restore, favorite) but NOT for search or tab
            // filtering — those keep the single composited update described
            // above. Gated until the open spring settles so the first published
            // list does not animate on top of the Spotlight open scale.
            .animation(rowsReadyForAnimation
                       ? .spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0)
                       : nil,
                       value: backend.itemsGeneration)
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
                .foregroundColor(theme.popupMutedText)
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
                .foregroundColor(theme.popupPrimaryText)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(theme.popupSecondaryText)
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
