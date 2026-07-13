import AppKit
import SwiftUI

// MARK: - History Popup Window (NSPanel)

class HistoryPopupWindow: NSPanel {
    static let shared = HistoryPopupWindow()

    /// Non-key preview panel managed by the popup content.
    weak var previewPanel: PreviewWindow?

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
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }
}

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0
    @State private var showPreview: Bool = false
    @FocusState private var isFocused: Bool

    // Design Tokens
    private let popupWidth: CGFloat = 500
    private let popupHeight: CGFloat = 600

    private var popupWindow: HistoryPopupWindow? {
        NSApp.windows.first(where: { $0 is HistoryPopupWindow }) as? HistoryPopupWindow
    }

    var body: some View {
        ZStack {
            // === Layer 0: Dark Translucent Background (HUD look) ===
            Color.black.opacity(0.8)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            // === Layer 1: Content ===
            VStack(spacing: 4) {
                itemsList
            }
            .padding(.all, 3)
        }
        .frame(width: popupWidth, height: popupHeight)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < backend.items.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.return) {
            if selectedIndex < backend.items.count {
                selectItem(at: selectedIndex)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if showPreview {
                closePreview()
            } else {
                onClose()
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard selectedIndex < backend.items.count else { return .handled }
            togglePreview()
            return .handled
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onDisappear {
            closePreview()
        }
    }

    // MARK: - Preview Management

    private func togglePreview() {
        if showPreview {
            closePreview()
        } else {
            openPreview()
        }
    }

    private func openPreview() {
        guard selectedIndex < backend.items.count, let popup = popupWindow else { return }
        let item = backend.items[selectedIndex]
        let preview = PreviewWindow(item: item)
        popup.previewPanel = preview
        preview.orderFront(nil) // don't become key
        showPreview = true
    }

    private func closePreview() {
        guard showPreview else { return }
        showPreview = false
        popupWindow?.previewPanel?.close()
        popupWindow?.previewPanel = nil
    }

    private func updatePreviewContent() {
        guard showPreview, selectedIndex < backend.items.count,
              let preview = popupWindow?.previewPanel else { return }
        preview.updateContent(item: backend.items[selectedIndex])
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(backend.items.enumerated()), id: \.element.id) { index, item in
                        ItemRowView(
                            item: item,
                            isSelected: index == selectedIndex
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = index
                            selectItem(at: index)
                        }
                        .id(index)
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
            .scrollIndicators(.hidden)
            .onChange(of: selectedIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: .center)
                updatePreviewContent()
            }
        }
    }

    // MARK: - Actions

    private func selectItem(at index: Int) {
        if backend.selectAndPaste(at: index) {
            closePreview()
            onClose()
        }
    }
}

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool

    private let whiteText = Color.white.opacity(0.9)
    private let mutedText = Color.white.opacity(0.6)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            appIcon
            VStack(alignment: .leading, spacing: 0) {
                switch item {
                case .text(_, let text, _, _, _, _):
                    textContent(text)
                case .image(_, _, let thumbData, let width, let height, _, _, _, _):
                    imageContent(thumbData: thumbData, width: width, height: height)
                }
            }
            Spacer(minLength: 2)
            if !item.sourceName.isEmpty {
                Text(item.sourceName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(whiteText)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.black.opacity(0.2)))
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .background(rowBackground)
        .overlay(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.8), lineWidth: 1)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var rowBackground: some View {
        Group {
            if isSelected { Color(nsColor: .controlAccentColor) }
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
        let stripped = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let display: String
        let visualLen = visualWidth(stripped)
        if visualLen > 60 {
            let prefix = String(stripped.prefix(whileVisualWidth: 30))
            let suffix = String(stripped.suffix(whileVisualWidth: 30))
            display = "\(prefix)……\(suffix)"
        } else { display = stripped }
        return Text(display)
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .foregroundColor(whiteText).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageContent(thumbData: Data, width: Int, height: Int) -> some View {
        HStack(spacing: 8) {
            if let nsImage = NSImage(data: thumbData) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            } else {
                Image(systemName: "photo").font(.system(size: 16))
                    .foregroundColor(mutedText).frame(height: 42)
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
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.frame.width > 0 {
            textView.textContainer?.containerSize.width = textView.frame.width
        }
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
