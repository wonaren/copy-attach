import AppKit
import SwiftUI

// MARK: - ⚪ ABOUT TAB

extension InlineSettingsView {
    var aboutTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: .appIconSVG ?? .appIcon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                VStack(spacing: 6) {
                    Text("CopyAttach")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    HStack(spacing: 5) {
                        Text("版本")
                            .foregroundColor(theme.secondaryText)
                        Text("v\(appVersion)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                    }
                    .font(.system(size: 13))

                    Button {
                        if let authorGitHubURL {
                            NSWorkspace.shared.open(authorGitHubURL)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let img = githubIconImage() {
                                Image(nsImage: img)
                                    .resizable()
                                    .frame(width: 13, height: 13)
                            }
                            Text("wonaren")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("github.com/wonaren")
                }

                Text("CopyAttach 是一款极轻量的剪贴板历史管理应用,它在性能体验、内存占用、存储效率、功耗表现、操作逻辑、UI界面都经过精心设计,旨在为用户提供一个简洁、高效、无负担的剪贴板历史管理工具。")
                    .font(.system(size: 12.5))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 300)

                Group {
                    if updater.phase.isBusy {
                        updateProgressCard
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    } else {
                        updateButtonsRow
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: updater.phase.isBusy)
                .animation(.easeOut(duration: 0.2), value: updateState)
                .padding(.top, 4)

                if case .failed(let message) = updater.phase {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                        // Manual escape hatch when programmatic download fails:
                        // open the release page / lanzou share in the browser.
                        Button {
                        if let repoURL {
                            NSWorkspace.shared.open(repoURL)
                        }
                        } label: {
                            Text("在浏览器中打开下载页")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .alert(item: $updateAlert) { result in
            switch result {
            case .upToDate(let version):
                return Alert(
                    title: Text("已是最新版本"),
                    message: Text("当前版本 v\(version) 已是最新"),
                    dismissButton: .default(Text("好的"))
                )
            case .updateAvailable(let latestVersion, _, let isDowngrade):
                if isDowngrade {
                    return Alert(
                        title: Text("正式版可用 v\(latestVersion)"),
                        message: Text("当前为开发版本 v\(appVersion)\n是否立即下载并安装？"),
                        primaryButton: .default(Text("立即下载")) {
                            startDirectDownload()
                        },
                        secondaryButton: .cancel(Text("继续使用开发版"))
                    )
                } else {
                    return Alert(
                        title: Text("发现新版本 v\(latestVersion)"),
                        message: Text("当前版本：v\(appVersion)\n是否立即下载并安装？"),
                        primaryButton: .default(Text("立即下载")) {
                            startDirectDownload()
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                }
            case .error(let message):
                return Alert(
                    title: Text("检查更新失败"),
                    message: Text(message),
                    dismissButton: .default(Text("好的"))
                )
            case .idle, .checking:
                // Should never be shown — updateAlert is only set for terminal states.
                return Alert(title: Text(""))
            }
        }
        .onAppear {
            autoCheckForUpdates()
        }
    }

    // MARK: - About tab actions

    private var updateButtonsRow: some View {
        HStack(spacing: 12) {
            Button {
                checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if case .checking = updateState {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                        Text("检查中…")
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text("检查更新")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .disabled(updateState == .checking)
            .background(Color.accentColor)
            .foregroundColor(theme.buttonText)
            .cornerRadius(6)
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                // Red badge showing the latest version when an update exists.
                if case .updateAvailable(let latestVersion, _, _) = updateState {
                    Text("v\(latestVersion)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

            // Green download button, only shown when an update exists.
            if case .updateAvailable = updateState {
                Button {
                    startDirectDownload()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text("下载更新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color.green)
                .foregroundColor(theme.buttonText)
                .cornerRadius(6)
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }

    private var updateProgressCard: some View {
        VStack(spacing: 8) {
            // 上方：通栏进度条
            if case .downloading(let progress) = updater.phase {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if case .installing = updater.phase {
                ProgressView(value: 1.0)
                    .progressViewStyle(.linear)
            }

            // 下方：提示文案与进度百分比/状态指示
            HStack(spacing: 6) {
                if case .downloading(let progress) = updater.phase {
                    Text("下载中...")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                } else if case .installing = updater.phase {
                    Text("安装更新...")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 250)
        .background(theme.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder.opacity(0.5), lineWidth: 1)
        )
    }

    private func githubIconImage() -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("github.svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    private var repoURL: URL? {
        URL(string: "https://github.com/wonaren/copyattach-release")
    }
    private var authorGitHubURL: URL? {
        URL(string: "https://github.com/wonaren")
    }

    private func openWebsite() {
        guard let repoURL else { return }
        NSWorkspace.shared.open(repoURL)
    }

    /// Silent check when the About tab appears. Never shows the alert —
    /// the result surfaces only through the badge / download button.
    /// Retried on re-entry after an error, but not after a successful check.
    private func autoCheckForUpdates() {
        switch updateState {
        case .idle, .error:
            checkForUpdates(showAlert: false)
        default:
            break
        }
    }

    /// Seamless update: download + install in the background (GitHub first,
    /// lanzou fallback), then auto-relaunch. No browser, no manual steps.
    private func startDirectDownload() {
        guard case .updateAvailable(let latestVersion, _, _) = updateState else { return }
        updater.startDownload(version: latestVersion)
    }

    /// Strip pre-release suffix (e.g. "-dev") for version comparison.
    /// "0.82.0-dev" → "0.82.0" so that a released "0.82.0" is correctly
    /// detected as newer.
    private static func stripDevSuffix(_ version: String) -> String {
        version.components(separatedBy: "-").first ?? version
    }
    private func stripDevSuffix(_ version: String) -> String { Self.stripDevSuffix(version) }

    nonisolated private static let cloudflareUpdateURL = URL(string: "https://dl.abovepast.shop/healthz")
    nonisolated private static let githubLatestReleaseURL = URL(string: "https://github.com/wonaren/copyattach-release/releases/latest")

    private struct HealthzPayload: Decodable {
        let version: String?
    }

    /// Two-phase update check:
    /// 1. Primary: queries the Cloudflare-accelerated endpoint (dl.abovepast.shop/healthz)
    ///    which provides cached version info in ~50ms, unaffected by GitHub DNS pollution or timeouts.
    /// 2. Fallback: HEAD request to GitHub's web endpoint (releases/latest), which redirects
    ///    to the latest tag page for zero bytes without REST API rate limits.
    private func checkForUpdates(showAlert: Bool = true) {
        guard updateState != .checking else { return }
        updateState = .checking
        checkViaCloudflare(showAlert: showAlert)
    }

    private func checkViaCloudflare(showAlert: Bool) {
        guard let url = Self.cloudflareUpdateURL else {
            checkViaGitHub(showAlert: showAlert)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6

        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            if let error {
                debugLog("[update] Cloudflare check failed: \(error.localizedDescription); falling back to GitHub")
                DispatchQueue.main.async {
                    checkViaGitHub(showAlert: showAlert)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let data,
                  let payload = try? JSONDecoder().decode(HealthzPayload.self, from: data),
                  let rawVersion = payload.version, !rawVersion.isEmpty else {
                debugLog("[update] Cloudflare check returned invalid payload; falling back to GitHub")
                DispatchQueue.main.async {
                    checkViaGitHub(showAlert: showAlert)
                }
                return
            }

            let latestVersion = Self.cleanVersionTag(rawVersion)
            let releaseURL = URL(string: "https://github.com/wonaren/copyattach-release/releases/tag/v\(latestVersion)")
                ?? Self.githubLatestReleaseURL!

            DispatchQueue.main.async {
                evaluateVersion(latestVersion: latestVersion, releaseURL: releaseURL, showAlert: showAlert)
            }
        }.resume()
    }

    private func checkViaGitHub(showAlert: Bool) {
        guard let url = Self.githubLatestReleaseURL else {
            finishUpdateCheck(.error("更新地址无效"), showAlert: showAlert)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    debugLog("[update] GitHub check failed: \(error.localizedDescription)")
                    finishUpdateCheck(.error("无法连接到更新服务器：\(error.localizedDescription)"), showAlert: showAlert)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    debugLog("[update] check failed: non-HTTP response")
                    finishUpdateCheck(.error("无效的服务器响应"), showAlert: showAlert)
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    break // redirect resolved; the final URL carries the tag
                case 404:
                    debugLog("[update] check failed: HTTP 404 (no published release)")
                    finishUpdateCheck(.error("未找到版本信息（仓库中尚无正式 Release）"), showAlert: showAlert)
                    return
                case 403, 429:
                    debugLog("[update] check failed: HTTP \(httpResponse.statusCode) (throttled)")
                    finishUpdateCheck(.error("请求过于频繁，请稍后再试"), showAlert: showAlert)
                    return
                default:
                    debugLog("[update] check failed: HTTP \(httpResponse.statusCode)")
                    finishUpdateCheck(.error("服务器返回错误 (HTTP \(httpResponse.statusCode))"), showAlert: showAlert)
                    return
                }

                // Redirect target is the release page itself: …/releases/tag/v0.106.0
                guard let releaseURL = httpResponse.url,
                      let latestVersion = Self.releaseTag(from: releaseURL) else {
                    debugLog("[update] check failed: no tag in \(httpResponse.url?.absoluteString ?? "nil")")
                    finishUpdateCheck(.error("无法解析更新信息"), showAlert: showAlert)
                    return
                }

                evaluateVersion(latestVersion: latestVersion, releaseURL: releaseURL, showAlert: showAlert)
            }
        }.resume()
    }

    private func evaluateVersion(latestVersion: String, releaseURL: URL, showAlert: Bool) {
        debugLog("[update] latest release is v\(latestVersion) (local v\(appVersion))")

        let currentVersion = self.appVersion
        let currentBase = stripDevSuffix(currentVersion)
        let isDev = currentVersion != currentBase

        if latestVersion.compare(currentBase, options: .numeric) == .orderedDescending {
            // Normal upgrade: a newer version exists
            finishUpdateCheck(.updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: false), showAlert: showAlert)
        } else if isDev {
            // Dev → stable: offer the stable release even if it's the same
            // version number or slightly behind (downgrade from dev)
            finishUpdateCheck(.updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: true), showAlert: showAlert)
        } else {
            finishUpdateCheck(.upToDate(currentVersion: currentVersion), showAlert: showAlert)
        }
    }

    /// Clean a raw tag string (e.g. "v0.107.0" or "0.107.0") to purely numeric version string.
    nonisolated private static func cleanVersionTag(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while v.hasPrefix("v") || v.hasPrefix("V") {
            v.removeFirst()
        }
        return v
    }

    /// Pull the tag out of a `…/releases/tag/<tag>` URL, stripping any
    /// leading "v" or "V" so the version string is purely numeric ("0.107.0").
    nonisolated private static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "tag"), i + 1 < parts.count else { return nil }
        let tag = parts[(i + 1)...].joined(separator: "/")
        guard !tag.isEmpty else { return nil }
        return cleanVersionTag(tag)
    }

    /// Terminal-state sink: drives the badge / download button, and optionally
    /// the alert (manual checks only — auto checks stay silent).
    private func finishUpdateCheck(_ result: UpdateCheckState, showAlert: Bool) {
        updateState = result
        if showAlert { updateAlert = result }
    }
}
