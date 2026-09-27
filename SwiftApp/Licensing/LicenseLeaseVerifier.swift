import CryptoKit
import Foundation

struct LicenseLeaseVerifier {
    let trustedKeyId: String
    let publicKey: Curve25519.Signing.PublicKey

    init() throws {
        guard let keyData = Data(base64URL: LicenseConfiguration.signingPublicKey) else {
            throw LicenseClientError.local("许可证签名公钥未配置或格式错误")
        }
        try self.init(keyID: LicenseConfiguration.signingKeyID, publicKeyData: keyData)
    }

    init(keyID: String, publicKeyData: Data) throws {
        guard publicKeyData.count == 32 else { throw LicenseClientError.local("许可证签名公钥格式错误") }
        trustedKeyId = keyID
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    }

    func verify(_ lease: SignedLease, expectedDeviceID: String, now: Date = Date()) throws -> LeasePayload {
        guard lease.keyId == trustedKeyId,
              let payloadData = Data(base64URL: lease.payload),
              let signatureData = Data(base64URL: lease.signature),
              publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw LicenseClientError.local("许可证凭证签名无效")
        }
        let payload = try JSONDecoder().decode(LeasePayload.self, from: payloadData)
        guard payload.schemaVersion == 1, payload.productId == "copyattach", payload.deviceId == expectedDeviceID else {
            throw LicenseClientError.local("许可证凭证与当前产品或设备不匹配")
        }
        guard ["trial", "perpetual", "subscription"].contains(payload.entitlement) else {
            throw LicenseClientError.local("许可证权益类型无效")
        }
        // 永久许可证没有到期时间（license_expires_at 为空），服务端签发的
        // expiresAt 只是续租节奏（LICENSE_LEASE_SECONDS），不代表权益边界：
        // Ed25519 签名 + 设备绑定即权威，Lease 过期后依然离线可用，无需联网。
        // 试用/订阅的 Lease 与权益到期照常强制校验。
        if payload.entitlement != "perpetual" {
            guard payload.expiresAt > Int64(now.timeIntervalSince1970) else {
                throw LicenseClientError.local("许可证凭证已过期，需要联网验证")
            }
            if payload.entitlement == "subscription" {
                guard let licenseExpiresAt = payload.licenseExpiresAt,
                      licenseExpiresAt > Int64(now.timeIntervalSince1970) else {
                    throw LicenseClientError.local("限时许可证已到期")
                }
            }
        }
        return payload
    }
}

enum LicenseConfiguration {
    private static func value(for key: String, fallback: String) -> String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String, !raw.isEmpty {
            return raw
        }
        return fallback
    }

    static let baseURL: URL = {
        let configured = value(for: "CopyAttachLicenseServerURL", fallback: "https://api.abovepast.shop")
        guard let url = URL(string: configured), let scheme = url.scheme, !scheme.isEmpty else {
            preconditionFailure("Invalid license server URL")
        }
        return url
    }()
    static let signingKeyID = value(for: "CopyAttachLicenseSigningKeyID", fallback: "production-2026-08")
    static let signingPublicKey = value(for: "CopyAttachLicenseSigningPublicKey", fallback: "efsKYx9a7urNlr-UXR7b0-Fl9w0mJNKe3RME-OeseOs")
}
