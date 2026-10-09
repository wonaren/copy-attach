import AppKit
import SwiftUI

// MARK: - Apple Motion Design System
//
// Encapsulates Apple-standard physics-based springs, linear sweep animations
// (shimmer for stealing perceived latency), and tactile button styles.
// Designed specifically to maintain 60/120fps ProMotion fluidity while adding
// rich, tactile motion and perceived responsiveness with ZERO visual dizziness or blur fatigue.

enum AppleMotion {
    /// Snappy physical spring for micro-interactions: tab pills, button presses,
    /// icon bounces. Settle time ~200ms with zero visible overshoot.
    static var snappy: Animation {
        .spring(response: 0.22, dampingFraction: 0.78, blendDuration: 0)
    }

    /// Smooth spring for layout/frame morphing and window-level transitions.
    static var smooth: Animation {
        .spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0)
    }

    /// Tactile spring for active press feedback on interactive elements.
    static var tactilePress: Animation {
        .spring(response: 0.16, dampingFraction: 0.70, blendDuration: 0)
    }
}

// MARK: - Crisp Micro-Scale & Fade Transition (纯净微缩放淡入淡出转场 - 清晰不晃眼)

/// Apple-grade crisp cross-dissolve with subtle micro-scale (0.992).
/// Completely eliminates Gaussian blur to protect readability and prevent eye fatigue.
/// Used for settings tabs, modal states, and transient HUDs.
extension AnyTransition {
    static var appleScaleFade: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.992).combined(with: .opacity),
            removal: .scale(scale: 0.992).combined(with: .opacity)
        )
    }
}

// MARK: - Apple Tactile Button Style (即时按压触觉反馈 - 0ms 响应)

/// Emil Kowalski rule: "Buttons must feel responsive: Add transform: scale(0.97)
/// on active press. This gives instant feedback, confirming the interface heard the user."
struct AppleTactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(AppleMotion.tactilePress, value: configuration.isPressed)
    }
}

// MARK: - Linear Shimmer Sweep Modifier (线性扫光动效 - 偷时间/感知流畅度)

/// Hardware-accelerated linear gradient sweep that runs continuously while
/// background operations (decoding thumbnails, encoding PNGs, loading previews)
/// are in progress. Steals perceived latency by assuring the user that the system
/// is actively working for them, with crisp geometric borders and zero blur.
struct LinearShimmerModifier: ViewModifier {
    @State private var isAnimating = false
    var isActive: Bool = true
    var duration: Double = 1.35

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.0), location: 0.0),
                                .init(color: Color.white.opacity(0.20), location: 0.5),
                                .init(color: Color.white.opacity(0.0), location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(width * 0.75, 50))
                        .offset(x: isAnimating ? width + 60 : -width * 0.75 - 60)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                            isAnimating = true
                        }
                    }
                }
            }
    }
}

extension View {
    /// Applies an Apple-grade linear shimmer sweep over this view.
    /// Completely inactive when `isActive` is false to avoid GPU overhead.
    func linearShimmer(isActive: Bool = true, duration: Double = 1.35) -> some View {
        modifier(LinearShimmerModifier(isActive: isActive, duration: duration))
    }
}

// MARK: - Shimmer Placeholder Card (图片加载与编码的骨架微光卡片)

/// A sleek, translucent placeholder card with a linear shimmer sweep and pulsing icon.
/// Used in ItemRowView while thumbnails decode or images undergo Phase 2 encoding.
/// Completely sharp and crisp with zero Gaussian blur.
struct ShimmerPlaceholderCard: View {
    let title: String
    let iconName: String
    var maxHeight: CGFloat = 100

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.popupRowHover.opacity(colorScheme == .dark ? 0.35 : 0.60))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.popupRowBorder, lineWidth: 0.8)
                )

            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 15))
                    .foregroundColor(theme.popupSecondaryText)
                    .symbolEffect(.pulse)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.popupSecondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: maxHeight)
        .frame(maxWidth: .infinity)
        .linearShimmer(isActive: true, duration: 1.35)
    }
}

// MARK: - Apple Toast HUD (轻量毛玻璃浮动反馈卡片)

/// Floating capsule HUD with ultra-thin material and subtle drop shadow.
/// Confirms user clipboard and favorite mutations instantly with crisp, legible typography.
struct AppleToastCard: View {
    let message: String
    let iconName: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: .systemGreen))
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(colorScheme == .dark ? .white : Color(white: 0.1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.40), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
    }
}
