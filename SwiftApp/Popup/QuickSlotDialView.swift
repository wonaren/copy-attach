import AppKit
import SwiftUI

struct QuickSlotDialView: View {
    let boundSlots: Set<Int>
    @Environment(\.appTheme) private var theme

    private static let segmentCount = 9
    private static let gapDegrees: Double = 7
    private static let outerRadiusRatio: CGFloat = 0.47
    private static let innerRadiusRatio: CGFloat = 0.31

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let size = min(geo.size.width, geo.size.height)
            let outer = size * Self.outerRadiusRatio
            let inner = size * Self.innerRadiusRatio
            let step = 360.0 / Double(Self.segmentCount)

            ZStack {
                ForEach(1...Self.segmentCount, id: \.self) { slot in
                    let start = -90 + Double(slot - 1) * step + Self.gapDegrees / 2
                    let end = -90 + Double(slot) * step - Self.gapDegrees / 2
                    let isBound = boundSlots.contains(slot)
                    donutSector(center: center, inner: inner, outer: outer,
                                startDegrees: start, endDegrees: end)
                        .fill(isBound
                              ? Color(nsColor: .controlAccentColor)
                              : theme.popupPrimaryText.opacity(0.10))

                    let mid = (start + end) / 2 * .pi / 180
                    let labelRadius = (inner + outer) / 2
                    Text("\(slot)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(isBound ? .white : theme.popupSecondaryText)
                        .position(x: center.x + cos(mid) * labelRadius,
                                  y: center.y + sin(mid) * labelRadius)
                }

                Text("右⌘")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.popupSecondaryText)
            }
        }
        .frame(width: 100, height: 100)
        .background(
            Circle()
                .fill(theme.popupBackground.opacity(0.94))
                .overlay(Circle().strokeBorder(theme.popupRowBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .allowsHitTesting(false)
    }

    private func donutSector(center: CGPoint,
                             inner: CGFloat,
                             outer: CGFloat,
                             startDegrees: Double,
                             endDegrees: Double) -> Path {
        let endRad = endDegrees * .pi / 180
        return Path { path in
            path.addArc(center: center,
                        radius: outer,
                        startAngle: .degrees(startDegrees),
                        endAngle: .degrees(endDegrees),
                        clockwise: false)
            path.addLine(to: CGPoint(x: center.x + cos(endRad) * inner,
                                     y: center.y + sin(endRad) * inner))
            path.addArc(center: center,
                        radius: inner,
                        startAngle: .degrees(endDegrees),
                        endAngle: .degrees(startDegrees),
                        clockwise: true)
            path.closeSubpath()
        }
    }
}
