import AppKit
import SwiftUI

// MARK: - Apple Motion Design System
//
// Encapsulates Apple-standard physics-based springs, linear sweep animations
// (shimmer for stealing perceived latency), and Gaussian blur transition curves.
// Designed specifically to maintain 60/120fps ProMotion fluidity while adding
// rich, tactile motion and optical depth.

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

    /// Crisp ease-out for blur-to-focus reveals (e.g. decoded image arriving).
    /// Emil Kowalski rule: ease-out starts immediately, giving instant feedback.
    static var blurReveal: Animation {
        .easeOut(duration: 0.22)
    }

    /// Transient container-level Gaussian blur transition for tab switches.
    /// 140ms duration bridges the visual gap between lists without per-row graphs.
    static var tabBlurTransition: Animation {
        .easeOut(duration: 0.14)
    }
}

// MARK: - Linear Shimmer Sweep Modifier (线性扫光动效 - 偷时间/感知流畅度)

/// Hardware-accelerated linear gradient sweep that runs continuously while
/// background operations (decoding thumbnails, encoding PNGs, loading previews)
/// are in progress. Steals perceived latency by assuring the user that the system
/// is actively working for them.
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
struct ShimmerPlaceholderCard: View {
    let title: String
    let iconName: String
    var maxHeight: CGFloat = 100

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.popupRowHover.opacity(colorScheme == .dark ? 0.45 : 0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.popupRowBorder, lineWidth: 0.8)
                )

            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 20))
                    .foregroundColor(theme.popupSecondaryText)
                    .symbolEffect(.pulse)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.popupSecondaryText)
            }
            .padding(.vertical, 12)
        }
        .frame(maxHeight: maxHeight)
        .frame(maxWidth: .infinity)
        .linearShimmer(isActive: true, duration: 1.3)
    }
}
