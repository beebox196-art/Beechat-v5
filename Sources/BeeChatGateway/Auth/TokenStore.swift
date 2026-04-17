import Foundation
import Security

public protocol TokenStore: Sendable {
    func getGatewayToken() throws -> String?
    func setGatewayToken(_ token: String) throws
    func getDeviceToken() throws -> String?
    func setDeviceToken(_ token: String) throws
    func deleteAll() throws
}

public final class KeychainTokenStore: TokenStore {
    private let service = "com.beechat.tokens"
    
    public init() {}
    
    public func getGatewayToken() throws -> String? {
        return try readToken(account: "gatewayToken")
    }
    
    public func setGatewayToken(_ token: String) throws {
        try writeToken(token, account: "gatewayToken")
    }
    
    public func getDeviceToken() throws -> String? {
        return try readToken(account: "deviceToken")
    }
    
    public func setDeviceToken(_ token: String) throws {
        try writeToken(token, account: "deviceToken")
    }
    
    public func deleteAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
    
    private func readToken(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: "KeychainTokenStore", code: Int(status), userInfo: nil)
        }
        return String(data: data, encoding: .utf8)
    }
    
    private func writeToken(_ token: String, account: String) throws {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let attributes: [String: Any] = [kSecValueData as String: data]
        
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw NSError(domain: "KeychainTokenStore", code: Int(addStatus), userInfo: nil)
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "KeychainTokenStore", code: Int(status), userInfo: nil)
        }
    }
}
