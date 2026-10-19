import Foundation

/// Fetches the latest released version of CopyAttach.
///
/// Latency contract: a check costs as much as the **fastest healthy source**,
/// never the sum of a primary plus a fallback. The sources are raced in
/// parallel:
///
/// - GitHub `releases/latest` — HEAD request, zero bytes, 302 to the tag page.
///   Measured 0.2–0.5 s; authoritative because the redirect target *is* the
///   release.
/// - `dl.abovepast.shop/healthz` — JSON version from the Cloudflare-accelerated
///   endpoint. It exists because GitHub's DNS is unreliable on some networks,
///   but it performs an upstream check per request (measured 3.9–10 s), so it
///   must never gate the fast answer.
///
/// The durable result is cached, so re-opening About shows the last answer
/// immediately and only revalidates once [`cacheLifetime`] has elapsed.
enum UpdateChecker {
    struct Release: Equatable, Sendable {
        /// Pure numeric version, e.g. "0.108.6".
        let version: String
        let releaseURL: URL
        /// Diagnostic only ("github" / "healthz"). Never shown to the user.
        let source: String
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

    /// How long a cached answer is trusted without a network revalidation. A
    /// new release still surfaces within this window on the next About visit;
    /// the manual button always checks fresh.
    static let cacheLifetime: TimeInterval = 15 * 60

    private static let cacheKey = "LastUpdateCheck"
    private static let githubLatestReleaseURL = URL(string: "https://github.com/wonaren/copy-attach/releases/latest")!
    private static let healthzURL = URL(string: "https://dl.abovepast.shop/healthz")!
    private static let releaseTagBase = "https://github.com/wonaren/copy-attach/releases/tag/v"

    /// GitHub is the fast path, so its timeout is the user-visible latency
    /// ceiling. The healthz timeout is generous on purpose: it only matters
    /// when GitHub is unreachable, and its own response time is seconds.
    private static let githubTimeout: TimeInterval = 4
    private static let healthzTimeout: TimeInterval = 12

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = healthzTimeout
        config.timeoutIntervalForResource = healthzTimeout
        // Without this, an offline Mac makes the request *wait for connectivity*
        // instead of failing, leaving the About tab spinning indefinitely.
        config.waitsForConnectivity = false
        // The answer is "what is the latest release right now"; a cached 302 or
        // healthz payload would make the check lie about its freshness.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "CopyAttach/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")",
        ]
        return URLSession(configuration: config)
    }()

    private struct HealthzPayload: Decodable {
        let version: String?
    }

    // MARK: - Network

    /// Race every source and return the first valid answer. A definitive "no
    /// release" fails fast; transient failures wait for the other source.
    static func latestRelease() async throws -> Release {
        let release = try await withThrowingTaskGroup(of: Release.self) { group in
            group.addTask { try await fetchGitHub() }
            group.addTask { try await fetchHealthz() }

            var lastError: Error = CheckError.unavailable
            while true {
                do {
                    guard let release = try await group.next() else { break }
                    group.cancelAll()
                    return release
                } catch {
                    lastError = error
                    if case CheckError.noRelease = error {
                        // No release exists; the other source cannot invent one.
                        group.cancelAll()
                        throw error
                    }
                }
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

        // URLSession follows the redirect: the final URL is
        // …/releases/tag/v0.108.6.
        guard let finalURL = http.url, let version = releaseTag(from: finalURL) else {
            throw CheckError.invalidResponse
        }
        debugLog("[update] GitHub answered v\(version) in \(milliseconds(since: started)) ms")
        return Release(version: version, releaseURL: finalURL, source: "github")
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
        debugLog("[update] healthz answered v\(version) in \(milliseconds(since: started)) ms")
        return Release(version: version, releaseURL: releaseURL, source: "healthz")
    }

    // MARK: - Cache

    /// Last successful answer, or nil when nothing has been cached. Pass
    /// `maxAge` to require freshness (the auto-check path); omit it to get the
    /// last known answer immediately (the About tab's first paint).
    static func cachedRelease(maxAge: TimeInterval? = nil) -> Release? {
        guard let dict = UserDefaults.standard.dictionary(forKey: cacheKey),
              let version = dict["version"] as? String,
              let urlString = dict["url"] as? String,
              let releaseURL = URL(string: urlString) else {
            return nil
        }
        if let maxAge {
            let checkedAt = dict["checkedAt"] as? Double ?? 0
            guard Date().timeIntervalSince1970 - checkedAt <= maxAge else { return nil }
        }
        return Release(version: version, releaseURL: releaseURL, source: "cache")
    }

    private static func remember(_ release: Release) {
        UserDefaults.standard.set([
            "version": release.version,
            "url": release.releaseURL.absoluteString,
            "checkedAt": Date().timeIntervalSince1970,
        ], forKey: cacheKey)
    }

    // MARK: - Version parsing

    /// Strip a leading "v"/"V" so the version string is purely numeric.
    static func cleanVersionTag(_ raw: String) -> String {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return version
    }

    /// Pull the tag out of a `…/releases/tag/<tag>` URL.
    static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "tag"), index + 1 < parts.count else {
            return nil
        }
        let tag = parts[(index + 1)...].joined(separator: "/")
        let version = cleanVersionTag(tag)
        return isValidVersion(version) ? version : nil
    }

    /// A version must be dot-separated non-empty numeric components. This is
    /// what keeps a captive-portal or garbage payload from being accepted and
    /// turned into a download URL.
    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
