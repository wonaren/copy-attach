import SwiftUI

// MARK: - Day Grouping Helpers (non-actor, safe from any thread)

/// Pure functions for day-based grouping and date label formatting.
/// Kept outside any View to avoid `@MainActor` isolation — these are called
/// from background search tasks as well as the main thread.
enum DayGroup {
    /// "7月21日 今天" / "7月20日 昨天" / "7月19日" / "2025年12月23日"
    static func label(for timestamp: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let nowYear = cal.component(.year, from: Date())
        let dateStr: String
        if comps.year == nowYear {
            dateStr = "\(comps.month ?? 0)月\(comps.day ?? 0)日"
        } else {
            dateStr = "\(comps.year ?? 0)年\(comps.month ?? 0)月\(comps.day ?? 0)日"
        }
        if cal.isDateInToday(date) { return "\(dateStr) 今天" }
        if cal.isDateInYesterday(date) { return "\(dateStr) 昨天" }
        return dateStr
    }

    /// True when both Unix-second timestamps fall on the same calendar day
    /// in the user's current time zone.
    static func isSameDay(_ a: UInt64, _ b: UInt64) -> Bool {
        let da = Date(timeIntervalSince1970: TimeInterval(a))
        let db = Date(timeIntervalSince1970: TimeInterval(b))
        return Calendar.current.isDate(da, inSameDayAs: db)
    }
}

// MARK: - Date Section Separator

/// Visual day separator shown between clipboard entries that fall on different
/// calendar days. Purely decorative — it does not participate in selection or
/// keyboard navigation, which index into the underlying item array directly.
struct DateSeparatorView: View {
    let timestamp: UInt64
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(DayGroup.label(for: timestamp))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.popupSecondaryText)
            Rectangle()
                .fill(theme.popupRowBorder)
                .frame(height: 0.5)
        }
        .padding(.horizontal, 2)
    }
}
