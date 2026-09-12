import AppKit
import SwiftUI

// MARK: - Onboarding Stage

/// The tour window's root view.
///
/// The whole tour lives in one window that changes shape, so this switches
/// between the welcome content and the progress card with a cross-fade while
/// the window itself animates to its new frame. The two must run together: the
/// fade alone would look like a content swap, the frame alone like a resize.
struct OnboardingStageView: View {
    let guide: OnboardingGuide

    var body: some View {
        ZStack {
            if guide.phase == .welcome {
                OnboardingWelcomeView(guide: guide)
                    .transition(.opacity)
            } else {
                OnboardingGuideView(guide: guide)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: guide.phase)
    }
}

// MARK: - Welcome Card

/// First-run welcome: what the app is, what is about to happen, and the two
/// ways out. 「开始引导」 morphs this window into the progress card; the text
/// button opts out of the tour entirely.
struct OnboardingWelcomeView: View {
    let guide: OnboardingGuide

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: .appIconSVG ?? .appIcon)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.popupRowBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)

            VStack(spacing: 6) {
                Text("欢迎使用 CopyAttach")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.popupPrimaryText)
                Text("接下来会带你实际走一遍核心操作，大约 1 分钟。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.popupSecondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(action: { guide.beginTour() }) {
                    Text("开始引导")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button(action: { guide.skip() }) {
                    Text("跳过引导，直接使用")
                        .font(.system(size: 11))
                        .foregroundColor(theme.popupMutedText)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 220)
        }
        .padding(28)
        .frame(
            width: OnboardingGuidePanel.welcomeSize.width,
            height: OnboardingGuidePanel.welcomeSize.height
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.popupBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.popupRowBorder, lineWidth: 1)
        )
    }
}
