import AppKit
import SwiftUI

// MARK: - Onboarding Guide View

/// The floating tour card: overall progress, the action to perform right now,
/// and sub-progress for the combined delete/undo step. It observes
/// `OnboardingGuide` directly — every `record(_:)` re-renders the card.
struct OnboardingGuideView: View {
    let guide: OnboardingGuide

    @Environment(\.appTheme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            progressBar
            if let step = guide.currentStep {
                stepCard(step)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(
            width: OnboardingGuidePanel.cardSize.width,
            height: OnboardingGuidePanel.cardSize.height,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.popupBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.popupRowBorder, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("快速上手")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.popupPrimaryText)
            Spacer()
            Text("\(guide.completedSteps.count)/\(guide.totalStepCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.popupMutedText)
            Button(action: { guide.skip() }) {
                Text("跳过")
                    .font(.system(size: 11))
                    .foregroundColor(theme.popupMutedText)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(guide.completedSteps.contains(step) ? Color.accentColor : theme.popupRowBorder)
                    .frame(height: 4)
                    .animation(AppleMotion.snappy, value: guide.completedSteps.contains(step))
            }
        }
    }

    // MARK: - Current Step

    private func stepCard(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: step.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                Text(step.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.popupPrimaryText)
                Spacer()
                if let hint = keyHint(for: step) {
                    keyBadge(hint)
                }
            }

            Text(step.instruction)
                .font(.system(size: 11.5))
                .foregroundColor(theme.popupSecondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if step == .deleteAndUndo {
                subActionRow
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.popupSearchBackground)
        )
    }

    /// Delete/undo is one step made of two actions; show which half landed.
    private var subActionRow: some View {
        HStack(spacing: 14) {
            subActionFlag(icon: "trash", label: "已删除", done: guide.deleteActionDone)
            subActionFlag(icon: "arrow.uturn.backward", label: "已撤销", done: guide.undoActionDone)
            Spacer()
        }
    }

    private func subActionFlag(icon: String, label: String, done: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(done ? Color(nsColor: .systemGreen) : theme.popupMutedText)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(done ? theme.popupPrimaryText : theme.popupMutedText)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text("按顺序完成以上操作，即可掌握全部核心功能。")
            .font(.system(size: 10.5))
            .foregroundColor(theme.popupMutedText)
    }

    // MARK: - Helpers

    /// The hotkey hint tracks the user's recorded shortcut rather than a
    /// hard-coded default.
    private func keyHint(for step: OnboardingStep) -> String? {
        if step == .openPopup { return HotkeyManager.shared.config.displayString }
        return step.keyHint
    }

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.popupPrimaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.popupTagBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(theme.popupRowBorder, lineWidth: 1)
            )
    }
}
