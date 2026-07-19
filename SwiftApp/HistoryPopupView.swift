import AppKit
import SwiftUI

// MARK: - Filter Mode

enum FilterMode: String, CaseIterable {
    case favorites
    case all

    var icon: String {
        switch self {
        case .favorites: return "star.fill"
        case .all: return "line.3.horizontal"
        }
    }
}

// MARK: - History Popup Window (NSPanel)

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    /// Non-key preview panel managed by the popup content.
    weak var previewPanel: PreviewWindow?

    private init() {
        // Match show() — use visibleFrame so first-open position matches
        // subsequent repositioning. Using frame.size (full screen) would
        // place the popup at a different y (menu bar not accounted for),
        // misaligning it with the preview window which uses visibleFrame.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let popupWidth: CGFloat = 520
        let popupHeight: CGFloat = 744
        let x = screenFrame.origin.x + (screenFrame.size.width - popupWidth) / 2
        let y = screenFrame.origin.y + (screenFrame.size.height - popupHeight) / 2

        super.init(
            contentRect: NSRect(x: x, y: y, width: popupWidth, height: popupHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hasShadow = true
        self.title = "CopyAttach"
        self.isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { return true }

    func show() {
        debugLog("HistoryPopupWindow.show() called")

        let contentView = HistoryPopupContent(onClose: { [weak self] in
            debugLog("HistoryPopupContent onClose callback")
            self?.close()
        })
        let hosting = PopupHostingView(rootView: contentView)
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect

        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.cornerCurve = .continuous

        self.contentView = hosting

        // Position at center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = self.frame
            let x = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2
            let y = screenFrame.origin.y + (screenFrame.size.height - windowFrame.size.height) / 2
            self.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.level = .floating

        // Start invisible: window alpha handles the entire fade (including shadow),
        // while SwiftUI handles the scale pop. Together they match Spotlight's
        // unified window + content appearance.
        self.alphaValue = 0
        self.orderFrontRegardless()
        self.makeKey()

        // Give the hosting view keyboard focus
        DispatchQueue.main.async {
            _ = self.makeFirstResponder(hosting)
            _ = hosting.becomeFirstResponder()
        }

        // Auto-close when window loses key status (click outside)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }

    @objc private func didResignKey(_ notification: Notification) {
        debugLog("Popup resigned key, animated close")
        closeWithAnimation()
    }

    /// Animated close: popup fades → preview fades → both close.
    func closeWithAnimation() {
        let preview = previewPanel
        previewPanel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if let pv = preview {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.1
                    pv.animator().alphaValue = 0
                }, completionHandler: {
                    pv.close()
                    self.close()
                })
            } else {
                self.close()
            }
        })
    }

    override func close() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        previewPanel?.close()
        previewPanel = nil
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0 // reset for next open
    }
}

/// NSHostingView subclass that accepts first responder for keyboard events
class PopupHostingView: NSHostingView<HistoryPopupContent> {
    override var acceptsFirstResponder: Bool { true }

    /// Local event monitor to intercept ←/→ from the empty search field
    /// before NSTextView swallows them for cursor movement.
    private var arrowMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            installArrowMonitor()
        } else {
            removeArrowMonitor()
        }
    }

    private func installArrowMonitor() {
        removeArrowMonitor()
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 123 || event.keyCode == 124 else { return event }
            // Only intercept when the search field (editable NSTextView) is
            // first responder and its string is empty — no cursor to move.
            guard let self = self,
                  let textView = self.window?.firstResponder as? NSTextView,
                  textView.isEditable,
                  textView.string.isEmpty else { return event }
            let direction: String = event.keyCode == 123 ? "left" : "right"
            NotificationCenter.default.post(name: arrowKeyFromSearchNotification, object: direction)
            return nil
        }
    }

    private func removeArrowMonitor() {
        if let monitor = arrowMonitor {
            NSEvent.removeMonitor(monitor)
            arrowMonitor = nil
        }
    }

    deinit {
        removeArrowMonitor()
    }

    /// Intercept ⌘Z before the search field's NSTextView swallows it for text undo.
    /// This catches the key-equivalent event regardless of which responder is first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 6 && event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Option + P: toggle favorite (must intercept before text input
        // system converts it to π character)
        if event.keyCode == 35 && event.modifierFlags.contains(.option) &&
            !event.modifierFlags.contains(.command) &&
            !event.modifierFlags.contains(.control) &&
            !event.modifierFlags.contains(.shift) {
            // Let the event pass through when the search bar is focused
            // so the user can type characters like π via Opt+P.
            if let textView = window?.firstResponder as? NSTextView, textView.isEditable {
                super.keyDown(with: event)
                return
            }
            NotificationCenter.default.post(name: favoriteToggleNotification, object: nil)
            return
        }

        // Command + number (1-9): quick select item
        if event.modifierFlags.contains(.command) {
            let keyCode = event.keyCode
            // kVK_ANSI_1=18 ... kVK_ANSI_9=26
            if keyCode >= 18 && keyCode <= 26 {
                let number = Int(keyCode - 18 + 1)
                NotificationCenter.default.post(name: commandNumberNotification, object: number)
                return
            }
        }
        // Control + Delete: delete item
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.control) {
                NotificationCenter.default.post(name: deleteKeyNotification, object: nil)
                return
            }
        }

        // Command + Z: undo deletion
        if event.keyCode == 6 && event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: undoKeyNotification, object: nil)
            return
        }

        // Printable character while on an item: switch focus to search bar
        // and re-send the event so the search field's IME can process it
        // (e.g. Chinese/Japanese IME composition).
        if let chars = event.characters,
           let first = chars.first,
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           (first.isLetter || first.isNumber || first.isPunctuation)
        {
            NotificationCenter.default.post(name: focusSearchNotification, object: nil)
            // After focus switches to search bar, re-send the original event
            // so the search field's NSTextView handles it with full IME support.
            // Use a weak reference to self.window rather than NSApp.keyWindow
            // to prevent keystroke injection into other apps if the popup
            // loses key status during the async gap.
            weak let popupWindow = self.window
            DispatchQueue.main.async { [event] in
                popupWindow?.firstResponder?.keyDown(with: event)
            }
            return
        }

        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        NotificationCenter.default.post(name: controlKeyNotification, object: controlPressed)

        let commandPressed = event.modifierFlags.contains(.command)
        NotificationCenter.default.post(name: commandKeyNotification, object: commandPressed)

        super.flagsChanged(with: event)
    }
}

private let deleteKeyNotification = Notification.Name("PopupDeleteKeyPressed")
private let controlKeyNotification = Notification.Name("PopupControlKeyChanged")
private let commandKeyNotification = Notification.Name("PopupCommandKeyChanged")
private let commandNumberNotification = Notification.Name("PopupCommandNumberPressed")
private let focusSearchNotification = Notification.Name("PopupFocusSearch")
private let undoKeyNotification = Notification.Name("PopupUndoKeyPressed")
private let favoriteToggleNotification = Notification.Name("PopupFavoriteToggle")
private let arrowKeyFromSearchNotification = Notification.Name("PopupArrowKeyFromSearch")

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0  // 0 = search bar, 1+ = items
    @State private var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var isCommandPressed: Bool = false
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
    private var displayItems: [ClipboardItem] {
        let base = effectiveSearchText.isEmpty ? backend.items : searchResults
        switch filterMode {
        case .all:
            return base
        case .favorites:
            return base.filter { backend.favoriteIds.contains($0.id) }
        }
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
            Color.black.opacity(0.8)
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
                    } else {
                        itemsList
                        itemCountBar
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
                if selectedIndex == 0 {
                    isSearchFocused = true
                } else {
                    isContainerFocused = true
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
            if selectedIndex > 0 {
                deleteItem(at: selectedIndex - 1)
            }
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
            scrollTarget = displayItems.first?.id
        }
        .onChange(of: searchText) { _, newValue in
            selectedIndex = 0
            searchTask?.cancel()
            if newValue.isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) {
                    effectiveSearchText = ""
                }
                searchResults = []
                scrollTarget = displayItems.first?.id
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
                        $0.fullText.localizedCaseInsensitiveContains(newValue)
                    }
                }.value

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        effectiveSearchText = newValue
                        searchResults = filtered
                    }
                    if selectedIndex == 0 {
                        scrollTarget = displayItems.first?.id
                    }
                }
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            if newValue == 0 {
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
                .foregroundColor(.white.opacity(0.45))

            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.9))

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    selectedIndex == 0
                        ? Color(nsColor: .controlAccentColor)
                        : Color.white.opacity(0.08),
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
                .foregroundColor(.white.opacity(0.2))
            Text("无匹配结果")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.35))
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
                            : .white.opacity(0.45))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(mode == filterMode
                                    ? Color(nsColor: .controlAccentColor).opacity(0.15)
                                    : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    mode == filterMode
                                        ? Color(nsColor: .controlAccentColor).opacity(0.3)
                                        : Color.white.opacity(0.06),
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
                .foregroundColor(.white.opacity(0.2))
            Text("暂无收藏")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.35))
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

    // MARK: - Item Count Bar

    private var itemCountBar: some View {
        HStack(spacing: 4) {
            Text("\(displayItems.count) 项")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            if !effectiveSearchText.isEmpty {
                Text("/ \(backend.items.count) 项")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            let textCount = displayItems.filter { $0.isText }.count
            let imageCount = displayItems.filter { $0.isImage }.count
            Text("\(textCount) 文本")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Text("\(imageCount) 图片")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
                    scrollTarget = displayItems[itemIndex].id
                }
                updatePreviewContent()
            }
    }

    private var itemsListScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
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
            .padding(.all, 2)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Empty State

    /// SVG image shown when clipboard history is empty.
    private var emptyStateImage: NSImage? {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">
          <defs>
            <style>
              .bg { fill: rgba(255,255,255,0.06); }
              .icon { fill: none; stroke: rgba(255,255,255,0.15); stroke-width: 2; stroke-linejoin: round; }
              .line { fill: none; stroke: rgba(255,255,255,0.08); stroke-width: 2; stroke-linecap: round; }
              .text { fill: rgba(255,255,255,0.40); font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; font-size: 22px; text-anchor: middle; }
            </style>
          </defs>
          <!-- Clipboard body -->
          <rect class="icon" x="140" y="20" width="120" height="160" rx="14"/>
          <!-- Clip -->
          <rect class="bg" x="160" y="12" width="80" height="18" rx="6"/>
          <!-- Text lines -->
          <line class="line" x1="160" y1="60" x2="240" y2="60"/>
          <line class="line" x1="160" y1="85" x2="240" y2="85"/>
          <line class="line" x1="160" y1="110" x2="240" y2="110"/>
          <line class="line" x1="160" y1="135" x2="215" y2="135"/>
          <!-- Text -->
          <text class="text" x="200" y="240">剪贴板记录为空</text>
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }

    private var emptyStateView: some View {
        VStack(spacing: 0) {
            Spacer()
            if let nsImage = emptyStateImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 320, height: 240)
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func deleteItem(at index: Int) {
        guard index < displayItems.count else { return }
        let item = displayItems[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        closePreview()
        var deleted = false
        withAnimation(.easeInOut(duration: 0.2)) {
            deleted = backend.deleteEntry(at: backendIdx)
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
        guard index < displayItems.count else { return }
        let item = displayItems[index]
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
                self.scrollTarget = self.displayItems.first?.id
            }
        }
    }
}

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    let shortcutHint: String?
    let isFavorite: Bool
    @State private var isHovering = false

    private static let hexColorRegex = try! NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")

    private func textColor(_ isSelected: Bool) -> Color {
        isSelected ? Color.white : Color.white.opacity(0.9)
    }
    private let mutedText = Color.white.opacity(0.6)
    private func sourceNameColor(_ isSelected: Bool) -> Color {
        isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.7)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            appIcon
            VStack(alignment: .leading, spacing: 0) {
                switch item {
                case .text(_, _, _, _, _, _, let fullText):
                    textContent(fullText)
                case .image(_, let dbId, let width, let height, _, _, _, _):
                    imageContent(dbId: dbId, width: width, height: height)
                }
            }
            Spacer(minLength: 2)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemYellow))
                    .frame(width: 16, alignment: .center)
                    .transition(.scale.combined(with: .opacity))
            }
            if isSelected && isDeleteModifierPressed {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white)
                    .frame(minWidth: 20, alignment: .center)
                    .padding(.trailing, 6)
                    .transition(.scale.combined(with: .opacity))
            } else if let hint = shortcutHint {
                Text(hint)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? sourceNameColor(true) : Color(nsColor: .controlAccentColor))
                    .lineLimit(1)
                    .monospacedDigit()
                    .transition(.scale.combined(with: .opacity))
            } else if !item.sourceName.isEmpty {
                Text(item.sourceName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(sourceNameColor(isSelected))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.black.opacity(0.2)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .background(rowBackground)
        .overlay(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isDeleteModifierPressed ? Color(nsColor: .systemRed) : Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.8), lineWidth: 1)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected && isDeleteModifierPressed { Color(nsColor: .systemRed) }
            else if isSelected { Color(nsColor: .controlAccentColor) }
            else if isHovering { Color.white.opacity(0.1) }
            else { Color(nsColor: .windowBackgroundColor).opacity(0.04) }
        }
    }

    private var appIcon: some View {
        Group {
            if !item.sourceBundleId.isEmpty, let nsImage = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: nsImage).resizable().frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Image(systemName: "app.fill").resizable().frame(width: 14, height: 14)
                    .foregroundColor(mutedText.opacity(0.5))
            }
        }
        .frame(width: 20, height: 20).foregroundColor(.white)
    }

    private func textContent(_ text: String) -> some View {
        // Early truncation: process at most 200 chars from the full text.
        // The display text after filtering is at most ~60 visual chars (30 CJK).
        // 200 is a safe upper bound that avoids O(n) processing of multi-KB text.
        let displayText = String(text.prefix(200))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "⏎")
        let display: String
        let visualLen = visualWidth(displayText)
        if visualLen > 50 {
            let prefix = String(displayText.prefix(whileVisualWidth: 25))
            let suffix = String(displayText.suffix(whileVisualWidth: 25))
            display = "\(prefix)……\(suffix)"
        } else { display = displayText }
        return coloredLabel(display)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(textColor(isSelected))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Build a Text view with inline color swatches for hex color codes.
    private func coloredLabel(_ text: String) -> Text {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = Self.hexColorRegex.matches(in: text, range: nsRange)

        if matches.isEmpty { return Text(text) }

        var result = Text("")
        var lastEnd = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            // Text before this color code
            if lastEnd < range.lowerBound {
                result = Text("\(result)\(String(text[lastEnd..<range.lowerBound]))")
            }
            // Color code with swatch
            let code = String(text[range])
            if let color = parseHexColor(code),
               let swatch = createColorSwatchImage(color) {
                result = Text("\(result)\(Image(nsImage: swatch))\(code)")
            } else {
                result = Text("\(result)\(code)")
            }
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            result = Text("\(result)\(String(text[lastEnd...]))")
        }

        return result
    }

    /// Parse a hex color string (#RGB or #RRGGBB) into NSColor.
    private func parseHexColor(_ hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard let value = UInt64(h, radix: 16) else { return nil }
        switch h.count {
        case 3:
            let r = CGFloat((value >> 8) & 0xF) / 15.0
            let g = CGFloat((value >> 4) & 0xF) / 15.0
            let b = CGFloat(value & 0xF) / 15.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        case 6:
            let r = CGFloat((value >> 16) & 0xFF) / 255.0
            let g = CGFloat((value >> 8) & 0xFF) / 255.0
            let b = CGFloat(value & 0xFF) / 255.0
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        default:
            return nil
        }
    }

    /// Create a small rounded square image filled with the given color.
    private func createColorSwatchImage(_ color: NSColor) -> NSImage? {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: 2, yRadius: 2)
        path.fill()
        image.unlockFocus()
        return image
    }

    private func imageContent(dbId: Int, width: Int, height: Int) -> some View {
        HStack(spacing: 8) {
            if let nsImage = ClipboardBackend.shared.getCachedThumbnail(dbId: dbId) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(mutedText.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(maxHeight: 100)
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            // Source: Image
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.system(size: 18))
                                    .foregroundColor(mutedText.opacity(0.8))
                            }
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(mutedText.opacity(0.15), lineWidth: 1)
                            )

                            // Flow/Processing Indicator
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(mutedText.opacity(0.5))
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(height: 10)
                            }

                            // Destination: Local
                            VStack(spacing: 4) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 18))
                                    .foregroundColor(mutedText.opacity(0.8))
                            }
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(mutedText.opacity(0.15), lineWidth: 1)
                            )
                        }
                        Text("图片编码中")
                            .font(.system(size: 11))
                            .foregroundColor(mutedText.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Large Text Preview (NSTextView-backed, non-contiguous layout)

struct LargeTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.95)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isHorizontallyResizable = false
        textView.textContainer!.widthTracksTextView = true
        textView.textContainer!.lineFragmentPadding = 0

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Force text view width to match scroll view's clip view width.
        // autoresizingMask + isHorizontallyResizable doesn't guarantee this
        // due to timing of makeNSView vs SwiftUI layout vs updateNSView.
        let clipWidth = scrollView.bounds.width
        textView.frame.size.width = clipWidth
        let inset = textView.textContainerInset
        textView.textContainer!.containerSize.width = clipWidth - inset.width * 2

        if textView.string != text {
            textView.string = text
        }
    }
}

// MARK: - Visual Width Helpers

private func visualWidth(_ s: String) -> Int {
    s.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
}

extension String {
    fileprivate func prefix(whileVisualWidth limit: Int) -> Substring {
        var w = 0
        return prefix(while: { char in
            let cw = char.isASCII ? 1 : 2
            defer { w += cw }
            return w + cw <= limit
        })
    }

    fileprivate func suffix(whileVisualWidth limit: Int) -> Substring {
        var w = 0
        let reversed = String(self.reversed())
        let taken = reversed.prefix(while: { char in
            let cw = char.isASCII ? 1 : 2
            defer { w += cw }
            return w + cw <= limit
        })
        return Substring(self.suffix(taken.count))
    }
}
