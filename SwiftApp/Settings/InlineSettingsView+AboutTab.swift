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
                        NSWorkspace.shared.open(authorGitHubURL)
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
                            NSWorkspace.shared.open(repoURL)
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
                        title: Text("发现新版本 \(latestVersion)"),
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
                    Text(latestVersion)
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

    private var repoURL: URL { URL(string: "https://github.com/wonaren/copyattach-release")! }
    private var authorGitHubURL: URL { URL(string: "https://github.com/wonaren")! }

    private func openWebsite() {
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

    /// Update check through GitHub's *web* endpoint, never the REST API.
    ///
    /// `api.github.com/repos/…/releases/latest` is anonymous-rate-limited to 60
    /// requests per hour **per source IP**, and that budget is shared by every
    /// other unauthenticated client behind the same NAT — campus, office and
    /// carrier networks exhaust it routinely. Once spent, the API answers 403
    /// and the check fails although nothing is wrong with the release. Measured
    /// here: `x-ratelimit-remaining: 0` on a shared egress IP, while the same
    /// machine's web requests were unaffected.
    ///
    /// `github.com/<repo>/releases/latest` is the plain web endpoint. It is not
    /// subject to that quota, and its 302 `Location` carries the same tag the
    /// API would have returned — both endpoints skip pre-releases and drafts,
    /// verified against repos whose newest release is a pre-release. A HEAD
    /// request follows the redirect for zero bytes, so the tag is read straight
    /// off the final URL.
    private func checkForUpdates(showAlert: Bool = true) {
        guard updateState != .checking else { return }
        updateState = .checking

        let url = URL(string: "https://github.com/wonaren/copyattach-release/releases/latest")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    debugLog("[update] check failed: \(error.localizedDescription)")
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
        }.resume()
    }

    /// Pull the tag out of a `…/releases/tag/<tag>` URL. Tags may contain
    /// slashes, so everything after `tag` is rejoined rather than taking one
    /// path component.
    private static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "tag"), i + 1 < parts.count else { return nil }
        let tag = parts[(i + 1)...].joined(separator: "/")
        return tag.isEmpty ? nil : tag
    }

    /// Terminal-state sink: drives the badge / download button, and optionally
    /// the alert (manual checks only — auto checks stay silent).
    private func finishUpdateCheck(_ result: UpdateCheckState, showAlert: Bool) {
        updateState = result
        if showAlert { updateAlert = result }
    }
}
