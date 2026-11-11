import AppKit
import SwiftUI

@MainActor
final class UpdateCompleteWindow: NSPanel {
    static let shared = UpdateCompleteWindow()

    static let width: CGFloat = 380

    private var hostingView: NSHostingView<AnyView>?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        animationBehavior = .none
    }

    func show(version: String, notes: String?) {
        let content = AnyView(
            UpdateCompleteView(version: version, notes: notes) { [weak self] in
                self?.dismiss()
            }
            .withAppTheme()
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            contentView = host
            hostingView = host
        }

        hostingView?.layoutSubtreeIfNeeded()
        let fitting = hostingView?.fittingSize ?? NSSize(width: Self.width, height: 200)
        let size = NSSize(width: Self.width, height: max(fitting.height, 120))
        setContentSize(size)
        centerOnScreen(size: size)

        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.contentView = nil
                self?.hostingView = nil
            }
        })
    }

    private func centerOnScreen(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                               y: frame.midY - size.height / 2))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
            return
        }
        super.keyDown(with: event)
    }
}

private struct UpdateCompleteView: View {
    let version: String
    let notes: String?
    let onClose: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.updateActionBackground)
                Text("已更新到 v\(version)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.popupPrimaryText)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.popupMutedText)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(theme.popupRowHover))
                }
                .buttonStyle(AppleTactileButtonStyle(scale: 0.9))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let notes, !notes.isEmpty {
                Divider()
                    .overlay(theme.popupRowBorder)
                ScrollView {
                    Text(notes)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.popupSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .frame(maxHeight: 220)
            } else {
                Text("更新日志暂不可用。")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.popupMutedText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .frame(width: UpdateCompleteWindow.width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.popupBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.popupRowBorder, lineWidth: 1)
                )
        )
    }
}
