import CryptoKit
import Foundation
import IOKit
import Security

final class DeviceIdentity {
    private let keyAccount = "device-secure-enclave-p256-v1"
    // This is a namespace, not a secret. Trial abuse prevention is enforced by
    // the server's persistent record keyed by this hashed platform UUID.
    private let anchorNamespace = "com.copyattach.license.hardware-anchor.v1:"
    private var key: SecureEnclave.P256.Signing.PrivateKey?

    func loadOrCreate() throws {
        guard SecureEnclave.isAvailable else {
            throw LicenseClientError.local("当前 Mac 不支持 Secure Enclave，无法创建设备许可证身份")
        }
        if let stored = try KeychainStore.load(account: keyAccount) {
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored)
            return
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            throw LicenseClientError.local("无法创建设备密钥访问策略：\(accessError?.takeRetainedValue().localizedDescription ?? "未知错误")")
        }
        let created = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        try KeychainStore.save(created.dataRepresentation, account: keyAccount)
        key = created
    }

    var publicKeyData: Data {
        get throws {
            guard let key else { throw LicenseClientError.local("设备身份尚未初始化") }
            return key.publicKey.x963Representation
        }
    }

    var deviceID: String {
        get throws { "sha256:" + Data(SHA256.hash(data: try publicKeyData)).base64URLEncodedString() }
    }

    func sign(_ challenge: Data) throws -> Data {
        guard let key else { throw LicenseClientError.local("设备身份尚未初始化") }
        return try key.signature(for: challenge).derRepresentation
    }

    func hardwareAnchor() throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw LicenseClientError.local("无法读取设备平台标识") }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            throw LicenseClientError.local("设备平台标识不存在")
        }
        let digest = SHA256.hash(data: Data((anchorNamespace + value.lowercased()).utf8))
        return "sha256:" + Data(digest).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
