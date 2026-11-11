import Foundation

enum UpdateChecker {
    struct Release: Equatable, Sendable {
        let version: String
        let releaseURL: URL
        let source: String
        let age: TimeInterval

        var isStale: Bool { age > UpdateChecker.staleAnswerLimit }
    }

    enum CheckError: LocalizedError, Equatable, Sendable {
        case unavailable
        case noRelease
        case throttled
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "无法连接到更新服务器，请检查网络后重试。"
            case .noRelease:
                return "未找到版本信息（仓库中尚无正式 Release）。"
            case .throttled:
                return "请求过于频繁，请稍后再试。"
            case .invalidResponse:
                return "无法解析更新信息。"
            }
        }
    }

    private static let staleAnswerLimit: TimeInterval = 2 * 60
    private static let unknownAnswerAge: TimeInterval = 60 * 60

    private static let cacheKey = "LastUpdateCheck"
    private static let githubLatestReleaseURL = URL(string: "https://github.com/wonaren/copy-attach/releases/latest")!
    private static let healthzURL = URL(string: "https://dl.abovepast.shop/healthz")!
    private static let releaseTagBase = "https://github.com/wonaren/copy-attach/releases/tag/v"

    private static let githubTimeout: TimeInterval = 4
    private static let healthzTimeout: TimeInterval = 12

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = healthzTimeout
        config.timeoutIntervalForResource = healthzTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "CopyAttach/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")",
        ]
        return URLSession(configuration: config)
    }()

    private struct HealthzPayload: Decodable {
        let version: String?
        let versionCheckedAt: Double?

        enum CodingKeys: String, CodingKey {
            case version
            case versionCheckedAt = "version_checked_at"
        }
    }

    static func latestRelease() async throws -> Release {
        let release = try await withThrowingTaskGroup(of: Release.self) { group in
            group.addTask { try await fetchGitHub() }
            group.addTask { try await fetchHealthz() }

            var lastError: Error = CheckError.unavailable
            var staleAnswer: Release?
            while true {
                do {
                    guard let release = try await group.next() else { break }
                    if release.isStale && staleAnswer == nil {
                        debugLog("[update] \(release.source) answered v\(release.version) but the data is \(Int(release.age))s old; waiting for a live source")
                        staleAnswer = release
                        continue
                    }
                    group.cancelAll()
                    return release
                } catch {
                    lastError = error
                    if case CheckError.noRelease = error {
                        group.cancelAll()
                        throw error
                    }
                }
            }
            if let staleAnswer {
                debugLog("[update] every live source failed; falling back to \(staleAnswer.source) v\(staleAnswer.version) (\(Int(staleAnswer.age))s old)")
                return staleAnswer
            }
            throw lastError
        }
        remember(release)
        return release
    }

    private static func fetchGitHub() async throws -> Release {
        let started = Date()
        var request = URLRequest(url: githubLatestReleaseURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: githubTimeout)
        request.httpMethod = "HEAD"

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CheckError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 404:
            throw CheckError.noRelease
        case 403, 429:
            throw CheckError.throttled
        default:
            throw CheckError.invalidResponse
        }

        guard let finalURL = http.url, let version = releaseTag(from: finalURL) else {
            throw CheckError.invalidResponse
        }
        debugLog("[update] GitHub answered v\(version) in \(milliseconds(since: started)) ms")
        return Release(version: version, releaseURL: finalURL, source: "github", age: 0)
    }

    private static func fetchHealthz() async throws -> Release {
        let started = Date()
        var request = URLRequest(url: healthzURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: healthzTimeout)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CheckError.invalidResponse
        }
        guard let payload = try? JSONDecoder().decode(HealthzPayload.self, from: data),
              let rawVersion = payload.version, !rawVersion.isEmpty else {
            throw CheckError.invalidResponse
        }
        let version = cleanVersionTag(rawVersion)
        guard isValidVersion(version) else {
            throw CheckError.invalidResponse
        }
        guard let releaseURL = URL(string: releaseTagBase + version) else {
            throw CheckError.invalidResponse
        }
        let age: TimeInterval
        if let checkedAt = payload.versionCheckedAt, checkedAt > 0 {
            age = max(0, Date().timeIntervalSince1970 - checkedAt / 1000)
        } else {
            age = unknownAnswerAge
        }
        debugLog("[update] healthz answered v\(version) (data \(Int(age))s old) in \(milliseconds(since: started)) ms")
        return Release(version: version, releaseURL: releaseURL, source: "healthz", age: age)
    }

    static func cachedRelease() -> Release? {
        guard let dict = UserDefaults.standard.dictionary(forKey: cacheKey),
              let version = dict["version"] as? String,
              let urlString = dict["url"] as? String,
              let releaseURL = URL(string: urlString) else {
            return nil
        }
        let checkedAt = dict["checkedAt"] as? Double ?? 0
        return Release(version: version, releaseURL: releaseURL, source: "cache",
                       age: max(0, Date().timeIntervalSince1970 - checkedAt))
    }

    private static func remember(_ release: Release) {
        UserDefaults.standard.set([
            "version": release.version,
            "url": release.releaseURL.absoluteString,
            "checkedAt": Date().timeIntervalSince1970 - release.age,
        ], forKey: cacheKey)
    }

    static func cleanVersionTag(_ raw: String) -> String {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return version
    }

    static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count else {
            return nil
        }
        let tag = parts[(index + 1)...].joined(separator: "/")
        let version = cleanVersionTag(tag)
        return isValidVersion(version) ? version : nil
    }

    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    static func isUpgrade(latest: String, current: String) -> Bool {
        let currentBase = current.components(separatedBy: "-").first ?? current
        if current != currentBase { return true }
        return latest.compare(currentBase, options: .numeric) == .orderedDescending
    }

    private static let notesSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    private struct ReleasePayload: Decodable {
        let body: String?
    }

    static func releaseNotes(version: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/wonaren/copy-attach/releases/tags/v\(version)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await notesSession.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
              let body = payload.body, !body.isEmpty else {
            debugLog("[update] release notes for v\(version) unavailable")
            return nil
        }
        return body
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
