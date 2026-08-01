import Foundation

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()
    /// 激活密钥购买页面。
    static let purchaseURL = URL(string: "https://pay.ldxp.cn/shop/F5T5GUPN")!

    @Published private(set) var state: EntitlementState = .loading
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    /// Non-nil while the in-window activation celebration is playing.
    @Published private(set) var celebration: CelebrationInfo?

    private let leaseAccount = "signed-license-lease-v1"
    private let identity = DeviceIdentity()
    private let api = LicenseAPIClient()
    private var verifier: LicenseLeaseVerifier?
    private var currentPayload: LeasePayload?
    private var nextRefreshAt: Date?
    /// 下一次在线状态检查时间。管理后台的暂停/撤销/试用到期
    /// 写入数据库后，设备在下一个检查点即可立即感知，
    /// 而不用等 Lease 中点/到期（最多可差一个完整验证周期）。
    private var nextStatusCheckAt: Date?
    private let statusCheckInterval: TimeInterval = 120
    private var maintenanceInProgress = false
    /// Bumped whenever an authoritative lease is (re)applied or a device is
    /// deactivated. A background refresh that started against an older epoch
    /// discards its result, so a stale refresh cannot clobber a concurrent
    /// activation or deactivation.
    private var stateEpoch = 0

    private init() {}

    func initialize() async {
        state = .loading
        do {
            try LicenseSelfTests.runIfRequested()
            try identity.loadOrCreate()
            verifier = try LicenseLeaseVerifier()
            guard let leaseData = try KeychainStore.load(account: leaseAccount) else {
                currentPayload = nil
                nextRefreshAt = nil
                state = .notStarted
                return
            }
            let lease = try JSONDecoder().decode(SignedLease.self, from: leaseData)
            do {
                let payload = try verify(lease)
                apply(payload)
                // The maintenance timer refreshes at the Lease midpoint. Do
                // not refresh on every launch: that creates needless server
                // traffic and hides whether scheduled renewal works.
            } catch {
                if let payloadData = Data(base64URL: lease.payload),
                   let payload = try? JSONDecoder().decode(LeasePayload.self, from: payloadData),
                   (payload.entitlement == "perpetual" || payload.entitlement == "subscription"),
                   let activationID = payload.activationId {
                    try await refreshOrThrow(activationID: activationID)
                } else if let payloadData = Data(base64URL: lease.payload),
                          let payload = try? JSONDecoder().decode(LeasePayload.self, from: payloadData),
                          payload.entitlement == "trial", let ends = payload.trialEndsAt {
                    if ends <= Int64(Date().timeIntervalSince1970) {
                        state = .trialExpired
                    } else {
                        // /trials/start is idempotent for the same device and
                        // returns a fresh short lease without restarting trial time.
                        let renewed = try await api.startTrial(device: identity)
                        let renewedPayload = try verify(renewed)
                        try KeychainStore.save(JSONEncoder().encode(renewed), account: leaseAccount)
                        apply(renewedPayload)
                    }
                } else {
                    state = .needsOnlineVerification
                }
            }
        } catch {
            state = .invalidLease(error.localizedDescription)
        }
    }

    /// Refreshes a short offline Lease before it expires. A transient refresh
    /// failure never interrupts an otherwise-valid Lease; only the real
    /// entitlement end or an expired Lease that cannot be renewed closes the
    /// core. Returns true only when the permission boundary changed.
    @discardableResult
    func maintainEntitlement(now: Date = Date()) async -> Bool {
        guard state.permitsCoreFeatures, let payload = currentPayload else { return false }
        let nowSeconds = Int64(now.timeIntervalSince1970)

        if payload.entitlement == "trial", let end = payload.trialEndsAt, end <= nowSeconds {
            state = .trialExpired
            return true
        }
        if payload.entitlement == "subscription", let end = payload.licenseExpiresAt, end <= nowSeconds {
            state = .subscriptionExpired
            return true
        }

        let leaseExpired = payload.expiresAt <= nowSeconds

        // 周期性在线状态检查：让后台的暂停/撤销/试用到期立即生效。
        // 离线或服务器不可达时静默跳过（离线 Lease 仍然权威，不惩罚用户）；
        // 只有服务器明确返回非活跃状态才切换权限边界。
        if !maintenanceInProgress, let checkAt = nextStatusCheckAt, checkAt <= now {
            if await checkOnlineStatus(payload) {
                return true
            }
            nextStatusCheckAt = Date().addingTimeInterval(statusCheckInterval)
        }

        guard leaseExpired || nextRefreshAt.map({ $0 <= now }) == true else { return false }
        guard !maintenanceInProgress else { return false }
        maintenanceInProgress = true
        defer { maintenanceInProgress = false }

        let epochAtStart = stateEpoch
        do {
            let renewed: SignedLease
            if payload.entitlement == "trial" {
                renewed = try await api.startTrial(device: identity)
            } else {
                guard let activationID = payload.activationId else {
                    throw LicenseClientError.local("许可证凭证缺少设备激活标识")
                }
                renewed = try await api.refresh(activationID: activationID, device: identity)
            }
            // A newer activation/deactivation may have replaced this lease while
            // the request was in flight. Discard the stale result instead of
            // overwriting the fresh entitlement.
            guard stateEpoch == epochAtStart else {
                debugLog("License refresh discarded: entitlement changed while request was in flight")
                return false
            }
            let renewedPayload = try verify(renewed)
            try KeychainStore.save(JSONEncoder().encode(renewed), account: leaseAccount)
            lastError = nil
            apply(renewedPayload)
            debugLog("License Lease refreshed in background; next refresh: \(nextRefreshAt?.description ?? "unknown")")
            return false
        } catch {
            guard stateEpoch == epochAtStart else { return false }
            lastError = "后台许可证验证失败：\(error.localizedDescription)"
            debugLog("License background refresh failed: \(error.localizedDescription)")
            // The signed Lease remains authoritative until its exact expiry.
            // Do not punish the user for a temporary network/server outage.
            if payload.expiresAt > Int64(Date().timeIntervalSince1970) {
                nextRefreshAt = Date().addingTimeInterval(10)
                return false
            }
            let mapped = mappedError(error)
            switch mapped {
            case .revoked, .subscriptionExpired, .deviceLimitReached:
                state = mapped
            default:
                state = .needsOnlineVerification
            }
            return true
        }
    }

    func startTrial() async {
        lastError = nil
        await perform { try await self.api.startTrial(device: self.identity) }
    }

    func activate(key: String) async {
        lastError = nil
        await perform { try await self.api.activate(key: key, device: self.identity) }
    }

    func refresh() async {
        guard let data = try? KeychainStore.load(account: leaseAccount),
              let lease = try? JSONDecoder().decode(SignedLease.self, from: data),
              let payloadData = Data(base64URL: lease.payload),
              let payload = try? JSONDecoder().decode(LeasePayload.self, from: payloadData),
              let activationID = payload.activationId else { return }
        do {
            try await refreshOrThrow(activationID: activationID)
        } catch {
            lastError = error.localizedDescription
            state = mappedError(error)
            AppDelegate.shared?.entitlementDidChange()
        }
    }

    func deactivateCurrentDevice() async {
        isWorking = true
        defer { isWorking = false }
        do {
            guard let data = try KeychainStore.load(account: leaseAccount),
                  let lease = try? JSONDecoder().decode(SignedLease.self, from: data),
                  let payloadData = Data(base64URL: lease.payload),
                  let payload = try? JSONDecoder().decode(LeasePayload.self, from: payloadData),
                  let activationID = payload.activationId else { throw LicenseClientError.local("当前没有正式许可证") }
            try await api.deactivate(activationID: activationID, device: identity)
            try KeychainStore.delete(account: leaseAccount)
            currentPayload = nil
            nextRefreshAt = nil
            state = .notStarted
            stateEpoch += 1
            AppDelegate.shared?.entitlementDidChange()
        } catch {
            lastError = error.localizedDescription
            applyFailureState(error)
        }
    }

    private func perform(_ operation: () async throws -> SignedLease) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let lease = try await operation()
            let payload = try verify(lease)
            try KeychainStore.save(JSONEncoder().encode(lease), account: leaseAccount)
            let wasUnlicensed = !state.permitsCoreFeatures
            apply(payload)
            if wasUnlicensed && state.permitsCoreFeatures {
                // Play the celebration inside the still-open gate window; the
                // real entitlement transition (closing the gate + starting the
                // backend) happens when finishCelebration() is called after the
                // animation completes.
                celebration = CelebrationInfo(
                    kind: celebrationKind(for: payload),
                    message: celebrationTitle(for: payload),
                    subtitle: celebrationSubtitle(for: payload)
                )
                AppDelegate.shared?.licenseCelebrationDidStart()
            } else {
                AppDelegate.shared?.entitlementDidChange()
            }
        } catch {
            lastError = error.localizedDescription
            applyFailureState(error)
        }
    }

    /// Applies the mapped error state only when the current entitlement is not
    /// already valid. A failed re-activation, trial start, or deactivation must
    /// not revoke a still-valid signed lease: downgrading `state` here without
    /// stopping the Rust backend would desync the UI (unlicensed menu) from the
    /// still-running monitor thread.
    private func applyFailureState(_ error: Error) {
        if state.permitsCoreFeatures {
            debugLog("License operation failed while entitled; current state kept: \(error.localizedDescription)")
        } else {
            state = mappedError(error)
        }
    }

    /// Called by the gate view when the celebration animation has finished
    /// playing. The gate stays open on the (now activated) license page so the
    /// user can confirm activation succeeded; the backend starts in the
    /// background so the app is already functional.
    func finishCelebration() {
        celebration = nil
        AppDelegate.shared?.licenseCelebrationFinished()
    }

    private func celebrationKind(for payload: LeasePayload) -> CelebrationKind {
        payload.entitlement == "trial" ? .trial : .keyActivation
    }

    private func celebrationTitle(for payload: LeasePayload) -> String {
        switch payload.entitlement {
        case "trial": return "免费试用已开启"
        case "subscription": return "激活成功！"
        default: return "激活成功！"
        }
    }

    private func celebrationSubtitle(for payload: LeasePayload) -> String {
        switch payload.entitlement {
        case "trial": return "30 天全功能体验，欢迎使用 CopyAttach"
        case "subscription": return "限时许可证已生效，欢迎使用 CopyAttach"
        default: return "永久许可证已生效，欢迎使用 CopyAttach"
        }
    }

    private func refreshOrThrow(activationID: String) async throws {
        let lease = try await api.refresh(activationID: activationID, device: identity)
        let payload = try verify(lease)
        try KeychainStore.save(JSONEncoder().encode(lease), account: leaseAccount)
        apply(payload)
        AppDelegate.shared?.entitlementDidChange()
    }

    private func verify(_ lease: SignedLease) throws -> LeasePayload {
        guard let verifier else { throw LicenseClientError.local("许可证验证器尚未初始化") }
        return try verifier.verify(lease, expectedDeviceID: identity.deviceID)
    }

    private func apply(_ payload: LeasePayload) {
        currentPayload = payload
        stateEpoch += 1
        nextRefreshAt = LicenseRefreshSchedule.refreshDate(for: payload)
        // 应用新 Lease 后尽快做一次在线状态检查（如刚启动/刚激活），
        // 避免后台已被暂停/撤销的凭证继续使用一个检查周期。
        nextStatusCheckAt = Date()
        if payload.entitlement == "trial" {
            guard let ends = payload.trialEndsAt else { state = .invalidLease("试用凭证缺少到期时间"); return }
            state = .trialActive(endsAt: Date(timeIntervalSince1970: TimeInterval(ends)), leaseExpiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt)))
        } else if payload.entitlement == "subscription" {
            guard let licExp = payload.licenseExpiresAt else { state = .invalidLease("订阅许可证缺少到期时间"); return }
            state = .subscriptionActive(expiresAt: Date(timeIntervalSince1970: TimeInterval(licExp)), leaseExpiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt)), seatLimit: payload.seatLimit ?? 3)
        } else {
            state = .licensed(leaseExpiresAt: Date(timeIntervalSince1970: TimeInterval(payload.expiresAt)), seatLimit: payload.seatLimit ?? 3)
        }
    }

    /// 向服务器查询当前在线状态。仅当服务器明确返回非活跃状态时返回 true
    /// （调用方随即切换权限边界）；not_found 属于歧义情况（记录被删除/数据库
    /// 重建），保守起见不据此降级，避免误伤仍持有有效 Lease 的用户。
    private func checkOnlineStatus(_ payload: LeasePayload) async -> Bool {
        do {
            if payload.entitlement == "trial", let trialID = payload.trialId {
                let status = try await api.trialStatus(trialID: trialID, device: identity)
                switch status.status {
                case "expired":
                    state = .trialExpired
                    return true
                default:
                    break
                }
            } else if let activationID = payload.activationId {
                let status = try await api.licenseStatus(activationID: activationID, device: identity)
                switch status.status {
                case "suspended":
                    state = .suspended
                    return true
                case "revoked":
                    state = .revoked
                    return true
                case "expired":
                    state = .subscriptionExpired
                    return true
                default:
                    break
                }
            }
        } catch {
            debugLog("License online status check failed: \(error.localizedDescription)")
        }
        return false
    }

    private func mappedError(_ error: Error) -> EntitlementState {
        if case LicenseClientError.server(let code, _) = error {
            if code == "DEVICE_LIMIT_REACHED" { return .deviceLimitReached }
            if code == "DEVICE_ALREADY_BOUND" { return .error("这台 Mac 已使用另一个设备身份绑定过该密钥。请先在管理后台解绑该设备，再重新激活。") }
            if code == "TRIAL_EXPIRED" { return .trialExpired }
            if code == "LICENSE_EXPIRED" { return .subscriptionExpired }
            if code == "TRIAL_ALREADY_USED" { return .error("这台 Mac 已经领取过免费试用，删除钥匙串或重装应用不会重置试用。请输入许可证密钥继续。") }
            if code == "LICENSE_NOT_ACTIVE" { return .revoked }
            if code == "APP_VERSION_TOO_OLD" { return .needsUpdate }
        }
        return .error(error.localizedDescription)
    }
}
