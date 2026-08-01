import Foundation

/// Which celebration animation to play after activation.
enum CelebrationKind: Equatable {
    case trial            // 免费试用
    case keyActivation    // 密钥激活
}

/// Payload for the in-window activation celebration (kind + copy).
struct CelebrationInfo: Equatable {
    let kind: CelebrationKind
    let message: String
    let subtitle: String
}

enum EntitlementState: Equatable {
    case loading
    case notStarted
    case trialActive(endsAt: Date, leaseExpiresAt: Date)
    case trialExpired
    case licensed(leaseExpiresAt: Date, seatLimit: Int)
    case subscriptionActive(expiresAt: Date, leaseExpiresAt: Date, seatLimit: Int)
    case subscriptionExpired
    case needsOnlineVerification
    case deviceLimitReached
    case revoked
    case suspended
    case needsUpdate
    case invalidLease(String)
    case error(String)

    var permitsCoreFeatures: Bool {
        switch self {
        case .trialActive, .licensed, .subscriptionActive: return true
        default: return false
        }
    }
}

struct SignedLease: Codable {
    let keyId: String
    let payload: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case keyId = "key_id"
        case payload, signature
    }
}

struct LeasePayload: Codable, Equatable {
    let schemaVersion: Int
    let leaseId: String
    let productId: String
    let entitlement: String
    let licenseId: String?
    let trialId: String?
    let activationId: String?
    let deviceId: String
    let seatLimit: Int?
    let trialEndsAt: Int64?
    let licenseExpiresAt: Int64?
    let issuedAt: Int64
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case leaseId = "lease_id"
        case productId = "product_id"
        case entitlement
        case licenseId = "license_id"
        case trialId = "trial_id"
        case activationId = "activation_id"
        case deviceId = "device_id"
        case seatLimit = "seat_limit"
        case trialEndsAt = "trial_ends_at"
        case licenseExpiresAt = "license_expires_at"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }
}

struct LicenseServerErrorEnvelope: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

enum LicenseClientError: LocalizedError {
    case server(code: String, message: String)
    case invalidResponse
    case local(String)

    var errorDescription: String? {
        switch self {
        case .server(_, let message): return message
        case .invalidResponse: return "许可证服务器返回了无效响应"
        case .local(let message): return message
        }
    }
}
