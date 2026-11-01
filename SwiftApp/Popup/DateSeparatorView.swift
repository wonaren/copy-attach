import SwiftUI

enum DayGroup {
    private static func dayComponents(for date: Date, calendar: Calendar) -> (era: Int, year: Int, month: Int, day: Int)? {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let era = components.era,
              let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return (era, year, month, day)
    }

    static func label(for timestamp: UInt64) -> String {
        let parts = labelParts(for: timestamp)
        return parts.relative.map { "\(parts.date) \($0)" } ?? parts.date
    }

    static func separatorID(for timestamp: UInt64) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        guard let components = dayComponents(for: date, calendar: Calendar.current) else {
            return Int.min
        }
        let key = Int64(components.era) * 1_000_000_000
            + Int64(components.year) * 10_000
            + Int64(components.month) * 100
            + Int64(components.day)
        guard key > 0, key <= Int64(Int.max) else { return Int.min }
        return Int(Int64.min + key)
    }

    static func labelParts(for timestamp: UInt64) -> (date: String, relative: String?) {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let cal = Calendar.current
        guard let comps = dayComponents(for: date, calendar: cal) else {
            return ("", nil)
        }
        let nowYear = cal.component(.year, from: Date())
        let dateText: String
        if comps.year == nowYear {
            dateText = "\(comps.month)月\(comps.day)日"
        } else {
            dateText = "\(comps.year)年\(comps.month)月\(comps.day)日"
        }
        if cal.isDateInToday(date) { return (dateText, "今天") }
        if cal.isDateInYesterday(date) { return (dateText, "昨天") }
        return (dateText, nil)
    }

    static func isSameDay(_ a: UInt64, _ b: UInt64) -> Bool {
        let da = Date(timeIntervalSince1970: TimeInterval(a))
        let db = Date(timeIntervalSince1970: TimeInterval(b))
        return Calendar.current.isDate(da, inSameDayAs: db)
    }
}

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
