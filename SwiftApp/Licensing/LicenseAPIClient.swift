import Foundation

struct LicenseAPIClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // 关闭磁盘 HTTP 响应缓存，保证鉴权接口每次拿到真实服务端数据
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "User-Agent": "CopyAttach/\(Self.appVersion) (Macintosh; Mac OS X)",
            "Accept": "application/json"
        ]
        session = URLSession(configuration: configuration)
    }

    /// 预热网络连接（提前完成 QUIC / TLS 会话建立），使用户触发操作时免于冷启动建连延迟
    func prewarm() {
        Task.detached(priority: .utility) {
            let url = LicenseConfiguration.baseURL.appendingPathComponent("v1/health")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.assumesHTTP3Capable = true
            _ = try? await session.data(for: request)
        }
    }

    func startTrial(device: DeviceIdentity) async throws -> SignedLease {
        try await post("v1/trials/start", body: try deviceBody(device), as: SignedLease.self)
    }

    func activate(key: String, device: DeviceIdentity) async throws -> SignedLease {
        var body = try deviceBody(device)
        body["license_key"] = key
        return try await post("v1/licenses/activate", body: body, as: SignedLease.self)
    }

    private func challenge(activationID: String, deviceID: String) async throws -> Challenge {
        try await post("v1/licenses/challenge", body: ["activation_id": activationID, "device_id": deviceID], as: Challenge.self)
    }

    func refresh(activationID: String, device: DeviceIdentity) async throws -> SignedLease {
        let deviceID = try device.deviceID
        let challenge = try await challenge(activationID: activationID, deviceID: deviceID)
        guard let nonce = Data(base64URL: challenge.nonce) else { throw LicenseClientError.invalidResponse }
        let signature = try device.sign(nonce).base64URLEncodedString()
        let body = ["challenge_id": challenge.challengeId, "activation_id": activationID, "device_id": deviceID, "signature": signature, "app_version": Self.appVersion]
        return try await post("v1/licenses/refresh", body: body, as: SignedLease.self)
    }

    func deactivate(activationID: String, device: DeviceIdentity) async throws {
        let deviceID = try device.deviceID
        let challenge = try await challenge(activationID: activationID, deviceID: deviceID)
        guard let nonce = Data(base64URL: challenge.nonce) else { throw LicenseClientError.invalidResponse }
        let body = ["challenge_id": challenge.challengeId, "activation_id": activationID, "device_id": deviceID, "signature": try device.sign(nonce).base64URLEncodedString(), "app_version": Self.appVersion]
        let _: StatusResponse = try await post("v1/licenses/deactivate", body: body, as: StatusResponse.self)
    }

    /// 轻量在线状态检查（无需签名）：让管理后台的暂停/撤销立即生效。
    func licenseStatus(activationID: String, device: DeviceIdentity) async throws -> LicenseStatus {
        try await post("v1/licenses/status", body: ["activation_id": activationID, "device_id": try device.deviceID], as: LicenseStatus.self)
    }

    /// 试用在线状态检查：管理后台让试用到期后，设备下一次轮询立即感知。
    func trialStatus(trialID: String, device: DeviceIdentity) async throws -> TrialStatus {
        try await post("v1/trials/status", body: ["trial_id": trialID, "device_id": try device.deviceID], as: TrialStatus.self)
    }

    private func deviceBody(_ device: DeviceIdentity) throws -> [String: String] {
        [
            "product_id": "copyattach",
            "device_id": try device.deviceID,
            "device_public_key": try device.publicKeyData.base64URLEncodedString(),
            "hardware_anchor": try device.hardwareAnchor(),
            "device_name": Host.current().localizedName ?? "Mac",
            "app_version": Self.appVersion,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ]
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func post<Response: Decodable>(_ path: String, body: [String: String], as: Response.Type) async throws -> Response {
        var request = URLRequest(url: LicenseConfiguration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        // 开启 HTTP/3 (QUIC / UDP) 支持：消除 TCP 队头阻塞与 SYN 握手丢包重传延迟
        request.assumesHTTP3Capable = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenseClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(LicenseServerErrorEnvelope.self, from: data) {
                throw LicenseClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw LicenseClientError.invalidResponse
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct Challenge: Decodable {
    let challengeId: String
    let nonce: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case challengeId = "challenge_id", nonce, expiresAt = "expires_at" }
}

struct LicenseStatus: Decodable {
    let status: String
    let licenseId: String?
    let licenseExpiresAt: Int64?
    let seatLimit: Int?
    enum CodingKeys: String, CodingKey {
        case status
        case licenseId = "license_id"
        case licenseExpiresAt = "license_expires_at"
        case seatLimit = "seat_limit"
    }
}

struct TrialStatus: Decodable {
    let status: String
    let trialEndsAt: Int64?
    enum CodingKeys: String, CodingKey { case status, trialEndsAt = "trial_ends_at" }
}

private struct StatusResponse: Decodable { let status: String }
