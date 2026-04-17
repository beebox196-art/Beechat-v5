import Foundation
import CryptoKit
import Security

public enum DeviceCrypto {
    private static let keyTag = "com.beechat.device-identity".data(using: .utf8)!

    /// Get or create the persistent EC P-256 keypair from Keychain.
    public static func getOrCreateKeyPair() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess, let key = item {
            return key as! SecKey
        }
        
        // Generate new EC P-256 keypair
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag
            ]
        ]
        
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let errDesc = error?.takeUnretainedValue().localizedDescription ?? "Unknown error"
            throw DeviceCryptoError.keyGenerationFailed(errDesc)
        }
        return key
    }

    /// Derive device ID from SHA-256 hash of public key raw bytes, hex-encoded.
    public static func getDeviceId(_ key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw DeviceCryptoError.exportFailed
        }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Export public key as base64-encoded raw bytes for transport.
    public static func exportPublicKey(_ key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw DeviceCryptoError.exportFailed
        }
        return data.base64EncodedString()
    }

    /// Sign the challenge payload using ECDSA P-256 with SHA-256.
    /// The signature is over a canonical pipe-delimited string.
    public static func signChallenge(
        _ key: SecKey,
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String
    ) throws -> String {
        // Canonical string: v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
        let canonical = "v2|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopes.joined(separator: ","))|\(signedAtMs)|\(token ?? "")|\(nonce)"
        guard let data = canonical.data(using: .utf8) else {
            throw DeviceCryptoError.encodingFailed
        }
        
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            let errDesc = error?.takeUnretainedValue().localizedDescription ?? "Unknown signing error"
            throw DeviceCryptoError.signingFailed(errDesc)
        }
        return signature.base64EncodedString()
    }
}

// MARK: - Errors

public enum DeviceCryptoError: LocalizedError {
    case keyGenerationFailed(String)
    case exportFailed
    case encodingFailed
    case signingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let msg): return "Key generation failed: \(msg)"
        case .exportFailed: return "Failed to export public key"
        case .encodingFailed: return "Failed to encode challenge payload"
        case .signingFailed(let msg): return "Challenge signing failed: \(msg)"
        }
    }
}