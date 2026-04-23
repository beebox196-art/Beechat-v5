import Foundation
import BeeChatGateway
import BeeChatPersistence

public protocol RPCClientProtocol {
    func sessionsList() async throws -> [SessionInfo]
    func sessionsSubscribe() async throws
    func chatHistory(sessionKey: String, limit: Int?) async throws -> [ChatMessagePayload]
    func chatSend(sessionKey: String, message: String, idempotencyKey: String, thinking: String?, attachments: [ChatAttachment]?) async throws -> String
    func chatAbort(sessionKey: String) async throws -> Bool
}

public struct ChatAttachment: Codable, Sendable {
    public let name: String?
    public let mimeType: String?
    public let data: String?
    public let size: Int?
    
    public init(name: String? = nil, mimeType: String? = nil, data: String? = nil, size: Int? = nil) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
        self.size = size
    }
}

public struct RPCClient: RPCClientProtocol {

    private let gateway: GatewayClient
    
    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }
    
    public func sessionsList() async throws -> [SessionInfo] {
        let response = try await gateway.call(method: "sessions.list", params: [:])
        
        guard let payloadData = try? JSONEncoder().encode(response),
              let sessionsResponse = try? JSONDecoder().decode(SessionsListResponse.self, from: payloadData) else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid sessions.list response"])
        }
        
        return sessionsResponse.sessions
    }
    
    public func sessionsSubscribe() async throws {
        _ = try await gateway.call(method: "sessions.subscribe", params: [:])
    }
    
    public func chatHistory(sessionKey: String, limit: Int? = 200) async throws -> [ChatMessagePayload] {
        var params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        if let limit = limit {
            params["limit"] = AnyCodable(limit)
        }
        
        let response = try await gateway.call(method: "chat.history", params: params)
        
        guard let payloadData = try? JSONEncoder().encode(response),
              let historyResponse = try? JSONDecoder().decode(ChatHistoryResponse.self, from: payloadData) else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat.history response"])
        }
        
        return historyResponse.messages.map { msg in
            ChatMessagePayload(
                id: msg.id,
                sessionKey: sessionKey,
                role: msg.role,
                content: msg.content,
                timestamp: Date(timeIntervalSince1970: msg.timestamp),
                runId: msg.runId
            )
        }
    }
    
    public func chatSend(sessionKey: String, message: String, idempotencyKey: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String {
        var params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
            "idempotencyKey": AnyCodable(idempotencyKey)
        ]
        
        if let thinking = thinking {
            params["thinking"] = AnyCodable(thinking)
        }
        
        if let attachments = attachments {
            params["attachments"] = AnyCodable(attachments)
        }
        
        let response = try await gateway.call(method: "chat.send", params: params)
        
        guard let payloadData = try? JSONEncoder().encode(response),
              let sendResponse = try? JSONDecoder().decode(ChatSendResponse.self, from: payloadData) else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "chat.send did not return runId"])
        }
        return sendResponse.runId
    }
    
    public func chatAbort(sessionKey: String) async throws -> Bool {
        let params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        let response = try await gateway.call(method: "chat.abort", params: params)
        return response["ok"]?.value as? Bool ?? false
    }
}
