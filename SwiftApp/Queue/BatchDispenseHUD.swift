import AppKit
import SwiftUI

final class BatchDispenseHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pill that reports batch-dispatch progress after a batch drag.
///
/// Separate window and separate model from `PasteQueueHUDWindow`: the queue's
/// pill is driven by `PasteQueueManager.status` (⌘V-paced dispensing) and mixing
/// the two state machines in one window makes each one's teardown depend on the
/// other's.
@MainActor
final class BatchDispenseHUDWindow: NSPanel {
    static let shared = BatchDispenseHUDWindow()

    static let pillSize = NSSize(width: 268, height: 36)
    /// Transparent margin so the SwiftUI drop shadow is not clipped.
    static let windowPadding: CGFloat = 14
    static var windowSize: NSSize {
        NSSize(width: pillSize.width + windowPadding * 2, height: pillSize.height + windowPadding * 2)
    }

    private var hostingView: BatchDispenseHostingView?
    private var visibilityGeneration: UInt64 = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        // Same contract as the queue pill: a status indicator, never a click sink.
        ignoresMouseEvents = true
    }

    func show() {
        visibilityGeneration &+= 1

        let content = AnyView(BatchDispenseHUDView().withAppTheme())
        if hostingView == nil {
            let host = BatchDispenseHostingView(rootView: content)
            contentView = host
            hostingView = host
        } else {
            hostingView?.rootView = content
        }

        if !isVisible {
            positionAtTopCenter()
            alphaValue = 0
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
    }

    func dismiss() {
        visibilityGeneration &+= 1
        let generation = visibilityGeneration

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
                self.contentView = nil
                self.hostingView = nil
            }
        })
    }

    private func positionAtTopCenter() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (Self.windowSize.width / 2)
        let y = visibleFrame.maxY - Self.windowSize.height - 12
        setFrame(NSRect(x: x, y: y, width: Self.windowSize.width, height: Self.windowSize.height), display: true)
    }
}

struct BatchDispenseHUDView: View {
    private var runner: BatchDispenseRunner { .shared }
    private var notice: BatchHUDNotice { .shared }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 14)
        .frame(width: BatchDispenseHUDWindow.pillSize.width, height: BatchDispenseHUDWindow.pillSize.height)
        .background(
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(colorScheme == .dark ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
                Capsule().strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                    lineWidth: 0.5
                )
            }
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 8, x: 0, y: 3)
        .padding(BatchDispenseHUDWindow.windowPadding)
        .animation(.easeOut(duration: 0.16), value: runner.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .running(let sent, let total):
            Text("\(min(sent + 1, total))/\(total)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color(nsColor: .controlAccentColor)))
                .contentTransition(.numericText())
            Text("批量粘贴")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(theme.popupPrimaryText)
            progressBar(sent: sent, total: total)
            Spacer(minLength: 0)
            Text(sent >= total ? "完成" : "自动")
                .font(.system(size: 9))
                .foregroundColor(theme.popupMutedText)

        case .finished(let sent, let total, let finishedNotice):
            Image(systemName: finishedNotice == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(finishedNotice == nil
                                 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
            Text(finishedNotice == nil ? "已发送 \(sent)/\(total)" : finishedNotice ?? "")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(finishedNotice == nil ? theme.popupPrimaryText : Color(nsColor: .systemOrange))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(sent)/\(total)")
                .font(.system(size: 9))
                .foregroundColor(theme.popupMutedText)

        case .idle:
            if let text = notice.text {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(nsColor: .systemOrange))
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func progressBar(sent: Int, total: Int) -> some View {
        let fraction = total > 0 ? min(1, Double(sent) / Double(total)) : 0
        return Capsule()
            .fill(theme.popupMutedText.opacity(0.35))
            .frame(width: 64, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: max(2, 64 * fraction), height: 3)
            }
    }
}
