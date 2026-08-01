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
        guard payload.expiresAt > Int64(now.timeIntervalSince1970) else {
            throw LicenseClientError.local("许可证凭证已过期，需要联网验证")
        }
        guard ["trial", "perpetual", "subscription"].contains(payload.entitlement) else {
            throw LicenseClientError.local("许可证权益类型无效")
        }
        if payload.entitlement == "subscription" {
            guard let licenseExpiresAt = payload.licenseExpiresAt,
                  licenseExpiresAt > Int64(now.timeIntervalSince1970) else {
                throw LicenseClientError.local("限时许可证已到期")
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

    static let baseURL = URL(string: value(for: "CopyAttachLicenseServerURL", fallback: "https://api.abovepast.shop"))!
    static let signingKeyID = value(for: "CopyAttachLicenseSigningKeyID", fallback: "production-2026-08")
    static let signingPublicKey = value(for: "CopyAttachLicenseSigningPublicKey", fallback: "efsKYx9a7urNlr-UXR7b0-Fl9w0mJNKe3RME-OeseOs")
}
