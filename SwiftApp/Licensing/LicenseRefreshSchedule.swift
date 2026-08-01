import Foundation

/// Schedules renewal at 50% of the signed Lease lifetime, bounded away from
/// both issuance and expiry. For a 120-second development Lease this refreshes
/// after 60 seconds; for a 24-hour production Lease it refreshes after 12 hours.
enum LicenseRefreshSchedule {
    static func refreshDate(for payload: LeasePayload) -> Date {
        let lifetime = max(payload.expiresAt - payload.issuedAt, 1)
        let lead = min(max(lifetime / 2, 5), 43_200)
        return Date(timeIntervalSince1970: TimeInterval(payload.expiresAt - lead))
    }
}
