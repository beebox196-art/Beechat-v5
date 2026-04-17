import Foundation

public struct DeliveryLedgerEntry: Codable, Sendable {
    public let id: UUID
    public let sessionKey: String
    public let idempotencyKey: String
    public let content: String
    public var status: DeliveryStatus
    public var runId: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var retryCount: Int
    
    public enum DeliveryStatus: String, Codable, Sendable {
        case pending
        case sent
        case delivered
        case failed
    }
}
