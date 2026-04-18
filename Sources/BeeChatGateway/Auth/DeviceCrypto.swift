import Foundation
import CryptoKit

public enum DeviceCrypto {
    private static let keyTag = "com.beechat.device-identity"

    // MARK: - Base64url Encoding/Decoding

    /// Encode data to base64url (no padding, URL-safe alphabet).
    public static func toBase64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode base64url string to data.
    public static func fromBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Add padding
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    // MARK: - Key Management

    /// Get or create the persistent Ed25519 keypair.
    /// Stores private key rawRepresentation (32 bytes) in Keychain; reconstructs on subsequent calls.
    public static func getOrCreateKeyPair() throws -> Curve25519.Signing.PrivateKey {
        // Try to load existing key from Keychain
        if let existingData = readKeyFromKeychain() {
            // Reconstruct private key from stored raw bytes
            return try Curve25519.Signing.PrivateKey(rawRepresentation: existingData)
        }

        // Generate new Ed25519 keypair
        let privateKey = Curve25519.Signing.PrivateKey()

        // Persist raw representation to Keychain
        let rawBytes = privateKey.rawRepresentation
        try storeKeyInKeychain(rawBytes)

        return privateKey
    }

    /// Derive device ID from SHA-256 hash of the public key raw bytes, hex-encoded.
    public static func getDeviceId(_ key: Curve25519.Signing.PrivateKey) -> String {
        let publicKeyData = key.publicKey.rawRepresentation
        let hash = SHA256.hash(data: publicKeyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Export public key as base64url-encoded raw bytes (32 bytes) for transport.
    public static func exportPublicKey(_ key: Curve25519.Signing.PrivateKey) -> String {
        return toBase64URL(key.publicKey.rawRepresentation)
    }

    /// Sign the challenge payload using Ed25519.
    /// Uses v3 signature payload format:
    ///   v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily
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
        // v3 canonical string (11 fields)
        let canonical = "v3|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopes.joined(separator: ","))|\(signedAtMs)|\(token ?? "")|\(nonce)|\(platform)|\(deviceFamily)"

        guard let data = canonical.data(using: .utf8) else {
            throw DeviceCryptoError.encodingFailed
        }

        let signature = try key.signature(for: data)
        return toBase64URL(signature)
    }

    // MARK: - Keychain Helpers

    private static func readKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecAttrAccount as String: "ed25519-private-key",
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
            kSecAttrAccount as String: "ed25519-private-key"
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

// MARK: - Errors

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