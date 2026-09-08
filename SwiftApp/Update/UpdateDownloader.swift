import AppKit
import Combine
import Foundation

// MARK: - Update downloader

/// Seamless update engine: downloads the installer in the background (lanzou
/// via NFD cloud parser first, GitHub release as fallback), then installs and
/// relaunches.
///
/// Download sources:
///   - 蓝奏云 (primary): fixed share `https://wwbvw.lanzouv.com/b0341lhs5g`,
///     password `1234`, file `CopyAttach-v<version>-macOS.zip`, resolved through
///     the NFD cloud parser (`lz0.qaiu.top`) which yields a plain HTTPS direct
///     link on its own CDN. Verified end-to-end (0.5s / 2.7MB). The lanzou
///     native download hop (`developer2.lanrar.com/file/?token`) rejects
///     non-browser clients (400 Time Out), so it is not used directly.
///   - GitHub (fallback): `https://github.com/wonaren/copyattach-release/releases/
///     download/v<version>/CopyAttach-<version>.dmg`
@MainActor
final class UpdateDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateDownloader()

    @Published var phase: DownloadPhase = .idle

    enum DownloadPhase: Equatable {
        case idle
        case downloading(Double)  // progress 0...1
        case installing
        case failed(String)

        /// True while a download/install is in flight. Used to drive the
        /// appear/disappear animation only — progress updates must NOT be
        /// implicitly animated (an easeOut on every tick makes the bar look
        /// frozen while the download races ahead of the interpolation).
        var isBusy: Bool {
            switch self {
            case .downloading, .installing: return true
            case .idle, .failed: return false
            }
        }
    }

    enum UpdateError: LocalizedError, Equatable {
        case github(String)
        case lanzou(String)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .github(let m), .lanzou(let m), .install(let m): return m
            }
        }
    }

    // 蓝奏云 share constants (fixed share + fixed password, per release distribution)
    private static let lanzouShareURL = URL(string: "https://wwbvw.lanzouv.com/b0341lhs5g")!
    private static let lanzouPassword = "1234"
    private static let lanzouFileBase = "https://wwbvw.lanzouv.com/"
    /// NFD cloud parser: resolves lanzou shares to plain HTTPS direct links
    /// (verified working; the lanzou native hop rejects non-browser clients).
    private static let nfdBase = "https://lz0.qaiu.top"

    private let dataSession: URLSession
    private var downloadSession: URLSession?
    /// Written on the main thread in `downloadFile`; read in the download
    /// delegate callbacks, which run on the main queue (delegateQueue: .main).
    /// nonisolated(unsafe) because the synchronous move in the callback must
    /// not hop — URLSession deletes the temp file when the callback returns.
    nonisolated(unsafe) private var downloadContinuation: CheckedContinuation<URL, Error>?
    nonisolated(unsafe) private var downloadDestination: URL?

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30 * 60
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
        ]
        dataSession = URLSession(configuration: config)
        super.init()
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Public API

    func startDownload(version: String) {
        switch phase {
        case .downloading, .installing:
            return
        case .idle, .failed:
            break
        }
        phase = .downloading(0)
        debugLog("[update] start download of v\(version)")
        Self.cleanupLegacyArtifacts()
        Task { await performDownload(version: version) }
    }

    // MARK: - Download pipeline

    private func performDownload(version: String) async {
        do {
            // 1) 蓝奏云 via NFD cloud parser (primary — stable, no anti-bot);
            //    GitHub release asset as fallback.
            let package: URL
            do {
                debugLog("[update] downloading from lanzou (NFD): v\(version)")
                package = try await downloadFromLanzou(version: version)
            } catch {
                debugLog("[update] lanzou failed: \(error.localizedDescription); falling back to GitHub")
                package = try await downloadFromGitHub(version: version)
            }

            // 2) verify + install
            guard Self.looksLikeInstaller(package) else {
                throw UpdateError.install("下载的安装包无效（文件不完整）")
            }
            phase = .installing
            try install(package: package, version: version)
        } catch {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            debugLog("[update] FAILED: \(message)")
            phase = .failed(message)
        }
    }

    private func downloadFromGitHub(version: String) async throws -> URL {
        let url = githubAssetURL(version: version)
        guard await githubReachable(url) else {
            throw UpdateError.github("GitHub 下载失败：无法连接")
        }
        debugLog("[update] downloading from GitHub: \(url.absoluteString)")
        return try await downloadFile(from: url)
    }

    private func githubAssetURL(version: String) -> URL {
        URL(string: "https://github.com/wonaren/copyattach-release/releases/download/v\(version)/CopyAttach-\(version).dmg")!
    }

    /// Cheap preflight so a blocked GitHub (DNS pollution / GFW) falls back to
    /// lanzou without making the user stare at 0% progress.
    private func githubReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await dataSession.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    // MARK: - Lanzou flow (via NFD cloud parser)

    /// Two-step resolution through NFD: folder listing → pick the matching
    /// version → direct link on NFD's CDN. The direct hop is a plain HTTPS
    /// download with progress reporting.
    private func downloadFromLanzou(version: String) async throws -> URL {
        // 1) folder listing (password-protected share)
        let listURL = URL(string: "\(Self.nfdBase)/v2/getFileList?url=\(Self.urlEncode(Self.lanzouShareURL.absoluteString))&pwd=\(Self.lanzouPassword)")!
        let listJSON = try await fetchJSON(listURL)
        guard let files = listJSON["data"] as? [[String: Any]] else {
            throw UpdateError.lanzou("蓝奏云文件列表解析失败")
        }
        // Architecture selection, strictest first. A bare `contains(version)`
        // also matched a longer version sharing the prefix (v0.101.4 vs
        // v0.101.40), and excluding only the *other* arch silently accepted an
        // unmarked build — which can be the wrong architecture entirely.
        #if arch(arm64)
        let wantedArch = "arm64"
        let otherArch = "x86_64"
        #else
        let wantedArch = "x86_64"
        let otherArch = "arm64"
        #endif
        // The trailing separator is what kills the version-prefix ambiguity.
        let versionTokens = ["v\(version)-", "\(version)-"]
        let candidates: [(name: String, id: String)] = files.compactMap { file in
            guard let name = file["fileName"] as? String,
                  let id = file["fileId"] as? String,
                  name.lowercased().hasSuffix(".zip"),
                  versionTokens.contains(where: { name.contains($0) }) else { return nil }
            return (name, id)
        }
        let chosen = candidates.first { $0.name.contains(wantedArch) }
            ?? candidates.first { !$0.name.contains(otherArch) }
        guard let entry = chosen else {
            let seen = candidates.map(\.name).prefix(5).joined(separator: ", ")
            throw UpdateError.lanzou("蓝奏云上未找到版本 \(version) 的 \(wantedArch) 安装包（候选：\(seen.isEmpty ? "无" : seen)）")
        }
        let fileName = entry.name
        let fileID = entry.id
        debugLog("[update] lanzou (NFD) found: \(fileName)")

        // 2) resolve the direct link
        let fileURL = Self.lanzouFileBase + fileID  // fileID may carry ?webpage=…
        let parserURL = URL(string: "\(Self.nfdBase)/json/parser?url=\(Self.urlEncode(fileURL))&pwd=\(Self.lanzouPassword)")!
        let parserJSON = try await fetchJSON(parserURL)
        guard let data = parserJSON["data"] as? [String: Any],
              let directLink = data["directLink"] as? String,
              let directURL = URL(string: directLink) else {
            throw UpdateError.lanzou("蓝奏云直链解析失败")
        }
        debugLog("[update] lanzou direct link resolved: \(directURL.host ?? "?")")
        return try await downloadFile(from: directURL)
    }

    /// GET a URL and decode its JSON body (non-200 codes surface as errors).
    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await dataSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.lanzou("直链解析服务请求失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.lanzou("直链解析服务响应无法解析")
        }
        guard let code = json["code"] as? Int, code == 200 else {
            let msg = json["msg"] as? String ?? "未知错误"
            throw UpdateError.lanzou("直链解析失败：\(msg)")
        }
        return json
    }

    // MARK: - Download primitives



    private func downloadFile(from url: URL) async throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CopyAttachUpdate", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(url.lastPathComponent.isEmpty ? "installer.bin" : url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let downloadSession else { throw UpdateError.install("下载器未就绪") }
        let task = downloadSession.downloadTask(with: request)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            downloadContinuation = cont
            downloadDestination = destination
            task.resume()
        }
    }

    // MARK: - Install

    /// Install the package (DMG or ZIP containing a DMG) over the running app,
    /// then relaunch via a detached script (the script must be the last thing
    /// to touch this process — SIGTERM terminates it immediately).
    private func install(package: URL, version: String) throws {
        let fm = FileManager.default
        let myPID = ProcessInfo.processInfo.processIdentifier
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CopyAttachUpdate-install-\(myPID)", isDirectory: true)
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        var dmg = package
        if package.pathExtension.lowercased() == "zip" {
            debugLog("[update] unzipping lanzou package")
            let unzipDir = workDir.appendingPathComponent("unzipped", isDirectory: true)
            try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            try runAndCheck("/usr/bin/ditto", ["-x", "-k", package.path, unzipDir.path], "解压安装包失败")
            guard let found = try fm.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension.lowercased() == "dmg" }) else {
                throw UpdateError.install("安装包内未找到 DMG")
            }
            dmg = found
        }

        let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try runAndCheck("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmg.path], "挂载安装包失败")
        var isMounted = true
        defer {
            if isMounted {
                _ = try? runCapture("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
            }
        }

        let appSrc = mountPoint.appendingPathComponent("CopyAttach.app")
        guard fm.fileExists(atPath: appSrc.path) else {
            throw UpdateError.install("安装包内缺少 CopyAttach.app")
        }

        let appDest = Bundle.main.bundleURL
        let staging = appDest.deletingLastPathComponent()
            .appendingPathComponent(".CopyAttach-update-staging-\(myPID)", isDirectory: true)
        try? fm.removeItem(at: staging)
        debugLog("[update] staging new app (\(version)) at \(staging.path)")
        try runAndCheck("/bin/cp", ["-R", appSrc.path, staging.path], "复制新版本失败")

        // Unmount disk image in main flow; fail explicitly if detach fails.
        try runAndCheck("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"], "卸载安装包失败")
        isMounted = false

        try? fm.removeItem(at: appDest)
        do {
            try fm.moveItem(at: staging, to: appDest)
        } catch {
            try? fm.removeItem(at: staging)
            throw UpdateError.install("替换应用失败：\(error.localizedDescription)")
        }
        debugLog("[update] new app installed at \(appDest.path)")

        // Detached relaunch script: kill this process, clean up temp dirs, then open the new app.
        phase = .installing
        let downloadDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CopyAttachUpdate", isDirectory: true)
        let scriptURL = workDir.appendingPathComponent("relaunch.sh")
        let script = """
        #!/bin/bash
        exec >> \(Self.shq(debugLogPath)) 2>&1
        echo "[update] relaunch: killing pid \(myPID)"
        kill \(myPID) 2>/dev/null || true
        for _ in $(seq 1 50); do
          kill -0 \(myPID) 2>/dev/null || break
          sleep 0.1
        done
        kill -9 \(myPID) 2>/dev/null || true
        open \(Self.shq(appDest.path))
        echo "[update] relaunch issued"
        rm -rf \(Self.shq(workDir.path)) 2>/dev/null || true
        rm -rf \(Self.shq(downloadDir.path)) 2>/dev/null || true
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try runAndCheck("/bin/bash", [scriptURL.path], "启动更新脚本失败")
    }

    private var debugLogPath: String { "/tmp/copyattach_debug.log" }

    // MARK: - Process helpers

    @discardableResult
    private func runCapture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.install("\(URL(fileURLWithPath: executable).lastPathComponent) 退出码 \(process.terminationStatus)：\(output.prefix(200))")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func runAndCheck(_ executable: String, _ arguments: [String], _ failureMessage: String) throws {
        do {
            try runCapture(executable, arguments)
        } catch {
            throw UpdateError.install("\(failureMessage)（\(error.localizedDescription)）")
        }
    }

    // MARK: - URLSessionDownloadDelegate

    /// The class must stay @MainActor for its published state; the session
    /// delegate callbacks arrive on the main queue and hop explicitly.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        Task { @MainActor in
            if case .downloading = self.phase {
                self.phase = .downloading(progress)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temp file must be moved SYNCHRONOUSLY in this callback: URLSession
        // removes it as soon as the callback returns. An async hop (Task) risks
        // racing a busy main thread and failing with "couldn't be moved…".
        guard let destination = downloadDestination else { return }
        let continuation = downloadContinuation
        downloadContinuation = nil
        do {
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                continuation?.resume(returning: destination)
            }
        } catch {
            Task { @MainActor in
                continuation?.resume(throwing: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let continuation = downloadContinuation
        downloadContinuation = nil
        Task { @MainActor in
            continuation?.resume(throwing: error)
        }
    }

    // MARK: - Lanzou challenge solver

    /// acw_sc__v2 anti-crawler challenge: fixed permutation of `arg1` followed
    /// by a hex XOR with the known key (reimplemented from the share page's JS).


    // MARK: - Helpers


    static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// DMG (koly trailer at EOF) or ZIP (PK magic at start).
    static func looksLikeInstaller(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 512 else { return false }
        handle.seek(toFileOffset: 0)
        let head = handle.readData(ofLength: 4)
        if head == Data("PK\u{03}\u{04}".utf8) { return true }
        handle.seek(toFileOffset: size - 512)
        let trailer = handle.readData(ofLength: 512)
        return trailer.contains(Data("koly".utf8))
    }

    private static func shq(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Legacy cleanup

    /// Detaches any lingering disk images and removes temporary update directories.
    nonisolated static func cleanupLegacyArtifacts() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let tmpPath = NSTemporaryDirectory()
            let tmpURL = URL(fileURLWithPath: tmpPath, isDirectory: true)

            detachStaleUpdateImages()

            if let items = try? fm.contentsOfDirectory(atPath: tmpPath) {
                for item in items where item.hasPrefix("CopyAttachUpdate") {
                    let itemURL = tmpURL.appendingPathComponent(item)
                    try? fm.removeItem(at: itemURL)
                }
            }
        }
    }

    nonisolated private static func detachStaleUpdateImages() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]] else { return }
            for image in images {
                let imagePath = (image["image-path"] as? String) ?? ""
                let entities = (image["system-entities"] as? [[String: Any]]) ?? []
                let isUpdateImage = imagePath.contains("CopyAttachUpdate")
                for entity in entities {
                    let mountPoint = (entity["mount-point"] as? String) ?? ""
                    let devEntry = (entity["dev-entry"] as? String) ?? ""
                    if isUpdateImage || mountPoint.contains("CopyAttachUpdate") {
                        let target = !mountPoint.isEmpty ? mountPoint : devEntry
                        if !target.isEmpty {
                            debugLog("[update] detaching stale mount: \(target)")
                            let detachProc = Process()
                            detachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                            detachProc.arguments = ["detach", target, "-force", "-quiet"]
                            try? detachProc.run()
                            detachProc.waitUntilExit()
                        }
                    }
                }
            }
        } catch {
            debugLog("[update] failed to query hdiutil info: \(error.localizedDescription)")
        }
    }
}
