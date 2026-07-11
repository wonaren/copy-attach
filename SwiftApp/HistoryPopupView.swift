import AppKit
import SwiftUI

/// The floating overlay window that shows clipboard history
class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    private init() {
        let screenSize = NSScreen.main?.frame.size ?? NSSize(width: 800, height: 600)
        let popupWidth: CGFloat = 520
        let popupHeight: CGFloat = 620
        let x = (screenSize.width - popupWidth) / 2
        let y = (screenSize.height - popupHeight) / 2

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
        self.title = "剪贴板历史"
        self.isMovableByWindowBackground = true
    }
    
    override var canBecomeKey: Bool {
        return true
    }

    func show() {
        debugLog("HistoryPopupWindow.show() called")
        
        let contentView = HistoryPopupContent(onClose: { [weak self] in
            debugLog("HistoryPopupContent onClose callback")
            self?.close()
        })
        let hosting = PopupHostingView(rootView: contentView)
        let contentRect = self.contentRect(forFrameRect: self.frame)
        hosting.frame = contentRect
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
        // Order front regardless of app activation state
        self.orderFrontRegardless()
        self.makeKey()
        debugLog("Window made key and ordered front. IsVisible: \(self.isVisible) IsKeyWindow: \(self.isKeyWindow)")

        // Give the hosting view keyboard focus
        DispatchQueue.main.async {
            let firstResp = self.makeFirstResponder(hosting)
            debugLog("makeFirstResponder returned: \(firstResp)")
            let became = hosting.becomeFirstResponder()
            debugLog("hosting.becomeFirstResponder returned: \(became)")
            debugLog("Current first responder: \(String(describing: self.firstResponder))")
        }
        
        // Auto-close when window loses key status (user clicks outside / switches app)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didResignKey),
            name: NSWindow.didResignKeyNotification,
            object: self
        )
    }
    
    @objc private func didResignKey(_ notification: Notification) {
        debugLog("Popup resigned key, closing")
        self.close()
    }

    override func close() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: self)
        super.close()
        self.contentView = nil
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
}

// MARK: - SwiftUI Content for Popup

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Background
            Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 0.96))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 4)

            VStack(spacing: 0) {
                // Title bar
                titleBar
                divider
                itemCountBar
                divider

                // Items list
                itemsList
            }
            .padding(8)
        }
        .frame(width: 504, height: 604)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
                hoveredIndex = nil
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < backend.items.count - 1 {
                selectedIndex += 1
                hoveredIndex = nil
            }
            return .handled
        }
        .onKeyPress(.return) {
            let targetIndex = hoveredIndex ?? selectedIndex
            if targetIndex < backend.items.count {
                selectItem(at: targetIndex)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onAppear {
            selectedIndex = 0
            // Become focused to receive key events
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Image(nsImage: .appIcon)
                .resizable()
                .frame(width: 24, height: 24)
            Text("剪贴板历史")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: .lightGray))

            Spacer()

            Button(action: onClose) {
                Text("✕")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .darkGray).opacity(0.5))
            .frame(height: 1)
    }

    // MARK: - Item Count Bar

    private var itemCountBar: some View {
        HStack {
            let textCount = backend.items.filter { $0.isText }.count
            let imageCount = backend.items.filter { $0.isImage }.count
            Text("\(backend.items.count) 项 (\(textCount) 文本, \(imageCount) 图片)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Spacer()
            if !backend.items.isEmpty {
                Button(role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "清除所有剪贴板历史?"
                    alert.informativeText = "此操作会删除所有已保存的记录，且无法撤销。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "确认清除")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        backend.clearHistory()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除所有历史记录")
                .padding(.trailing, 8)
            }
        }
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(backend.items.enumerated()), id: \.element.id) { index, item in
                        ItemRowView(
                            item: item,
                            isSelected: index == selectedIndex,
                            isHovered: index == hoveredIndex
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            selectItem(at: index)
                        }
                        .onHover { hovering in
                            hoveredIndex = hovering ? index : nil
                        }
                        .id(index)
                    }
                }
                .padding(4)
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    // MARK: - Actions

    private func selectItem(at index: Int) {
        if backend.selectAndPaste(at: index) {
            onClose()
        }
    }
}

// MARK: - Item Row View

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // App icon
            appIcon

            // Content
            VStack(alignment: .leading, spacing: 2) {
                switch item {
                case .text(_, let text, _, _, _, _):
                    textContent(text)
                case .image(_, let thumbData, let width, let height, _, _, _, _):
                    imageContent(thumbData: thumbData, width: width, height: height)
                }
                // Source app name
                if !item.sourceName.isEmpty {
                    Text(item.sourceName)
                        .font(.system(size: 9))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.blue.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
    }

    private var appIcon: some View {
        VStack {
            if !item.sourceBundleId.isEmpty, let nsImage = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .cornerRadius(4)
            } else {
                // Default icon when no source app info
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .frame(width: 24, height: 24)
        .padding(.top, 2)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: NSColor(calibratedRed: 0.24, green: 0.39, blue: 0.71, alpha: 1.0))
        } else if isHovered {
            return Color(nsColor: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1.0))
        } else {
            return Color(nsColor: NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.165, alpha: 1.0))
        }
    }

    private func textContent(_ text: String) -> some View {
        let preview = truncateText(text, maxLength: 200)
        return Text(preview)
            .font(.system(size: 12))
            .foregroundColor(isSelected ? .white : Color(nsColor: .lightGray))
            .lineLimit(2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageContent(thumbData: Data, width: Int, height: Int) -> some View {
        HStack(spacing: 10) {
            if let nsImage = NSImage(data: thumbData) {
                let imageHeight: CGFloat = 60
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: imageHeight)
                    .cornerRadius(4)
            } else {
                Text("📷")
                    .font(.system(size: 20))
                    .frame(height: 60)
            }
        }
    }

    private func truncateText(_ text: String, maxLength: Int) -> String {
        let lines: [String] = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Take first two non-empty lines for increased density
        let preview: String
        if lines.count >= 2 {
            preview = lines[0] + "\n" + lines[1]
        } else if lines.count == 1 {
            preview = lines[0]
        } else {
            preview = text.trimmingCharacters(in: .whitespaces)
        }

        if preview.count <= maxLength {
            return preview
        }

        let truncated = String(preview.prefix(maxLength - 1))
        // Try to break at word boundary
        if let lastSpace = truncated.lastIndex(of: " "), lastSpace.utf16Offset(in: truncated) > maxLength / 2 {
            return String(truncated[...lastSpace]) + "…"
        }
        return truncated + "…"
    }
}
