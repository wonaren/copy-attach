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

// MARK: - Right-Click Context Menu Support

/// Screen-space frames of the laid-out item rows (entryId → CGRect in global
/// coordinates), published by each row via `RowFramePreferenceKey`.
/// `PopupHostingView.rightMouseDown` uses this store to map a right-click to
/// the row under the cursor. All access happens on the main thread.
@MainActor
final class PopupRowFrameStore {
    static let shared = PopupRowFrameStore()
    var frames: [Int: CGRect] = [:]
}

private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Retains a closure for the lifetime of an NSMenuItem. `NSMenuItem.target`
/// is weak, so the menu keeps the handler alive through `representedObject`
/// (strong) — the local scope of `showContextMenu` additionally holds it while
/// the synchronous `popUp` tracking loop runs.
private final class ContextMenuItemTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    // Explicit @objc name: Swift's `perform(_:)` would bridge to
    // `performSelector:`, which collides with NSObject's own method of that
    // name — NSMenu's action dispatch then resolves the selector to garbage
    // and crashes. `invoke:` is collision-free.
    @objc(invoke:) func invoke(_ sender: Any?) { action() }
}

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @State private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0  // 0 = search bar, 1+ = items
    @State private var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var isCommandPressed: Bool = false
    @Environment(\.appTheme) private var theme
    @State private var searchText: String = ""
    @State private var effectiveSearchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var scrollTarget: Int?
    /// Id of the always-laid-out zero-height anchor at the very top of the
    /// list content (outside the LazyVStack, so its position is exact and
    /// never depends on lazy row-height estimation). Scrolling to it returns
    /// the viewport to offset 0 reliably.
    private let listTopAnchorID = 0

    @State private var filterMode: FilterMode = .all

    // Namespace for the sliding selection highlight (Spotlight-style glide
    // between rows when the selection moves with ↑/↓ keys or a click).
    @Namespace private var selectionNamespace

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
        filteredItems(for: filterMode).sorted { $0.timestamp > $1.timestamp }
    }

    /// The highest valid selectedIndex (search bar + item count).
    private var maxIndex: Int { displayItems.count }

    // Design Tokens
    private let popupWidth: CGFloat = 500
    private let popupHeight: CGFloat = 720

    /// Base duration for the smallest filter change.
    private let filterSwitchBaseDuration: TimeInterval = 0.15
    /// Extra seconds per unit of visible change (rows entering or leaving),
    /// saturating once the change exceeds what fits on screen.
    private let filterSwitchPerChange: TimeInterval = 0.011
    /// Per-direction cap on counted change: past ~6 rows the extra rows are
    /// offscreen and contribute no visible motion.
    private let filterSwitchChangeCap = 6
    /// Hard ceiling: the control (tab pill) already snaps instantly, so the
    /// content animation never needs more than this.
    private let filterSwitchMaxDuration: TimeInterval = 0.28

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

    /// Row-level enter/exit for filter changes: fade + a slight scale in place.
    /// No directional offset — filtering the same data pool is not navigation.
    /// Survivors (rows whose entry_id survives the new filter) have no
    /// transition at all: they stay pinned and only shift as the list collapses
    /// around them, which is what visually says "same data, new filter" instead
    /// of "another page".
    private var filterRowTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        )
    }

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

                    // Filter tabs re-filter the SAME data pool: rows keep their
                    // entry_id identity, survivors stay pinned, removed rows
                    // dissolve in place (`filterRowTransition`) and the list
                    // collapses. No page slide — filtering is not navigation.
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
        .onKeyPress(.return) {
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1)
            }
            return .handled
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
            switchFilterTab(direction: "left", animated: true)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "right", animated: true)
            return .handled
        }
        .onAppear {
            selectedIndex = backend.items.isEmpty ? 0 : 1
            searchText = ""
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
            showContextMenu(for: request)
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
            switchFilterTab(direction: direction, animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: popupSwipeNotification)) { note in
            guard let direction = note.object as? String else { return }
            switchFilterTab(direction: direction, animated: true)
        }
        .onChange(of: filterMode) { _, _ in
            closePreview()
            // A tab switch re-anchors the selection to the new list's first
            // row: the new tab is a different filter of the same data pool, so
            // the old row number has no meaning there. An empty new list falls
            // back to the search bar; a search-bar-focused switch (selectedIndex
            // == 0) keeps the search focus.
            if selectedIndex != 0 {
                selectedIndex = displayItems.isEmpty ? 0 : 1
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
                    switchToFilterTab(mode, animated: true)
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

    // MARK: - Tab Switching

    /// Switch to a specific filter tab. The tabs re-filter the same data pool,
    /// so this is a simple identity-preserving diff: `withAnimation` animates
    /// row removals/insertions (`filterRowTransition`) and the layout collapse,
    /// while surviving rows never leave their identity. The duration adapts to
    /// the measured change (see `filterSwitchAnimation(removed:added:)`).
    private func switchToFilterTab(_ target: FilterMode, animated: Bool) {
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

    /// The entries a filter tab shows, unsorted. `.all` passes the base through
    /// unchanged (no copy); the other modes filter through `matches`, the
    /// single source of the favorites/image/text predicates.
    private func filteredItems(for mode: FilterMode) -> [ClipboardItem] {
        let base = effectiveSearchText.isEmpty ? backend.items : searchResults
        switch mode {
        case .all:
            return base
        case .favorites, .image, .text:
            return base.filter { matches($0, filterMode: mode) }
        }
    }

    /// Whether an entry satisfies a filter tab's predicate. Single source of
    /// truth for the filter definitions — `displayItems` and the tab-switch
    /// measurement both derive from it, so they can't drift apart.
    private func matches(_ item: ClipboardItem, filterMode mode: FilterMode) -> Bool {
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
    private func switchFilterTab(direction: String, animated: Bool) {
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

    // MARK: - Preview Management

    private func handleEscape() {
        if showPreview {
            closePreview()
        } else {
            searchText = ""
            onClose()
        }
    }

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
        // Trackpad pinch (magnify) events are delivered only to the truly
        // frontmost application. This LSUIElement agent app never receives
        // applicationDidBecomeActive while its nonactivating panels are up —
        // NSApp.isActive reports true, but the window server keeps routing
        // magnify gestures to the previous app, so ZoomableImageNSView's
        // magnify monitor never fires. Real activation makes gesture delivery
        // work for the preview. Deactivation is automatic when the
        // popup/preview closes or another app is clicked; the paste target
        // pid is protected in ClipboardBackend.updateSourceApp.
        NSApp.activate(ignoringOtherApps: true)
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
            guard let full = item.fullText else {
                debugLog("fullTextItem: failed to load full text for entry \(entryId)")
                return nil
            }
            return .text(entryId: entryId, text: full, timestamp: timestamp,
                         label: label, sourceName: sourceName, sourceBundleId: sourceBundleId, preview: full)
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
                .contentTransition(.numericText())
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

    // MARK: - Items List

    /// The region that reacts to the filter mode: the item list + bottom bar,
    /// or the per-tab empty state. Rows keep their `entry_id` identity across
    /// filter changes — survivors stay put, changed rows dissolve in place and
    /// the list collapses (`filterRowTransition`).
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
                            .transition(filterRowTransition)
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
                        // Report the row's screen-space frame so PopupHostingView
                        // can map a right-click to this row (context menu).
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowFramePreferenceKey.self,
                                    value: [item.id: geo.frame(in: .global)]
                                )
                            }
                        )
                        .id(item.id)
                        .transition(filterRowTransition)
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
            // Wholesale replace: LazyVStack only lays out visible rows, so a
            // fresh pass contains exactly the rows that can be right-clicked.
            PopupRowFrameStore.shared.frames = frames
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

    // MARK: - Right-Click Context Menu

    /// The current displayItems index of the entry, or nil if it no longer
    /// exists (deleted, filtered out, or the list changed while the menu was
    /// open). Actions re-resolve by stable entry id instead of trusting the
    /// index captured when the menu was built.
    private func currentIndex(of entryId: Int) -> Int? {
        displayItems.firstIndex(where: { $0.id == entryId })
    }

    /// Presented by `PopupHostingView.rightMouseDown` via notification.
    /// Selects the right-clicked row, then shows a native NSMenu at the cursor.
    private func showContextMenu(for request: PopupContextMenuRequest) {
        guard let index = currentIndex(of: request.entryId) else { return }
        let item = displayItems[index]
        selectedIndex = min(index + 1, maxIndex)

        let menu = NSMenu()
        menu.autoenablesItems = false

        addContextMenuItem(to: menu, title: "插入", symbol: "arrow.down.to.line") {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.selectedIndex = idx + 1
            self.selectItem(at: idx)
        }
        addContextMenuItem(to: menu, title: "预览", symbol: "eye") {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.selectedIndex = idx + 1
            if self.showPreview {
                self.updatePreviewContent()
            } else {
                self.openPreview()
            }
        }
        menu.addItem(.separator())
        addContextMenuItem(to: menu,
                           title: item.isImage ? "复制图片" : "复制内容",
                           symbol: item.isImage ? "photo" : "doc.on.doc") {
            self.copyItemContent(item)
        }
        if item.isImage {
            addContextMenuItem(to: menu, title: "另存为…", symbol: "square.and.arrow.down") {
                self.saveImageItem(item)
            }
        }
        menu.addItem(.separator())
        let isFavorite = backend.favoriteIds.contains(item.id)
        addContextMenuItem(to: menu,
                           title: isFavorite ? "取消收藏" : "收藏",
                           symbol: isFavorite ? "star.slash" : "star") {
            self.backend.toggleFavorite(item.id)
            // Favorites may shrink displayItems; keep the selection valid.
            if self.selectedIndex > self.maxIndex {
                self.selectedIndex = max(0, self.maxIndex)
            }
        }
        addContextMenuItem(to: menu, title: "删除", symbol: "trash", destructive: true) {
            guard let idx = self.currentIndex(of: item.id) else { return }
            self.deleteItem(at: idx)
        }

        guard let popup = popupWindow, let contentView = popup.contentView else { return }
        let point = contentView.convert(request.windowPoint, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    private func addContextMenuItem(to menu: NSMenu, title: String, symbol: String,
                                    destructive: Bool = false, action: @escaping () -> Void) {
        let handler = ContextMenuItemTarget(action)
        let item = NSMenuItem(title: title,
                              action: #selector(ContextMenuItemTarget.invoke(_:)),
                              keyEquivalent: "")
        item.target = handler
        // NSMenuItem.target is weak; representedObject (strong) keeps the
        // handler alive for as long as the menu owns the item.
        item.representedObject = handler
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(item)
    }

    /// Copy the entry's full content to the system pasteboard without pasting.
    /// The monitor re-captures it as a normal clipboard write: dedup keeps the
    /// same entry id and moves it to the top of history (natural "re-copy"
    /// semantics).
    private func copyItemContent(_ item: ClipboardItem) {
        switch item {
        case .text:
            guard let full = item.fullText else {
                debugLog("copyItemContent: failed to load full text for entry \(item.id)")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
        case .image:
            guard let data = item.imageData else {
                debugLog("copyItemContent: image not ready (entry \(item.id))")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
    }

    /// Save an image entry to a user-chosen location as a PNG file.
    private func saveImageItem(_ item: ClipboardItem) {
        guard case .image(_, _, _, _, let timestamp, _, _, _) = item,
              let data = item.imageData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        panel.nameFieldStringValue = "CopyAttach-\(formatter.string(from: date)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            debugLog("saveImageItem: failed to write \(url.path): \(error)")
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
