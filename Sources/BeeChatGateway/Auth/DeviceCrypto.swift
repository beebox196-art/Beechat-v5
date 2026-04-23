import Foundation
import CryptoKit

public enum DeviceCrypto {
    private static let keyTag = "com.beechat.device-identity"

    public static func toBase64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    /// Persistent Ed25519 keypair stored in Keychain.
    public static func getOrCreateKeyPair() throws -> Curve25519.Signing.PrivateKey {
        if let existingData = readKeyFromKeychain() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: existingData)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let rawBytes = privateKey.rawRepresentation
        try storeKeyInKeychain(rawBytes)

        return privateKey
    }

    public static func getDeviceId(_ key: Curve25519.Signing.PrivateKey) -> String {
        let publicKeyData = key.publicKey.rawRepresentation
        let hash = SHA256.hash(data: publicKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func exportPublicKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        return toBase64URL(key.publicKey.rawRepresentation)
    }

    /// v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily
    public static func signChallenge(
        _ key: Curve25519.Signing.PrivateKey,
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String,
        platform: String = "macos",
        deviceFamily: String = "desktop"
    ) throws -> String {
        let canonical = "v3|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopes.joined(separator: ","))|\(signedAtMs)|\(token ?? "")|\(nonce)|\(platform)|\(deviceFamily)"

        guard let data = canonical.data(using: .utf8) else {
            throw DeviceCryptoError.encodingFailed
        }

        let signature = try key.signature(for: data)
        return toBase64URL(signature)
    }

    private static func readKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccount as String: "ed25519-private-key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    private static func storeKeyInKeychain(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccount as String: "ed25519-private-key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw DeviceCryptoError.keyStorageFailed(Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw DeviceCryptoError.keyStorageFailed(Int(status))
        }
    }
}

public enum DeviceCryptoError: LocalizedError {
    case keyGenerationFailed(String)
    case keyStorageFailed(Int)
    case exportFailed
    case encodingFailed
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .keyStorageFailed(let code): return "Key storage failed (OSStatus: \(code))"
        case .exportFailed: return "Failed to export public key"
        case .encodingFailed: return "Failed to encode challenge payload"
        case .signingFailed(let msg): return "Challenge signing failed: \(msg)"
        }
    }
}