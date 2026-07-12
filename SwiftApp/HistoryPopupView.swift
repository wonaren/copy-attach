import AppKit
import SwiftUI

// MARK: - NSVisualEffectView Wrapper for SwiftUI (Liquid Glass Backdrop)

struct GlassBackdropView: NSViewRepresentable {
    private let material: NSVisualEffectView.Material
    private let blendingMode: NSVisualEffectView.BlendingMode

    init(material: NSVisualEffectView.Material = .hudWindow,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - History Popup Window (NSPanel) — Liquid Glass Panel

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
        // Force dark appearance for consistent glass rendering
        self.appearance = NSAppearance(named: .darkAqua)
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

        // Enable layer-backed rendering with 18px rounded corners for the glass panel
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = 18
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

// MARK: - SwiftUI Content for Popup — Liquid Glass Interface

struct HistoryPopupContent: View {
    let onClose: () -> Void

    @StateObject private var backend = ClipboardBackend.shared
    @State private var selectedIndex: Int = 0
    @State private var hoveredIndex: Int? = nil
    @FocusState private var isFocused: Bool

    // MARK: - DESIGN.md Color Constants

    private let actionBlue = Color(red: 0x00/255, green: 0x66/255, blue: 0xCC/255)      // #0066cc
    private let focusBlue  = Color(red: 0x00/255, green: 0x71/255, blue: 0xE3/255)      // #0071e3
    private let glassWhite = Color.white
    private let onDarkText = Color(white: 1.0)
    private let bodyMuted  = Color(white: 0.8)   // ~#cccccc
    private let finePrint  = Color(white: 0.55)  // ~#8a8a8a

    var body: some View {
        ZStack {
            // === Layer 0: Liquid Glass Backdrop ===
            GlassBackdropView()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // === Layer 1: Glass Edge Border (light refraction) ===
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            glassWhite.opacity(0.20),
                            glassWhite.opacity(0.05),
                            glassWhite.opacity(0.12),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )

            // === Layer 2: Content ===
            VStack(spacing: 0) {
                titleBar
                glassDivider
                itemCountBar
                glassDivider
                itemsList
            }
            .padding(4)
        }
        .frame(width: 508, height: 608)
        .focusable()
        .focusEffectDisabled()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    // MARK: - Title Bar (Liquid Glass)

    private var titleBar: some View {
        HStack(spacing: 8) {
            // App Icon
            Image(nsImage: .appIcon)
                .resizable()
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text("CopyAttach")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(onDarkText.opacity(0.9))

            Spacer()

            // Close Button — subtle glass chip
            Button(action: onClose) {
                ZStack {
                    Circle()
                        .fill(glassWhite.opacity(0.10))
                        .frame(width: 20, height: 20)

                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(onDarkText.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(glassWhite.opacity(0.06))
        )
    }

    // MARK: - Glass Divider

    private var glassDivider: some View {
        Rectangle()
            .fill(glassWhite.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 4)
    }

    // MARK: - Item Count Bar

    private var itemCountBar: some View {
        HStack(spacing: 6) {
            let textCount = backend.items.filter { $0.isText }.count
            let imageCount = backend.items.filter { $0.isImage }.count

            // Pill indicator for total count
            HStack(spacing: 4) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 9, weight: .medium))
                Text("\(backend.items.count)")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(bodyMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(glassWhite.opacity(0.07))
            )

            Text("\(textCount) 文本 · \(imageCount) 图片")
                .font(.system(size: 10))
                .foregroundColor(finePrint)

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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(finePrint)
                }
                .buttonStyle(.plain)
                .help("清除所有历史记录")
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Items List

    private var itemsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(backend.items.enumerated()), id: \.element.id) { index, item in
                        ItemRowView(
                            item: item,
                            isSelected: index == selectedIndex,
                            isHovered: index == hoveredIndex,
                            actionBlue: actionBlue,
                            focusBlue: focusBlue,
                            glassWhite: glassWhite,
                            onDarkText: onDarkText,
                            bodyMuted: bodyMuted,
                            finePrint: finePrint
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
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 4)
            }
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

// MARK: - Item Row View — Liquid Glass Aesthetic

struct ItemRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isHovered: Bool

    // Color tokens passed from parent to avoid recomputation
    let actionBlue: Color
    let focusBlue: Color
    let glassWhite: Color
    let onDarkText: Color
    let bodyMuted: Color
    let finePrint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
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

            Spacer(minLength: 2)

            // Source app name
            if !item.sourceName.isEmpty {
                Text(item.sourceName)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(finePrint)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(glassWhite.opacity(isSelected ? 0.15 : 0.06))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(rowBackground)
        .overlay(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    focusBlue.opacity(0.6),
                                    actionBlue.opacity(0.3),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Row Background & Border

    private var rowBackground: some View {
        Group {
            if isSelected {
                // Selected: Action Blue liquid glass fill
                actionBlue.opacity(0.35)
            } else if isHovered {
                // Hovered: subtle white glass highlight
                glassWhite.opacity(0.08)
            } else {
                // Default: nearly transparent — shows through to main glass backdrop
                Color.clear
            }
        }
    }

    // MARK: - App Icon

    private var appIcon: some View {
        Group {
            if !item.sourceBundleId.isEmpty, let nsImage = getAppIcon(for: item.sourceBundleId) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundColor(glassWhite.opacity(0.25))
            }
        }
        .frame(width: 18, height: 18)
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
            display = "\(prefix)……\(suffix)"
        } else {
            display = stripped
        }
        return Text(display)
            .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .foregroundColor(isSelected ? .white : onDarkText.opacity(0.85))
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
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(glassWhite.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(finePrint)
                    .frame(height: 42)
            }
        }
    }
}

// MARK: - Visual Width Helpers (unchanged from original)

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
