import SwiftUI

struct DateSeparatorView: View {
    let timestamp: UInt64
    @Environment(\.appTheme) private var theme

    var body: some View {
        let parts = DayGroup.labelParts(for: timestamp)
        HStack(spacing: 6) {
            Text(parts.date)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.popupSecondaryText)
                .contentTransition(.numericText())
            if let relative = parts.relative {
                Text(relative)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.popupSecondaryText)
                    .transition(.opacity)
            }
            Rectangle()
                .fill(theme.popupRowBorder)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 2)
    }
}
