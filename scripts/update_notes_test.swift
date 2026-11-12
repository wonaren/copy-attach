import AppKit
import ObjectiveC

func debugLog(_ message: String) {}

private final class UpdateResponses: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []

    static var paths: [String] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.requests.append(url.path) }
        guard url.host == "api.github.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: String
        let status: Int
        switch url.lastPathComponent {
        case "v0.111.1": (status, body) = (200, #"{"body":"Notes A"}"#)
        case "v0.111.2": (status, body) = (503, "")
        case "v0.111.3": (status, body) = (200, #"{"body":""}"#)
        case "v0.111.4": (status, body) = (200, "invalid JSON")
        case "v0.111.5":
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        default:
            preconditionFailure("Unexpected notes request: \(url)")
        }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLSessionConfiguration {
    @objc class func testDefault() -> URLSessionConfiguration {
        let config = testDefault()
        config.protocolClasses = [UpdateResponses.self]
        config.urlCache = nil
        return config
    }

    @objc class func testEphemeral() -> URLSessionConfiguration {
        let config = testEphemeral()
        config.protocolClasses = [UpdateResponses.self]
        return config
    }
}

@main
struct UpdateNotesTest {
    @MainActor
    static func main() async throws {
        let status = try await run()
        exit(status)
    }

    @MainActor
    static func run() async throws -> Int32 {
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        for (original, replacement) in [
            (#selector(getter: URLSessionConfiguration.default), #selector(URLSessionConfiguration.testDefault)),
            (#selector(getter: URLSessionConfiguration.ephemeral), #selector(URLSessionConfiguration.testEphemeral))
        ] {
            method_exchangeImplementations(
                class_getClassMethod(URLSessionConfiguration.self, original)!,
                class_getClassMethod(URLSessionConfiguration.self, replacement)!
            )
        }
        defaults.removeObject(forKey: UpdateBadge.pendingVersionKey)
        defaults.removeObject(forKey: UpdateBadge.pendingNotesKey)
        let downloader = UpdateDownloader()
        var failures: [String] = []
        for patch in [1, 2, 1, 3, 1, 4, 1, 5] {
            let version = "0.111.\(patch)"
            downloader.startDownload(version: version)
            downloader.startDownload(version: "0.111.99")
            let deadline = ContinuousClock.now + .seconds(3)
            while downloader.phase.isBusy && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(UpdateResponses.paths.contains { $0.hasSuffix("/v\(version)") },
                         "The real notes request did not reach the test transport")
            guard case .failed = downloader.phase else {
                preconditionFailure("Package requests must fail before installation")
            }
            let expected = patch == 1 ? "Notes A" : nil
            let actual = defaults.string(forKey: UpdateBadge.pendingNotesKey)
            if actual != expected {
                failures.append("v\(version): expected \(String(describing: expected)), got \(String(describing: actual))")
            }
            precondition(defaults.string(forKey: UpdateBadge.pendingVersionKey) == nil)
        }
        precondition(UpdateResponses.paths.count == 24,
                     "Expected notes, Lanzou and GitHub requests for each attempt")
        downloader.phase = .installing
        defaults.set("Installing notes", forKey: UpdateBadge.pendingNotesKey)
        downloader.startDownload(version: "0.111.99")
        precondition(downloader.phase == .installing)
        precondition(defaults.string(forKey: UpdateBadge.pendingNotesKey) == "Installing notes")
        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            return 1
        }
        print("PASS: real startDownload path clears stale notes after HTTP, empty-body, JSON and timeout failures; successful notes and busy downloads are preserved")
        return 0
    }
}
