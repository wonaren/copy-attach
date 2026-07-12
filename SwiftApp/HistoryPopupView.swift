import AppKit
import SwiftUI

// MARK: - History Popup Window (NSPanel)

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

        // Enable layer-backed rendering with 22px rounded corners (native HUD look)
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 22
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

        // Auto-close when window loses key status
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

// MARK: - SwiftUI Content for Popup — Native HUD Aesthetic

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    // Design Tokens
    private let popupWidth: CGFloat = 500
    private let popupHeight: CGFloat = 600

    var body: some View {
        ZStack {
            // === Layer 0: Dark Translucent Background (HUD look) ===
            Color.black.opacity(0.8)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            // === Layer 1: Content ===
            VStack(spacing: 4) {
                // List of clipboard items
                itemsList
            }
            .padding(.all, 4) // unified padding
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
            onClose()
            return .handled
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) { // wider spacing for native feel
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
                .padding(.all, 4) // inner list padding
            }
            // Style the ScrollView itself as the main container
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.1), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scrollIndicators(.hidden)
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) {
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

// MARK: - Item Row View — Native HUD Pill Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool

    // Design Tokens
    private let whiteText = Color.white.opacity(0.9)
    private let mutedText = Color.white.opacity(0.6)

    var body: some View {
        HStack(alignment: .center, spacing: 4) { // Reduced spacing from 10 to 4
            // App icon
            appIcon

            // Content
            VStack(alignment: .leading, spacing: 0) {
                switch item {
                case .text(_, let text, _, _, _, _):
                    textContent(text)
                case .image(_, _, let thumbData, let width, let height, _, _, _, _):
                    imageContent(thumbData: thumbData, width: width, height: height)
                }
            }

            Spacer(minLength: 4)

            // Source app name
            if !item.sourceName.isEmpty {
                Text(item.sourceName)
                    .font(.system(size: 10, weight: .medium)) // Slightly reduced size
                    .foregroundColor(whiteText)
                    .lineLimit(1)
                    .padding(.horizontal, 4) // Reduced padding from 6 to 4
                    .padding(.vertical, 1.5) // Reduced padding from 2 to 1.5
                    .background(Capsule().fill(Color.black.opacity(0.2))) // background for label
            }
        }
        .padding(.horizontal, 6) // Reduced horizontal padding from 8 to 6
        .padding(.vertical, 5) // Reduced vertical padding from 6 to 5
        .background(rowBackground)
        .overlay(
            Group {
                if isSelected {
                    // Cleaner, solid focus border for selected item
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor).opacity(0.8), lineWidth: 1)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) // corner radius from item image
    }

    // MARK: - Row Background

    private var rowBackground: some View {
        Group {
            if isSelected {
                // Selected: System accent color
                Color(nsColor: .controlAccentColor)
            } else {
                // Default: Nearly transparent
                Color(nsColor: .windowBackgroundColor).opacity(0.04)
            }
        }
    }

    // MARK: - App Icon

    private var appIcon: some View {
        Group {
            if !item.sourceBundleId.isEmpty, let nsImage = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundColor(mutedText.opacity(0.5))
            }
        }
        .frame(width: 20, height: 20)
        .foregroundColor(.white) // fallback foreground for app icon
    }

    // MARK: - Text Content

    private func textContent(_ text: String) -> some View {
        let stripped = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let display: String
        let visualLen = visualWidth(stripped)
        if visualLen > 64 {
            let prefix = String(stripped.prefix(whileVisualWidth: 32))
            let suffix = String(stripped.suffix(whileVisualWidth: 32))
            display = "\(prefix)…\(suffix)"
        } else {
            display = stripped
        }

        return Text(display)
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .foregroundColor(whiteText) // user's image shows white text
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Image Content

    private func imageContent(thumbData: Data, width: Int, height: Int) -> some View {
        HStack(spacing: 8) {
            if let nsImage = NSImage(data: thumbData) {
                let imageHeight: CGFloat = 80
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: imageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundColor(mutedText)
                    .frame(height: 42)
            }
        }
    }
}

// MARK: - Visual Width Helpers

/// 1 for ASCII, 2 for CJK / fullwidth characters
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
