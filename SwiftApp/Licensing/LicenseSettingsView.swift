import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    @ObservedObject private var manager = LicenseManager.shared
    @State private var licenseKey = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader

                if canStartTrial {
                    actionCard(icon: "clock.arrow.circlepath", title: "先免费体验", detail: "从点击开始时计时，试用期间开放全部功能。") {
                        Button("开始 30 天免费试用") { Task { await manager.startTrial() } }
                            .buttonStyle(.borderedProminent).disabled(manager.isWorking)
                    }
                }

                activationCard

                if let error = manager.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundColor(.red)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08)).cornerRadius(8)
                }

                if case .licensed = manager.state {
                    Button("解绑本设备", role: .destructive) { Task { await manager.deactivateCurrentDevice() } }
                        .disabled(manager.isWorking)
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("还没有许可证密钥？").font(.system(size: 12, weight: .semibold)).foregroundColor(theme.primaryText)
                    Text("在购买页面支付后获得一串以 CA- 开头的密钥。复制密钥 → 粘贴到上方输入框 → 点击“验证并激活”。一个密钥最多绑定 3 台 Mac。")
                        .font(.system(size: 11.5)).foregroundColor(theme.secondaryText).lineSpacing(3)
                    Button {
                        NSWorkspace.shared.open(LicenseManager.purchaseURL)
                    } label: {
                        Label("购买激活密钥", systemImage: "cart.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 2)
                }

                Text("未开始试用或未激活时，CopyAttach 不会监控剪贴板。关闭此窗口将退出程序。许可证验证不会上传任何剪贴板内容。")
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText).lineSpacing(2)
            }
            .padding(24)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon).font(.system(size: 28)).foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle).font(.system(size: 17, weight: .semibold)).foregroundColor(theme.primaryText)
                Text(statusDetail).font(.system(size: 12)).foregroundColor(theme.secondaryText)
            }
            Spacer()
            if manager.isWorking { ProgressView().controlSize(.small) }
        }
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("已有许可证密钥", systemImage: "key.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
            Text("在购买页面或发货消息中复制完整密钥，然后粘贴到这里。")
                .font(.system(size: 11.5)).foregroundColor(theme.secondaryText)
            TextField("例如：CA-ABCD-EFGH-IJKL-MNOP-QRST-UVWX", text: $licenseKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { activate() }
            HStack {
                Button("从剪贴板粘贴密钥") {
                    licenseKey = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                Button("验证并激活") { activate() }
                    .buttonStyle(.borderedProminent).disabled(normalizedKey.isEmpty || manager.isWorking)
            }
            Text("密钥仅用于本次激活；激活成功后保存的是绑定本设备的签名凭证。")
                .font(.system(size: 10.5)).foregroundColor(theme.tertiaryText)
        }
        .padding(16).background(theme.cardBackground).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
    }

    private func actionCard<Content: View>(icon: String, title: String, detail: String, @ViewBuilder action: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
            Text(detail).font(.system(size: 11.5)).foregroundColor(theme.secondaryText)
            action()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
    }

    private var normalizedKey: String { licenseKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func activate() { guard !normalizedKey.isEmpty else { return }; Task { await manager.activate(key: normalizedKey) } }
    private var canStartTrial: Bool { if case .notStarted = manager.state { return true }; return false }
    private var statusIcon: String {
        switch manager.state { case .trialActive: return "clock.badge.checkmark"; case .licensed: return "checkmark.seal.fill"; case .subscriptionActive: return "timer"; case .loading: return "hourglass"; default: return "exclamationmark.shield" }
    }
    private var statusColor: Color { switch manager.state { case .trialActive: return .orange; case .licensed: return .green; case .subscriptionActive: return .blue; default: return .secondary } }
    private var statusTitle: String {
        switch manager.state {
        case .loading: return "正在检查许可证"
        case .notStarted: return "开始试用或激活后才能使用"
        case .trialActive: return "免费试用中"
        case .trialExpired: return "免费试用已结束"
        case .licensed: return "永久许可证已激活"
        case .subscriptionActive: return "限时许可证有效"
        case .subscriptionExpired: return "限时许可证已到期"
        case .needsOnlineVerification: return "需要联网验证"
        case .deviceLimitReached: return "已达到 3 台设备上限"
        case .revoked: return "许可证已停用"
        case .suspended: return "许可证已暂停"
        case .invalidLease: return "本地许可证无效"
        case .error: return "许可证操作失败"
        }
    }
    private var statusDetail: String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        switch manager.state {
        case .trialActive(let end, _): return "全部功能可用，试用结束：\(formatter.string(from: end))"
        case .licensed(_, let limit): return "永久权益 · 最多 \(limit) 台设备"
        case .subscriptionActive(let end, _, let limit): return "到期时间：\(formatter.string(from: end)) · 最多 \(limit) 台设备"
        case .subscriptionExpired: return "该限时许可证已到期，请输入新的有效许可证"
        case .invalidLease(let text), .error(let text): return text
        case .deviceLimitReached: return "请先在已激活设备上解绑，再重新激活"
        case .trialExpired: return "历史数据仍保留在本机，输入许可证密钥后继续使用"
        case .suspended: return "许可证已被暂停，无法继续使用 CopyAttach"
        case .needsOnlineVerification: return "启动 License Server 后重新打开 App"
        default: return "当前不会监控或保存剪贴板内容"
        }
    }
}
