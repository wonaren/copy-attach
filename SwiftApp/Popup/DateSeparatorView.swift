import SwiftUI

// MARK: - Day Grouping Helpers (non-actor, safe from any thread)

/// Pure functions for day-based grouping and date label formatting.
/// Kept outside any View to avoid `@MainActor` isolation — these are called
/// from background search tasks as well as the main thread.
enum DayGroup {
    private static func dayComponents(for date: Date, calendar: Calendar) -> DateComponents {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era != nil,
              components.year != nil,
              components.month != nil,
              components.day != nil else {
            preconditionFailure("Unable to derive calendar day for date \(date)")
        }
        return components
    }

    /// "7月21日 今天" / "7月20日 昨天" / "7月19日" / "2025年12月23日"
    static func label(for timestamp: UInt64) -> String {
        let parts = labelParts(for: timestamp)
        return parts.relative.map { "\(parts.date) \($0)" } ?? parts.date
    }

    /// Stable identity for a calendar day, independent of its first entry.
    /// The Int.min namespace is reserved for separators, while entry IDs are
    /// positive. Encoding calendar components avoids timestamp truncation.
    static func separatorID(for timestamp: UInt64) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let components = dayComponents(for: date, calendar: Calendar.current)
        let era = Int64(components.era!)
        let year = Int64(components.year!)
        let month = Int64(components.month!)
        let day = Int64(components.day!)
        let key = era * 1_000_000_000 + year * 10_000 + month * 100 + day
        precondition(key > 0 && key <= Int64(Int.max), "Calendar day ID overflow")
        return Int(Int64.min + key)
    }

    /// Split the date and relative-day label so the separator can preserve its
    /// identity while updating only the text that actually changed.
    static func labelParts(for timestamp: UInt64) -> (date: String, relative: String?) {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let cal = Calendar.current
        let comps = dayComponents(for: date, calendar: cal)
        let nowYear = cal.component(.year, from: Date())
        let dateText: String
        if comps.year == nowYear {
            dateText = "\(comps.month!)月\(comps.day!)日"
        } else {
            dateText = "\(comps.year!)年\(comps.month!)月\(comps.day!)日"
        }
        if cal.isDateInToday(date) { return (dateText, "今天") }
        if cal.isDateInYesterday(date) { return (dateText, "昨天") }
        return (dateText, nil)
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
