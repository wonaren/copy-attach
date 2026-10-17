import AppKit
import SwiftUI

/// Floating pill HUD that displays current queue progress and item preview.
struct PasteQueueHUDView: View {
    private var manager: PasteQueueManager { PasteQueueManager.shared }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if manager.isFinished {
                finishedView
            } else {
                activeQueueView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(width: PasteQueueHUDWindow.pillSize.width, height: PasteQueueHUDWindow.pillSize.height)
        .background(
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
                Capsule()
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 0.5)
            }
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 8, x: 0, y: 3)
        .padding(PasteQueueHUDWindow.windowPadding)
    }

    private var activeQueueView: some View {
        HStack(spacing: 8) {
            // Index Capsule Badge
            HStack(spacing: 1) {
                Text("\(manager.currentIndex + 1)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("/")
                    .font(.system(size: 10, weight: .regular))
                    .opacity(0.8)
                Text("\(manager.totalCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(Color(nsColor: .controlAccentColor))
            )

            // Item content preview
            if let item = manager.currentItem {
                HStack(spacing: 5) {
                    if item.isImage {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .systemOrange))
                        Text(item.preview)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(theme.popupPrimaryText)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.popupSecondaryText)
                        Text(item.displayPreview)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(theme.popupPrimaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(item.id)
            } else {
                Spacer()
            }

            // The HUD is click-through (see PasteQueueHUDWindow), so every
            // affordance must be a key and the pill must name them. A skipped
            // item's notice temporarily takes the hint's place.
            if let notice = manager.skippedNotice {
                Text(notice)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("⌘V 粘贴 · ⇧⌘V 跳过 · Esc×2 退出")
                    .font(.system(size: 9))
                    .foregroundColor(theme.popupMutedText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var finishedView: some View {
        HStack(spacing: 8) {
            Image(systemName: manager.failedSkipCount > 0
                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(manager.failedSkipCount > 0
                                 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                .symbolEffect(.bounce, value: manager.isFinished)
            Text(manager.failedSkipCount > 0
                 ? "已跳过 \(manager.failedSkipCount) 个失效项"
                 : "全部粘贴完成")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(manager.failedSkipCount > 0
                                 ? Color(nsColor: .systemOrange) : theme.popupPrimaryText)
            Spacer()
        }
        .transition(.appleScaleFade)
    }
}
