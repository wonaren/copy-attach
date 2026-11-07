import AppKit
import SwiftUI

enum FilterMode: String, CaseIterable {
    case favorites
    case all
    case image
    case text
    case remarks

    var icon: String {
        switch self {
        case .favorites: return "star.fill"
        case .all: return "line.3.horizontal"
        case .image: return "photo"
        case .text: return "doc.text"
        case .remarks: return "tag.fill"
        }
    }

    var title: String {
        switch self {
        case .favorites: return "收藏"
        case .all: return "全部"
        case .image: return "图片"
        case .text: return "文本"
        case .remarks: return "备注"
        }
    }
}

private enum PopupRow: Identifiable {
    case separator(timestamp: UInt64, isFirst: Bool)
    case item(index: Int, item: ClipboardItem)

    var id: Int {
        switch self {
        case .separator(let timestamp, _):
            return DayGroup.separatorID(for: timestamp)
        case .item(_, let item):
            return item.id
        }
    }
}

private struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

final class ContextMenuItemTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc(invoke:) func invoke(_ sender: Any?) { action() }
}

struct HistoryPopupContent: View {
    let onClose: () -> Void

    var backend: ClipboardBackend { ClipboardBackend.shared }
    @State var selectedIndex: Int = 0
    @State var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var isCommandPressed: Bool = false
    @Environment(\.appTheme) var theme
    @State var searchText: String = ""
    @State var effectiveSearchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State var scrollTarget: Int?
    let listTopAnchorID = 0

    @State var filterMode: FilterMode = .all
    @State var pendingFilterMode: FilterMode?
    @State var filterSwitchGeneration = 0

    @State var contextMenuArmed = false
    @State var pendingContextMenuRequest: PopupContextMenuRequest?

    @Namespace private var selectionNamespace
    @Namespace private var filterTabNamespace

    @State private var openingScale: CGFloat = 1.06
    @State private var isDismissing: Bool = false

    @State var toastMessage: String? = nil
    @State var toastIcon: String = "checkmark.circle.fill"
    @State private var toastDismissTask: Task<Void, Never>? = nil

    func showToast(_ message: String, icon: String = "checkmark.circle.fill") {
        toastDismissTask?.cancel()
        withAnimation(AppleMotion.snappy) {
            toastIcon = icon
            toastMessage = message
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled {
                withAnimation(AppleMotion.snappy) {
                    toastMessage = nil
                }
            }
        }
    }

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isContainerFocused: Bool

    @State var searchResults: [ClipboardItem] = []
    @State private var searchResultsGeneration = 0

    @State var editingItemId: Int? = nil
    @State var editingText: String = ""

    @State private var rowsReadyForAnimation = false

    private struct DisplayMemo {
        let itemsGeneration: Int
        let effectiveSearchText: String
        let searchResultsGeneration: Int
        let filterMode: FilterMode
        let startOfToday: Date
        let items: [ClipboardItem]
        let rows: [PopupRow]
        let textCount: Int
        let imageCount: Int
    }

    private final class DisplayMemoBox {
        var memo: DisplayMemo?
    }

    @State private var displayMemoBox = DisplayMemoBox()

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

    var displayItems: [ClipboardItem] { currentDisplayMemo.items }

    var maxIndex: Int { displayItems.count }

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
        if selectedIndex > maxIndex {
            selectedIndex = max(0, maxIndex)
        }
        if restoreFocus { restoreContainerFocus() }
    }

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
        let container = selectedIndex > 0
        isSearchFocused = !container
        isContainerFocused = container
        DispatchQueue.main.async {
            self.isSearchFocused = !container
            self.isContainerFocused = container
            if container, let window = self.popupWindow, let contentView = window.contentView {
                window.makeFirstResponder(contentView)
            }
        }
    }

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
                    .transition(.appleScaleFade)
            } else {
                VStack(spacing: 4) {
                    searchField
                        .padding(.horizontal, 5)
                        .padding(.top, 6)

                    filterModeTabs
                        .padding(.horizontal, 5)

                    filterPageContent
                        .animation(.easeOut(duration: 0.18), value: displayItems.isEmpty)
                }
                .padding(.all, 3)
                .transition(.appleScaleFade)
            }

            if let msg = toastMessage {
                VStack {
                    Spacer()
                    AppleToastCard(message: msg, iconName: toastIcon)
                        .padding(.bottom, 28)
                }
                .transition(.appleScaleFade)
                .zIndex(999)
            }
        }
        .scaleEffect(isDismissing ? 1.04 : openingScale, anchor: .center)
        .blur(radius: isDismissing ? 16.0 : 0.0)
        .opacity(isDismissing ? 0.0 : 1.0)
        .frame(width: popupWidth, height: popupHeight)
        .animation(.easeOut(duration: 0.18), value: backend.items.isEmpty)
        .onPreferenceChange(SpotlightFramePreferenceKey.self) { geometry in
            OnboardingGuide.shared.updateSpotlightGeometry(geometry)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isContainerFocused)
        .onKeyPress(.upArrow) {
            guard !isDismissing, editingItemId == nil else { return .ignored }
            Perf.instant("swift", "nav.input", data: "up")
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !isDismissing, editingItemId == nil else { return .ignored }
            Perf.instant("swift", "nav.input", data: "down")
            if selectedIndex < maxIndex {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard !isDismissing, editingItemId == nil else { return .ignored }
            if PasteQueueManager.shared.hasItems {
                guard PasteDeliveryMode.current == .keystroke else {
                    showToast("当前为「仅复制到剪贴板」模式，无法顺序粘贴",
                              icon: "doc.on.clipboard")
                    return .handled
                }
                let outcome = PasteQueueManager.shared.startDispensing {
                    closePreview()
                    onClose()
                    backend.restorePasteTargetFocus(force: true)
                }
                switch outcome {
                case .started:
                    OnboardingGuide.shared.record(.queueStarted)
                    break
                case .eventTapUnavailable:
                    showToast("无法接管 ⌘V，请检查辅助功能权限",
                              icon: "exclamationmark.triangle.fill")
                case .emptyQueue:
                    showToast("粘贴队列已空", icon: "exclamationmark.triangle.fill")
                case .allEntriesStale:
                    showToast("所选条目已失效，队列已清空",
                              icon: "exclamationmark.triangle.fill")
                }
                return .handled
            }
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1, asPath: press.modifiers.contains(.shift))
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            guard !isDismissing else { return .handled }
            handleEscape()
            return .handled
        }
        .onKeyPress(.space) {
            guard !isDismissing, editingItemId == nil else { return .ignored }
            if selectedIndex == 0 { return .ignored }
            togglePreview()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !isDismissing, editingItemId == nil else { return .ignored }
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "left")
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !isDismissing, editingItemId == nil else { return .ignored }
            guard selectedIndex > 0 else { return .ignored }
            switchFilterTab(direction: "right")
            return .handled
        }
        .onAppear {
            Perf.instant("swift", "popup.content_appear",
                         data: backend.items.isEmpty ? "empty" : "rows")
            selectedIndex = backend.items.isEmpty ? 0 : 1
            let preserveForRetry = PasteQueueManager.shared.consumePendingBatchRetryOnOpen()
            if PasteQueueManager.shared.hasItems && !preserveForRetry {
                PasteQueueManager.shared.clear()
            }
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
            openingScale = 1.06
            isDismissing = false
            toastDismissTask?.cancel()
            toastDismissTask = nil
            toastMessage = nil
            isControlPressed = NSEvent.modifierFlags.contains(.control)
            isCommandPressed = NSEvent.modifierFlags.contains(.command)

            let openDuration = 0.2
            withAnimation(.spring(response: openDuration,
                                  dampingFraction: 0.85,
                                  blendDuration: 0)) {
                openingScale = 1.0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + openDuration + 0.05) {
                self.rowsReadyForAnimation = true
                if self.backend.items.isEmpty {
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
            isDismissing = false
            toastDismissTask?.cancel()
            toastDismissTask = nil
            toastMessage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: popupWillDismissNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                isDismissing = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: popupCancelDismissNotification)) { _ in
            withAnimation(.easeOut(duration: 0.15)) {
                isDismissing = false
            }
            if selectedIndex == 0 {
                isSearchFocused = true
            } else {
                isContainerFocused = true
            }
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
            guard editingItemId == nil else { return }
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
            guard editingItemId == nil,
                  let number = note.object as? Int,
                  number >= 1 && number <= displayItems.count else { return }
            selectItem(at: number - 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: focusSearchNotification)) { _ in
            selectedIndex = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: queueToggleNotification)) { _ in
            guard selectedIndex > 0, !isDismissing, editingItemId == nil else { return }
            guard PasteDeliveryMode.current == .keystroke else {
                showToast("当前为「仅复制到剪贴板」模式，无需粘贴队列",
                          icon: "doc.on.clipboard")
                return
            }
            let itemIndex = selectedIndex - 1
            guard itemIndex < displayItems.count else { return }
            let item = displayItems[itemIndex]
            withAnimation(AppleMotion.snappy) {
                PasteQueueManager.shared.toggle(item)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            OnboardingGuide.shared.record(.queueToggled)
        }
        .onReceive(NotificationCenter.default.publisher(for: focusSearchAndBackspaceNotification)) { _ in
            selectedIndex = 0
            if !searchText.isEmpty {
                searchText.removeLast()
            }
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
            let anchorId = selectedItemId
            if selectedIndex > 0 {
                let itemIdx = selectedIndex - 1
                if itemIdx < displayItems.count {
                    let item = displayItems[itemIdx]
                    let isFav = backend.favoriteIds.contains(item.id)
                    if backend.toggleFavorite(item.id) {
                        showToast(!isFav ? "已加入收藏" : "已取消收藏", icon: !isFav ? "star.fill" : "star.slash.fill")
                    } else {
                        showToast("收藏失败，请重试", icon: "exclamationmark.triangle.fill")
                    }
                }
            }
            restoreSelection(anchorId)
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
            commitPendingInlineEdit()
            closePreview()
            if selectedIndex != 0 {
                selectedIndex = displayItems.isEmpty ? 0 : 1
            }
        }
        .onChange(of: searchText) { _, newValue in
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

            let hasCJK = newValue.unicodeScalars.contains { $0.value > 0x2E80 }
            let debounceNs: UInt64 = hasCJK ? 150_000_000 : 80_000_000

        let query = newValue
        let perfSearch = PerfSpan.start("swift", "search.end_to_end")
        searchTask = Task { [items = backend.items] in
            do {
                try await Task.sleep(nanoseconds: debounceNs)
                try Task.checkCancellation()

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

                try Task.checkCancellation()

                await MainActor.run {
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(selectedIndex == 0 ? Color(nsColor: .controlAccentColor) : theme.popupMutedText)
                .scaleEffect(selectedIndex == 0 ? 1.08 : 1.0)
                .animation(AppleMotion.snappy, value: selectedIndex == 0)

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
                .buttonStyle(AppleTactileButtonStyle(scale: 0.90))
                .transition(.scale(scale: 0.85).combined(with: .opacity))
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
        .animation(AppleMotion.snappy, value: selectedIndex == 0)
        .onTapGesture {
            selectedIndex = 0
            isSearchFocused = true
        }
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
                        .scaleEffect(mode == filterMode ? 1.06 : 1.0)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if mode == filterMode {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.popupFilterTabBackgroundSelected)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(
                                                Color(nsColor: .controlAccentColor).opacity(0.35),
                                                lineWidth: 1
                                            )
                                    )
                                    .matchedGeometryEffect(id: "activeFilterPill", in: filterTabNamespace)
                            } else {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.popupFilterTabBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(theme.popupRowBorder, lineWidth: 1)
                                    )
                            }
                        }
                }
                .buttonStyle(AppleTactileButtonStyle(scale: 0.94))
                .help(mode.title)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .animation(AppleMotion.snappy, value: filterMode)
    }

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
        } else if displayItems.isEmpty && filterMode == .remarks {
            emptyMessageView(icon: "tag.slash", title: "暂无备注")
        } else {
            VStack(spacing: 4) {
                itemsList
                bottomBar
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        itemsListScrollView
            .scrollPosition(id: $scrollTarget)
            .onChange(of: selectedIndex) { _, newValue in
                Perf.instant("swift", "nav.applied", data: String(newValue))
                if newValue == 0 {
                    if showPreview { closePreview() }
                    return
                }
                let itemIndex = newValue - 1
                if itemIndex < displayItems.count {
                    scrollTarget = scrollTargetForItem(at: itemIndex)
                    updatePreviewContent(item: displayItems[itemIndex])
                }
            }
            .reportSpotlightFrame(.list, hasSelectedRow: selectedIndex > 0)
    }

    private static var rowChangeTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96))
    }

    private var itemsListScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(listTopAnchorID)
                LazyVStack(spacing: 3) {
                let queueOrderByID = PasteQueueManager.shared.orderMap
                let canToggleQueue = PasteDeliveryMode.current == .keystroke
                ForEach(popupRows, id: \.id) { row in
                    switch row {
                    case .separator(let timestamp, let isFirst):
                        DateSeparatorView(timestamp: timestamp)
                            .padding(.top, isFirst ? 2 : 8)
                            .padding(.bottom, 1)
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
                            queueOrder: queueOrderByID[item.id],
                            canToggleQueue: canToggleQueue,
                            isFavorite: backend.favoriteIds.contains(item.id),
                            isEditingRemark: editingItemId == item.id,
                            editingText: $editingText,
                            searchQuery: effectiveSearchText,
                            onToggleQueue: {
                                withAnimation(AppleMotion.snappy) {
                                    PasteQueueManager.shared.toggle(item)
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                OnboardingGuide.shared.record(.queueToggled)
                            },
                            onCommitRemark: { newText in
                                commitInlineEditing(entryId: item.id, newText: newText)
                            },
                            onCancelRemark: {
                                cancelInlineEditing()
                            },
                            selectionNamespace: selectionNamespace
                        )
                        .equatable()
                        .onDrag({
                            dragProvider(item: item, batch: batchDragPlan(for: item))
                        }, preview: {
                            let plan = batchDragPlan(for: item)
                            DragChip(item: plan?.payload ?? item, count: plan?.count ?? 1)
                        })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if editingItemId == item.id { return }
                            if editingItemId != nil {
                                commitPendingInlineEdit()
                                return
                            }
                            if PasteQueueManager.shared.hasItems {
                                guard PasteDeliveryMode.current == .keystroke else { return }
                                withAnimation(AppleMotion.snappy) {
                                    PasteQueueManager.shared.toggle(item)
                                }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                OnboardingGuide.shared.record(.queueToggled)
                                return
                            }
                            selectItem(at: index)
                        }
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
            .animation(.spring(response: 0.18, dampingFraction: 0.82, blendDuration: 0),
                       value: selectedIndex)
            .animation(rowsReadyForAnimation
                       ? .spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0)
                       : nil,
                       value: backend.itemsGeneration)
        }
        .onPreferenceChange(RowFramePreferenceKey.self) { frames in
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

    private var popupRows: [PopupRow] { currentDisplayMemo.rows }

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

    private var queueBottomBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .font(.system(size: 10, weight: .bold))
                Text("已选 \(PasteQueueManager.shared.totalCount) 项")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(Color(nsColor: .controlAccentColor))

            Spacer()

            if PasteQueueManager.shared.totalCount > 1 {
                Text("拖拽整组发送")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(theme.popupPrimaryText)
                Text("·")
                    .foregroundColor(theme.popupMutedText)
            }
            Text("勾选或按 ⌘C 标记")
                .font(.system(size: 9.5))
                .foregroundColor(theme.popupMutedText)
            Text("·")
                .foregroundColor(theme.popupMutedText)
            Text("⏎ 开始顺序粘贴")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(theme.popupPrimaryText)
            Text("·")
                .foregroundColor(theme.popupMutedText)
            Text("⎋ 清空")
                .font(.system(size: 9.5))
                .foregroundColor(theme.popupSecondaryText)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlAccentColor).opacity(0.12))
        )
    }

    private var bottomBar: some View {
        Group {
            if PasteQueueManager.shared.hasItems {
                queueBottomBar
            } else {
                normalBottomBar
            }
        }
    }

    private var normalBottomBar: some View {
        let memo = currentDisplayMemo
        return HStack(spacing: 0) {
            Text("\(memo.items.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.popupSecondaryText)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.18), value: memo.items.count)
                .drawingGroup()
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

            if isCommandPressed {
                if PasteDeliveryMode.current == .keystroke {
                    shortcutHint(key: "⌘C", label: "批量入队/发送")
                }
                shortcutHint(key: "⌘1~9", label: "快速选择")
                shortcutHint(key: "⌘Z", label: "撤销")
            } else {
                shortcutHint(key: "⌥P", label: "收藏/取消")
                shortcutHint(key: "Space", label: "预览")
                shortcutHint(key: "⌃⌫", label: "删除")
                shortcutHint(key: "⌘Z", label: "撤销")
                shortcutHint(key: "⌘1~9", label: "快速选择")
                shortcutHint(key: "右键", label: "菜单")
            }
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
