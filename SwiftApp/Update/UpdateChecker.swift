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
///   endpoint. It exists because GitHub's DNS is unreliable on some networks
///   (measured: 1 in 3 HEAD requests to github.com timed out at 6 s). It is a
///   **cache**, not a live lookup: the worker re-verifies upstream at most once
///   per refresh interval and reports how old its answer is, so an answer older
///   than [`staleAnswerLimit`] is held back rather than accepted.
///
/// The durable result is cached, so re-opening About shows the last answer
/// immediately; a check still runs on every visit (the painted answer never
/// suppresses it) so a fresh release surfaces as soon as a source knows it.
enum UpdateChecker {
    struct Release: Equatable, Sendable {
        /// Pure numeric version, e.g. "0.108.6".
        let version: String
        let releaseURL: URL
        /// Diagnostic only ("github" / "healthz"). Never shown to the user.
        let source: String
        /// How old the version data was when it arrived. GitHub resolves the
        /// current release on every request, so it is 0; `/healthz` reports
        /// when it last verified upstream, which can be a full refresh interval
        /// behind. A release published inside that window is invisible to it.
        let age: TimeInterval

        /// An answer this old cannot be treated as final: the authoritative
        /// source may still be about to answer with a newer release. Measured
        /// 2026-10-20 — v0.109.0 was published at 15:01:55, `/healthz` kept
        /// serving v0.108.6 until 15:06:44, and the app offered the old version.
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

    /// Version data older than this cannot end the race (see `Release.isStale`).
    private static let staleAnswerLimit: TimeInterval = 2 * 60
    /// Age assumed when a source reports no timestamp at all. The worker refuses
    /// to report anything older than an hour, so that is the worst case.
    private static let unknownAnswerAge: TimeInterval = 60 * 60

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
        /// Milliseconds since 1970 when the worker last *verified* the version
        /// against GitHub. Absent in worker builds that predate the field, and 0
        /// when the worker has never verified one — both are treated as the
        /// worst case rather than as "live".
        let versionCheckedAt: Double?

        enum CodingKeys: String, CodingKey {
            case version
            case versionCheckedAt = "version_checked_at"
        }
    }

    // MARK: - Network

    /// Race every source and return the first valid answer. A definitive "no
    /// release" fails fast; transient failures wait for the other source.
    static func latestRelease() async throws -> Release {
        let release = try await withThrowingTaskGroup(of: Release.self) { group in
            group.addTask { try await fetchGitHub() }
            group.addTask { try await fetchHealthz() }

            var lastError: Error = CheckError.unavailable
            /// A stale answer is held back, not thrown away: it is the correct
            /// result only once every authoritative source has failed.
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
                        // No release exists; the other source cannot invent one.
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

        // URLSession follows the redirect: the final URL is
        // …/releases/tag/v0.108.6.
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

    // MARK: - Cache

    /// Last successful answer, or nil when nothing has been cached. Used to
    /// paint the About tab instantly; the check itself never consults it.
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
        // `checkedAt` records when the *data* was produced, not when we fetched
        // it: a /healthz answer that was already minutes old must not be granted
        // a fresh cache lifetime on top of its own staleness.
        UserDefaults.standard.set([
            "version": release.version,
            "url": release.releaseURL.absoluteString,
            "checkedAt": Date().timeIntervalSince1970 - release.age,
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
