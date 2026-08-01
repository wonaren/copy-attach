import AppKit
import SwiftUI

/// Activation celebration that plays *inside* the license gate window (not a
/// full-screen overlay). Two variants, selected by `CelebrationKind`:
///
///  - `.trial` — calm teal "trial started" animation: a clock badge pops in
///    while soft bubbles rise from the bottom with a slow side-to-side sway.
///
///  - `.keyActivation` — the classic confetti-fountain animation: green
///    checkmark badge with particle arcs from the bottom corners.
struct LicenseCelebrationView: View {
    let kind: CelebrationKind
    let message: String
    let subtitle: String

    @State private var dimmed = false

    var body: some View {
        ZStack {
            // Gentle dim over the gate content
            Color.black.opacity(dimmed ? 0.55 : 0)
                .ignoresSafeArea()

            switch kind {
            case .trial:
                TrialCelebrationView(message: message, subtitle: subtitle)
            case .keyActivation:
                KeyActivationCelebrationView(message: message, subtitle: subtitle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { dimmed = true }
        }
    }
}

// MARK: - Trial (免费试用)

/// Calm variant for starting a free trial: teal clock badge with a gentle
/// spring, plus soft bubbles that drift upward with a slow side-to-side sway.
private struct TrialCelebrationView: View {
    let message: String
    let subtitle: String

    @State private var appear = false
    @State private var emit = false
    @State private var launchTime: TimeInterval = 0
    @State private var bubbles: [Bubble] = []

    private let bubbleColors: [Color] = [.teal, .cyan, .mint, .white]

    var body: some View {
        ZStack {
            // Soft bubbles: rise from below the window, sway gently, fade out.
            if emit {
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        let w = size.width
                        let h = size.height
                        let elapsed = now - launchTime
                        for b in bubbles {
                            let local = elapsed - b.delay
                            guard local >= 0, local <= b.duration else { continue }
                            let progress = local / b.duration
                            let y = h * CGFloat(1.06 - 1.12 * progress)
                            let sway = CGFloat(sin(elapsed * b.swaySpeed + b.phase)) * b.swayAmount * w
                            let x = b.centerX * w + sway
                            let diameter = b.size * CGFloat(1 + 0.3 * progress)
                            let opacity = 0.35 * (1 - progress * progress)
                            let r = CGRect(
                                x: x - diameter / 2,
                                y: y - diameter / 2,
                                width: diameter,
                                height: diameter
                            )
                            context.fill(Path(ellipseIn: r), with: .color(b.color.opacity(opacity)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.teal.opacity(0.95), Color.cyan.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 92, height: 92)
                        .shadow(color: Color.teal.opacity(0.5), radius: 20, y: 6)

                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .scaleEffect(appear ? 1 : 0.2)
                        .rotationEffect(.degrees(appear ? 0 : -12))
                }
                .scaleEffect(appear ? 1 : 0.3)
                .animation(.spring(response: 0.75, dampingFraction: 0.6).delay(0.05), value: appear)

                VStack(spacing: 6) {
                    Text(message)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : 10)
                        .animation(.easeOut(duration: 0.45).delay(0.25), value: appear)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .opacity(appear ? 1 : 0)
                        .animation(.easeOut(duration: 0.45).delay(0.38), value: appear)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appear = true
            bubbles = makeBubbles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                launchTime = Date().timeIntervalSinceReferenceDate
                emit = true
            }
        }
    }

    private struct Bubble {
        let color: Color
        let centerX: CGFloat // normalized 0...1
        let size: CGFloat
        let duration: Double
        let delay: Double
        let swayAmount: CGFloat // fraction of width
        let swaySpeed: Double
        let phase: Double
    }

    private func makeBubbles() -> [Bubble] {
        (0..<16).map { index in
            Bubble(
                color: bubbleColors[index % bubbleColors.count],
                centerX: CGFloat.random(in: 0.06...0.94),
                size: CGFloat.random(in: 6...22),
                duration: Double.random(in: 2.6...3.8),
                delay: Double.random(in: 0.0...0.6),
                swayAmount: CGFloat.random(in: 0.03...0.06),
                swaySpeed: Double.random(in: 0.7...1.3),
                phase: Double.random(in: 0...(.pi * 2))
            )
        }
    }
}

// MARK: - Key activation (密钥激活)

/// Classic confetti-fountain variant: green checkmark badge, with particle
/// arcs fountaining from the bottom-left corner toward the upper right and
/// from the bottom-right corner toward the upper left.
private struct KeyActivationCelebrationView: View {
    let message: String
    let subtitle: String

    @State private var appear = false
    @State private var burst = false
    @State private var launchTime: TimeInterval = 0
    @State private var particles: [Particle] = []

    private let particleColors: [Color] = [
        .pink, .orange, .yellow, .green, .mint, .cyan, .blue, .purple, .indigo
    ]

    var body: some View {
        ZStack {
            // Fountain particles driven by a TimelineView + Canvas: each piece
            // travels a quadratic-bezier arc from a bottom corner to an upper
            // target (left corner -> upper right, right corner -> upper left).
            if burst {
                TimelineView(.animation) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        let w = size.width
                        let h = size.height
                        let elapsed = now - launchTime
                        for p in particles {
                            let local = elapsed - p.delay
                            guard local >= 0, local <= p.duration else { continue }
                            let progress = easeOut(min(local / p.duration, 1))
                            // Normalized control point -> scaled coordinates
                            let origin = CGPoint(x: p.originX * w, y: p.originY * h)
                            let target = CGPoint(x: p.targetX * w, y: p.targetY * h)
                            let control = CGPoint(
                                x: (origin.x + target.x) / 2,
                                y: min(origin.y, target.y) - p.arcHeight * h
                            )
                            let pos = quadPoint(p0: origin, p1: control, p2: target, t: CGFloat(progress))
                            let rotation = p.rotation * progress * Double.pi / 180
                            let transform = CGAffineTransform(translationX: pos.x, y: pos.y)
                                .rotated(by: CGFloat(rotation))
                                .translatedBy(x: -p.size.width / 2, y: -p.size.height / 2)
                            let rect = CGRect(origin: .zero, size: p.size)
                            let path = Path(rect).applying(transform)
                            let fade = 1 - progress * progress
                            context.fill(path, with: .color(p.color.opacity(fade)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }

            // Badge + headline, centered
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.95), Color.mint.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 92, height: 92)
                        .shadow(color: Color.green.opacity(0.55), radius: 22, y: 7)

                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .scaleEffect(appear ? 1 : 0.2)
                        .rotationEffect(.degrees(appear ? 0 : -24))
                }
                .scaleEffect(appear ? 1 : 0.3)
                .animation(.spring(response: 0.55, dampingFraction: 0.55).delay(0.05), value: appear)

                VStack(spacing: 6) {
                    Text(message)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(appear ? 1 : 0)
                        .offset(y: appear ? 0 : 10)
                        .animation(.easeOut(duration: 0.45).delay(0.25), value: appear)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .opacity(appear ? 1 : 0)
                        .animation(.easeOut(duration: 0.45).delay(0.38), value: appear)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appear = true
            particles = makeParticles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                launchTime = Date().timeIntervalSinceReferenceDate
                burst = true
            }
        }
    }

    // MARK: - Particle math

    private struct Particle {
        let color: Color
        let originX: CGFloat  // normalized 0...1
        let originY: CGFloat  // normalized 0...1
        let targetX: CGFloat  // normalized 0...1
        let targetY: CGFloat  // normalized 0...1
        let arcHeight: CGFloat // fraction of height
        let rotation: Double
        let delay: Double
        let duration: Double
        let size: CGSize
    }

    private func makeParticles() -> [Particle] {
        (0..<26).map { index in
            let fromLeft = index % 2 == 0
            // Launch from bottom corner, arc to upper center-ish
            let targetX = CGFloat.random(in: 0.38...0.62) + (fromLeft ? 1 : -1) * CGFloat.random(in: 0.04...0.12)
            return Particle(
                color: particleColors[index % particleColors.count],
                originX: fromLeft ? 0.02 : 0.98,
                originY: 0.98,
                targetX: min(max(targetX, 0.12), 0.88),
                targetY: CGFloat.random(in: 0.16...0.34),
                arcHeight: CGFloat.random(in: 0.14...0.24),
                rotation: Double.random(in: 300...780) * (Bool.random() ? 1 : -1),
                delay: Double.random(in: 0.05...0.20),
                duration: Double.random(in: 0.9...1.3),
                size: CGSize(width: CGFloat.random(in: 6...10), height: CGFloat.random(in: 8...14))
            )
        }
    }

    private func quadPoint(p0: CGPoint, p1: CGPoint, p2: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
        )
    }

    private func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }
}
