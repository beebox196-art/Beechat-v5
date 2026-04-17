import Foundation

public struct DeviceIdentity: Codable, Sendable {
    public let id: String
    public let publicKey: String
    public let signature: String
    public let signedAt: Int
    public let nonce: String
}
