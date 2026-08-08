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

                HStack(spacing: 12) {
                    Button(action: checkForUpdates) {
                        if case .checking = updateState {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                                Text("检查中…")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        } else {
                            Text("检查更新")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .disabled(updateState == .checking)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .alert(item: alertBinding) { result in
            switch result {
            case .upToDate(let version):
                return Alert(
                    title: Text("已是最新版本"),
                    message: Text("当前版本 v\(version) 已是最新"),
                    dismissButton: .default(Text("好的"))
                )
            case .updateAvailable(let latestVersion, let releaseURL, let isDowngrade):
                if isDowngrade {
                    return Alert(
                        title: Text("正式版可用 v\(latestVersion)"),
                        message: Text("当前为开发版本 v\(appVersion)\n是否切换到正式版？"),
                        primaryButton: .default(Text("前往下载")) {
                            NSWorkspace.shared.open(releaseURL)
                        },
                        secondaryButton: .cancel(Text("继续使用开发版"))
                    )
                } else {
                    return Alert(
                        title: Text("发现新版本 v\(latestVersion)"),
                        message: Text("当前版本：v\(appVersion)\n是否前往下载页面？"),
                        primaryButton: .default(Text("前往下载")) {
                            NSWorkspace.shared.open(releaseURL)
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
                // Should never be shown — alertBinding filters these out.
                return Alert(title: Text(""))
            }
        }
    }

    // MARK: - About tab actions

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

    private var alertBinding: Binding<UpdateCheckState?> {
        Binding {
            if case .idle = updateState { return nil }
            if case .checking = updateState { return nil }
            return updateState
        } set: { _ in
            updateState = .idle
        }
    }

    /// Strip pre-release suffix (e.g. "-dev") for version comparison.
    /// "0.82.0-dev" → "0.82.0" so that a released "0.82.0" is correctly
    /// detected as newer.
    private static func stripDevSuffix(_ version: String) -> String {
        version.components(separatedBy: "-").first ?? version
    }
    private func stripDevSuffix(_ version: String) -> String { Self.stripDevSuffix(version) }

    private func checkForUpdates() {
        guard case .idle = updateState else { return }
        updateState = .checking

        let url = URL(string: "https://api.github.com/repos/wonaren/copyattach-release/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    updateState = .error("无法连接到更新服务器：\(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    updateState = .error("无效的服务器响应")
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    break // continue parsing
                case 404:
                    updateState = .error("未找到版本信息（仓库中尚无正式 Release）")
                    return
                case 403:
                    updateState = .error("API 请求过于频繁，请稍后再试")
                    return
                default:
                    updateState = .error("服务器返回错误 (HTTP \(httpResponse.statusCode))")
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    updateState = .error("无法解析更新信息")
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let currentVersion = self.appVersion
                let currentBase = stripDevSuffix(currentVersion)
                let isDev = currentVersion != currentBase

                let releaseURL: URL
                if let htmlURL = json["html_url"] as? String, let url = URL(string: htmlURL) {
                    releaseURL = url
                } else {
                    releaseURL = URL(string: "https://github.com/wonaren/copyattach-release/releases/tag/v\(latestVersion)")!
                }

                if latestVersion.compare(currentBase, options: .numeric) == .orderedDescending {
                    // Normal upgrade: a newer version exists
                    updateState = .updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: false)
                } else if isDev {
                    // Dev → stable: offer the stable release even if it's the same
                    // version number or slightly behind (downgrade from dev)
                    updateState = .updateAvailable(latestVersion: latestVersion, releaseURL: releaseURL, isDowngrade: true)
                } else {
                    updateState = .upToDate(currentVersion: currentVersion)
                }
            }
        }.resume()
    }

    private var todoBadge: some View {
        Text("TODO")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Color(red: 0.92, green: 0.58, blue: 0.20))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(red: 0.92, green: 0.58, blue: 0.20).opacity(0.15))
            .cornerRadius(4)
    }
}
