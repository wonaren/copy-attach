import CryptoKit
import Foundation

/// Deterministic protocol checks, executed only when COPYATTACH_LICENSE_SELF_TEST=1.
/// They cover the exact client-side regressions that previously made a valid
/// subscription lease appear activated on the server but fail in the App.
enum LicenseSelfTests {
    static func runIfRequested() throws {
        guard ProcessInfo.processInfo.environment["COPYATTACH_LICENSE_SELF_TEST"] == "1" else { return }
        try subscriptionLeaseIsAccepted()
        try expiredSubscriptionIsRejected()
        try expiredPerpetualLeaseIsAccepted()
        try refreshScheduleIsBeforeExpiry()
        debugLog("[LicenseSelfTests] PASS: subscription/perpetual verification, expiry, and refresh schedule")
    }

    private static func subscriptionLeaseIsAccepted() throws {
        let fixture = try fixture(licenseExpiresAt: 1_900_000_060, leaseExpiresAt: 1_900_000_060)
        let verifier = try LicenseLeaseVerifier(keyID: fixture.keyID, publicKeyData: fixture.publicKey)
        let payload = try verifier.verify(fixture.lease, expectedDeviceID: fixture.deviceID, now: Date(timeIntervalSince1970: 1_900_000_000))
        guard payload.entitlement == "subscription", payload.licenseExpiresAt == 1_900_000_060 else {
            throw LicenseClientError.local("subscription self-test payload mismatch")
        }
    }

    private static func expiredPerpetualLeaseIsAccepted() throws {
        // 永久许可证无到期时间：即使 Lease 的 expires_at 已过（服务端续租节奏），
        // 签名 + 设备绑定有效即离线可用，不应触发联网验证。
        let fixture = try fixture(entitlement: "perpetual", licenseExpiresAt: nil, leaseExpiresAt: 1_899_999_999)
        let verifier = try LicenseLeaseVerifier(keyID: fixture.keyID, publicKeyData: fixture.publicKey)
        let payload = try verifier.verify(fixture.lease, expectedDeviceID: fixture.deviceID, now: Date(timeIntervalSince1970: 1_900_000_000))
        guard payload.entitlement == "perpetual" else {
            throw LicenseClientError.local("perpetual self-test payload mismatch")
        }
    }

    private static func refreshScheduleIsBeforeExpiry() throws {
        let payload = LeasePayload(schemaVersion: 1, leaseId: "schedule", productId: "copyattach", entitlement: "perpetual", licenseId: "license", trialId: nil, activationId: "activation", deviceId: "device", seatLimit: 3, trialEndsAt: nil, licenseExpiresAt: nil, issuedAt: 1_900_000_000, expiresAt: 1_900_000_120)
        let scheduled = Int64(LicenseRefreshSchedule.refreshDate(for: payload).timeIntervalSince1970)
        guard scheduled == 1_900_000_060 else { throw LicenseClientError.local("120-second Lease was not scheduled to refresh at 60 seconds") }
    }

    private static func expiredSubscriptionIsRejected() throws {
        let fixture = try fixture(licenseExpiresAt: 1_899_999_999, leaseExpiresAt: 1_900_000_060)
        let verifier = try LicenseLeaseVerifier(keyID: fixture.keyID, publicKeyData: fixture.publicKey)
        do {
            _ = try verifier.verify(fixture.lease, expectedDeviceID: fixture.deviceID, now: Date(timeIntervalSince1970: 1_900_000_000))
            throw LicenseClientError.local("expired subscription self-test was accepted")
        } catch LicenseClientError.local(let message) where message == "限时许可证已到期" {
            return
        }
    }

    private struct Fixture { let keyID: String; let publicKey: Data; let deviceID: String; let lease: SignedLease }

    private static func fixture(entitlement: String = "subscription", licenseExpiresAt: Int64?, leaseExpiresAt: Int64) throws -> Fixture {
        let key = Curve25519.Signing.PrivateKey()
        let deviceID = "sha256:self-test-device"
        let payload = LeasePayload(schemaVersion: 1, leaseId: "self-test", productId: "copyattach", entitlement: entitlement, licenseId: "license", trialId: nil, activationId: "activation", deviceId: deviceID, seatLimit: 3, trialEndsAt: nil, licenseExpiresAt: licenseExpiresAt, issuedAt: 1_900_000_000, expiresAt: leaseExpiresAt)
        let data = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: data)
        return Fixture(keyID: "self-test-key", publicKey: key.publicKey.rawRepresentation, deviceID: deviceID, lease: SignedLease(keyId: "self-test-key", payload: data.base64URLEncodedString(), signature: signature.base64URLEncodedString()))
    }
}
