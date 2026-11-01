import AppKit
import SwiftUI

enum AppleMotion {
    static var snappy: Animation {
        .spring(response: 0.22, dampingFraction: 0.78, blendDuration: 0)
    }

    static var smooth: Animation {
        .spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0)
    }

    static var tactilePress: Animation {
        .spring(response: 0.16, dampingFraction: 0.70, blendDuration: 0)
    }
}

extension AnyTransition {
    static var appleScaleFade: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.992).combined(with: .opacity),
            removal: .scale(scale: 0.992).combined(with: .opacity)
        )
    }
}

struct AppleTactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(AppleMotion.tactilePress, value: configuration.isPressed)
    }
}

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
    func linearShimmer(isActive: Bool = true, duration: Double = 1.35) -> some View {
        modifier(LinearShimmerModifier(isActive: isActive, duration: duration))
    }
}

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
