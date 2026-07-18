import AppKit
import SwiftUI

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
        ClipboardBackend.shared.clearThumbnailCache()
        super.close()
        self.contentView = nil
        self.alphaValue = 1.0 // reset for next open
    }
}

/// NSHostingView subclass that accepts first responder for keyboard events
class PopupHostingView: NSHostingView<HistoryPopupContent> {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.control) {
                NotificationCenter.default.post(name: deleteKeyNotification, object: nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        NotificationCenter.default.post(name: controlKeyNotification, object: controlPressed)
        super.flagsChanged(with: event)
    }
}

private let deleteKeyNotification = Notification.Name("PopupDeleteKeyPressed")
private let controlKeyNotification = Notification.Name("PopupControlKeyChanged")

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0  // 0 = search bar, 1+ = items
    @State private var showPreview: Bool = false
    @State private var isControlPressed: Bool = false
    @State private var searchText: String = ""
    @State private var effectiveSearchText: String = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var scrollTarget: Int?

    // Spotlight opening animation: start slightly larger, spring in
    @State private var openingScale: CGFloat = 1.10

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isContainerFocused: Bool

    /// Items filtered by search text. When effectiveSearchText is empty, returns all items.
    private var filteredItems: [ClipboardItem] {
        guard !effectiveSearchText.isEmpty else { return backend.items }
        return backend.items.filter {
            $0.label.localizedCaseInsensitiveContains(effectiveSearchText) ||
            $0.sourceName.localizedCaseInsensitiveContains(effectiveSearchText) ||
            $0.fullText.localizedCaseInsensitiveContains(effectiveSearchText)
        }
    }

    /// The highest valid selectedIndex (search bar + item count).
    private var maxIndex: Int { filteredItems.count }

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

                    if filteredItems.isEmpty && !effectiveSearchText.isEmpty {
                        noResultsView
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
            if selectedIndex == 0 { return .handled }
            togglePreview()
            return .handled
        }
        .onAppear {
            selectedIndex = 0
            searchText = ""
            isControlPressed = NSEvent.modifierFlags.contains(.control)

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

            // Focus search field after animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + animDuration + 0.05) {
                isSearchFocused = true
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
        .onChange(of: searchText) { _, newValue in
            selectedIndex = 0
            searchTask?.cancel()
            if newValue.isEmpty {
                withAnimation(.easeInOut(duration: 0.12)) {
                    effectiveSearchText = ""
                }
                scrollTarget = filteredItems.first?.id
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        effectiveSearchText = newValue
                    }
                    if selectedIndex == 0 {
                        scrollTarget = filteredItems.first?.id
                    }
                }
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            if newValue == 0 {
                isSearchFocused = true
                isContainerFocused = false
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

    // MARK: - Preview Management

    private func togglePreview() {
        if showPreview { closePreview() } else { openPreview() }
    }

    private func openPreview() {
        let itemIndex = selectedIndex - 1
        guard itemIndex < filteredItems.count, let popup = popupWindow else { return }
        let item = filteredItems[itemIndex]
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
        guard showPreview, itemIndex >= 0, itemIndex < filteredItems.count,
              let preview = popupWindow?.previewPanel else { return }
        guard let previewItem = fullTextItem(filteredItems[itemIndex]) else {
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
            if effectiveSearchText.isEmpty {
                Text("\(backend.items.count) 项")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text("\(filteredItems.count)/\(backend.items.count) 项")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            let textCount = filteredItems.filter { $0.isText }.count
            let imageCount = filteredItems.filter { $0.isImage }.count
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
                    if !filteredItems.isEmpty {
                        scrollTarget = filteredItems[0].id
                    }
                    return
                }
                let itemIndex = newValue - 1
                if itemIndex < filteredItems.count {
                    scrollTarget = filteredItems[itemIndex].id
                }
                updatePreviewContent()
            }
    }

    private var itemsListScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                    ItemRowView(
                        item: item,
                        isSelected: selectedIndex == index + 1,
                        isDeleteModifierPressed: isControlPressed
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
        guard index < filteredItems.count else { return }
        let item = filteredItems[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        closePreview()
        guard backend.deleteEntry(at: backendIdx) else { return }
        if backend.items.isEmpty {
            selectedIndex = 0
            searchText = ""
        } else if selectedIndex > maxIndex {
            selectedIndex = max(0, maxIndex)
        }
    }

    private func selectItem(at index: Int) {
        guard index < filteredItems.count else { return }
        let item = filteredItems[index]
        guard let backendIdx = backend.items.firstIndex(where: { $0.id == item.id }) else { return }
        if backend.selectAndPaste(at: backendIdx) {
            closePreview()
            onClose()
        }
    }
}

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isDeleteModifierPressed: Bool
    @State private var isHovering = false

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
            if isSelected && isDeleteModifierPressed {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white)
                    .frame(minWidth: 20, alignment: .center)
                    .padding(.trailing, 6)
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
        let displayText = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "⏎")
        let display: String
        let visualLen = visualWidth(displayText)
        if visualLen > 60 {
            let prefix = String(displayText.prefix(whileVisualWidth: 30))
            let suffix = String(displayText.suffix(whileVisualWidth: 30))
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
        let pattern = try! NSRegularExpression(pattern: "#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\b")
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: nsRange)

        if matches.isEmpty { return Text(text) }

        var result = Text("")
        var lastEnd = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            // Text before this color code
            if lastEnd < range.lowerBound {
                result = result + Text(String(text[lastEnd..<range.lowerBound]))
            }
            // Color code with swatch
            let code = String(text[range])
            if let color = parseHexColor(code),
               let swatch = createColorSwatchImage(color) {
                result = result + Text(Image(nsImage: swatch)) + Text(code)
            } else {
                result = result + Text(code)
            }
            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            result = result + Text(String(text[lastEnd...]))
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
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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
