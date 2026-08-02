import AppKit
import SwiftUI

/// Mandatory startup/expiry gate. This is deliberately separate from Settings:
/// closing it without a valid entitlement terminates the application.
struct LicenseGateView: View {
    @State private var manager = LicenseManager.shared
    @State private var licenseKey = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            if manager.celebration == nil {
                if manager.state.permitsCoreFeatures {
                    activatedView
                        .transition(.opacity)
                } else {
                    gateContent
                        .transition(.opacity)
                }
            }

            // In-window celebration overlay, played right after activation.
            if let celebration = manager.celebration {
                LicenseCelebrationView(
                    kind: celebration.kind,
                    message: celebration.message,
                    subtitle: celebration.subtitle
                )
                .transition(.opacity)
                .allowsHitTesting(false)
                .task {
                    // Play the animation (~2s), then return to the license page
                    // so the user can confirm activation succeeded before the
                    // gate is dismissed.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    manager.finishCelebration()
                }
            }
        }
        .frame(width: 500, height: 470)
        .background(theme.background)
        .animation(.easeInOut(duration: 0.35), value: manager.celebration)
    }

    /// Post-activation confirmation, shown once the celebration ends. The gate
    /// stays open until the user dismisses it; closing it does not quit the app
    /// because the license is now active.
    private var activatedView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: activatedIcon)
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text(title).font(.system(size: 22, weight: .bold)).foregroundColor(theme.primaryText)
                Text(detail).font(.system(size: 12.5)).foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 390)
            }
            Spacer()
            Divider()
            HStack {
                Text("关闭此窗口后继续使用 CopyAttach，可在菜单栏访问全部功能。")
                    .font(.system(size: 10.5)).foregroundColor(theme.tertiaryText)
                Spacer()
                Button("完成") { AppDelegate.shared?.closeLicenseGate() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 500)
        .background(theme.background)
    }

    private var gateContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: .appIconSVG ?? .appIcon)
                    .resizable().frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                Text(title).font(.system(size: 20, weight: .bold)).foregroundColor(theme.primaryText)
                Text(detail).font(.system(size: 12)).foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 380)
            }
            .padding(.top, 18).padding(.bottom, 14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("输入许可证密钥").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
                Text("购买后获得以 CA- 开头的密钥。一个密钥最多激活 3 台 Mac。")
                    .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                TextField("CA-ABCD-EFGH-IJKL-MNOP-QRST-UVWX", text: $licenseKey)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .onSubmit { activate() }
                HStack {
                    Button("粘贴密钥") {
                        licenseKey = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    Spacer()
                    if manager.isWorking { ProgressView().controlSize(.small) }
                    Button("验证并激活") { activate() }
                        .buttonStyle(.borderedProminent).disabled(normalizedKey.isEmpty || manager.isWorking)
                }

                if let error = manager.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(.red)
                }

                if shouldOfferRetry {
                    Button("重新联网验证") { Task { await manager.refresh() } }
                        .disabled(manager.isWorking)
                }

                if canStartTrial {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有许可证？").font(.system(size: 12, weight: .medium))
                            Text("可先免费体验全部功能 30 天").font(.system(size: 10.5)).foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                        Button("开始免费试用") { Task { await manager.startTrial() } }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(manager.isWorking)
                    }
                }

                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有激活密钥？").font(.system(size: 12, weight: .medium))
                        Text("在购买页面支付后获得以 CA- 开头的密钥").font(.system(size: 10.5)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(LicenseManager.purchaseURL)
                    } label: {
                        Label("购买密钥", systemImage: "cart.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(16)

            Divider()
            HStack {
                Text("不激活或关闭此窗口将退出 CopyAttach")
                    .font(.system(size: 10.5)).foregroundColor(theme.tertiaryText)
                Spacer()
                Button("退出应用") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 500)
        .background(theme.background)
    }

    private var normalizedKey: String { licenseKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func activate() { guard !normalizedKey.isEmpty else { return }; Task { await manager.activate(key: normalizedKey) } }
    private var canStartTrial: Bool { if case .notStarted = manager.state { return true }; return false }
    private var shouldOfferRetry: Bool { if case .needsOnlineVerification = manager.state { return true }; return false }
    private var title: String {
        switch manager.state {
        case .trialExpired: return "免费试用已结束"
        case .subscriptionExpired: return "限时许可证已到期"
        case .deviceLimitReached: return "许可证设备数量已达上限"
        case .revoked: return "许可证已停用"
        case .suspended: return "许可证已暂停"
        case .needsUpdate: return "请升级 CopyAttach"
        case .needsOnlineVerification: return "需要验证许可证"
        case .invalidLease: return "许可证凭证无效"
        case .error: return "无法验证许可证"
        case .trialActive: return "免费试用已开启"
        case .licensed: return "永久许可证已激活"
        case .subscriptionActive: return "限时许可证已激活"
        default: return "激活 CopyAttach"
        }
    }
    private var detail: String {
        switch manager.state {
        case .trialExpired: return "继续使用 CopyAttach 需要永久许可证。您的本地剪贴板历史不会被删除。"
        case .subscriptionExpired: return "当前限时许可证已到期，请输入新的有效许可证。您的本地剪贴板历史不会被删除。"
        case .deviceLimitReached: return "此密钥已绑定 3 台设备，请先解绑旧设备，或使用其他许可证密钥。"
        case .revoked: return "当前许可证已撤销、退款或停用，无法继续运行 CopyAttach。"
        case .suspended: return "当前许可证已被暂停使用，无法继续运行 CopyAttach。请联系管理员恢复。"
        case .needsUpdate: return "当前版本过旧，服务端已不再支持。请升级到最新版 CopyAttach 后重新验证许可证。"
        case .needsOnlineVerification: return "本地授权凭证已到期。请连接 License Server 完成验证后继续使用。"
        case .invalidLease(let message), .error(let message): return message
        case .trialActive(let endsAt, _):
            return "30 天全功能体验已生效，试用截止 \(activatedDate(endsAt))。关闭此窗口即可继续使用。"
        case .licensed(_, let limit):
            return "永久权益已绑定本机，最多可同时激活 \(limit) 台设备。关闭此窗口即可继续使用。"
        case .subscriptionActive(let expiresAt, _, let limit):
            return "限时许可证已生效，有效期至 \(activatedDate(expiresAt))，最多 \(limit) 台设备。关闭此窗口即可继续使用。"
        default: return "开始试用或输入有效许可证密钥后才能运行剪贴板功能。"
        }
    }
    private var activatedIcon: String {
        switch manager.state {
        case .trialActive: return "clock.badge.checkmark"
        case .subscriptionActive: return "timer"
        default: return "checkmark.seal.fill"
        }
    }
    private func activatedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
