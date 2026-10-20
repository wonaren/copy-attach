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

                JustifiedParagraph(
                    text: "CopyAttach 是一款极轻量的剪贴板历史管理应用,它在性能体验、内存占用、存储效率、功耗表现、操作逻辑、UI界面都经过精心设计,旨在为用户提供一个简洁、高效、无负担的剪贴板历史管理工具。",
                    font: .systemFont(ofSize: 12.5),
                    textColor: NSColor(theme.secondaryText),
                    width: 320
                )

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
            case .idle:
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
            // Secondary action, in the same neutral idiom as the rest of
            // Settings (buttonBackground + cardBorder). A filled accent put
            // white on #007AFF at 4.0:1 — under AA — and while an update was
            // pending it competed with the one action that actually matters.
            Button {
                checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if isCheckingUpdate {
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
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.buttonBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.buttonBorder, lineWidth: 1)
                )
            }
            .disabled(isCheckingUpdate)
            .buttonStyle(.plain)

            // Primary action, only while an update is pending. The version
            // rides in the label: it used to be a separate red badge pinned
            // over the check button, shown under the exact same condition, so
            // it carried no information the download button didn't already
            // carry — at 3.4:1 for 9 pt text.
            if case .updateAvailable(let latestVersion, _, _) = updateState {
                Button {
                    startDirectDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                        Text("下载更新")
                            .font(.system(size: 12, weight: .medium))
                        Text("v\(latestVersion)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(theme.updateActionText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.updateActionBackground)
                    .cornerRadius(6)
                }
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
        URL(string: "https://github.com/wonaren/copy-attach/releases")
    }
    private var authorGitHubURL: URL? {
        URL(string: "https://github.com/wonaren")
    }

    private func openWebsite() {
        guard let repoURL else { return }
        NSWorkspace.shared.open(repoURL)
    }

    /// Silent check when the About tab appears. Never shows the alert — the
    /// result surfaces only through the badge / download button.
    ///
    /// The last known answer is painted immediately; the network is only hit
    /// when that cache has aged out. Opening a settings tab must never wait on
    /// a socket, and a check must cost the fastest source's latency rather
    /// than the slowest one's timeout (see `UpdateChecker`).
    private func autoCheckForUpdates() {
        if let cached = UpdateChecker.cachedRelease() {
            evaluateVersion(latestVersion: cached.version,
                            releaseURL: cached.releaseURL,
                            showAlert: false)
        }
        guard UpdateChecker.cachedRelease(maxAge: UpdateChecker.cacheLifetime) == nil else { return }
        checkForUpdates(showAlert: false)
    }

    /// Seamless update: download + install in the background (lanzou first,
    /// GitHub fallback), then auto-relaunch. No browser, no manual steps.
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

    /// Check for updates without blocking the UI. Manual checks always bypass
    /// the cache. The spinner lives in `isCheckingUpdate`, so a revalidation
    /// never erases the result currently on screen.
    private func checkForUpdates(showAlert: Bool = true) {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task { @MainActor in
            defer { isCheckingUpdate = false }
            do {
                let release = try await UpdateChecker.latestRelease()
                evaluateVersion(latestVersion: release.version,
                                releaseURL: release.releaseURL,
                                showAlert: showAlert)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "无法连接到更新服务器：\(error.localizedDescription)"
                debugLog("[update] check failed: \(error.localizedDescription)")
                // A silent revalidation failure must not wipe a cached result
                // (that would hide a known update and its download button) —
                // only a manual check or a blank tab surfaces the error.
                if showAlert || updateState == .idle {
                    finishUpdateCheck(.error(message), showAlert: showAlert)
                }
            }
        }
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

    /// Terminal-state sink: drives the badge / download button, and optionally
    /// the alert (manual checks only — auto checks stay silent).
    private func finishUpdateCheck(_ result: UpdateCheckState, showAlert: Bool) {
        updateState = result
        if showAlert { updateAlert = result }
    }
}
