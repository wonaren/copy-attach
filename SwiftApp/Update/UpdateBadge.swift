import Foundation
import Observation

@Observable
@MainActor
final class UpdateBadge {
    static let shared = UpdateBadge()

    static let pendingVersionKey = "PendingUpdateVersion"
    static let pendingNotesKey = "PendingUpdateNotes"
    private static let seenVersionKey = "SeenUpdateVersion"

    private(set) var latestVersion: String?
    private(set) var isChecking = false
    private(set) var hasUnseenUpdate = false

    private var lastAttempt: Date?

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    func loadCache() {
        guard let cached = UpdateChecker.cachedRelease() else { return }
        apply(cached.version)
    }

    func refreshIfStale() {
        if let cached = UpdateChecker.cachedRelease() {
            apply(cached.version)
            if cached.age < UpdateChecker.cacheTTL { return }
        }
        refresh()
    }

    func refresh() {
        guard !isChecking else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < UpdateChecker.cacheTTL { return }
        lastAttempt = Date()
        isChecking = true
        Task { @MainActor in
            defer { isChecking = false }
            guard let release = try? await UpdateChecker.latestRelease() else { return }
            apply(release.version)
        }
    }

    private func apply(_ latest: String) {
        latestVersion = UpdateChecker.isUpgrade(latest: latest, current: Self.currentVersion) ? latest : nil
        hasUnseenUpdate = latestVersion != nil
            && UserDefaults.standard.string(forKey: Self.seenVersionKey) != latest
    }

    func markSeen() {
        guard let latestVersion else { return }
        UserDefaults.standard.set(latestVersion, forKey: Self.seenVersionKey)
        hasUnseenUpdate = false
    }
}
