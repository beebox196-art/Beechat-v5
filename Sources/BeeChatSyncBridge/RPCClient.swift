import Foundation
import BeeChatGateway
import BeeChatPersistence

public protocol RPCClientProtocol {
    func sessionsList() async throws -> [SessionInfo]
    func sessionsSubscribe() async throws
    func chatHistory(sessionKey: String, limit: Int?) async throws -> [ChatMessagePayload]
    func chatSend(sessionKey: String, message: String, idempotencyKey: String) async throws -> String
    func chatAbort(sessionKey: String) async throws -> Bool
}

public struct RPCClient: RPCClientProtocol {

    private let gateway: GatewayClient
    
    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }
    
    public func sessionsList() async throws -> [SessionInfo] {
        let response = try await gateway.call(method: "sessions.list", params: [:])
        guard let sessionsData = response["sessions"]?.value as? [[String: Any]] else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid sessions.list response"])
        }
        
        return sessionsData.compactMap { dict in
            guard let key = dict["key"] as? String else { return nil }
            return SessionInfo(
                key: key,
                label: dict["label"] as? String,
                channel: dict["channel"] as? String,
                model: dict["model"] as? String,
                totalTokens: dict["totalTokens"] as? Int,
                lastMessageAt: dict["lastMessageAt"] as? String
            )
        }
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
        guard let messagesData = response["messages"]?.value as? [[String: Any]] else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat.history response"])
        }
        
        return messagesData.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let role = dict["role"] as? String,
                  let content = dict["content"] as? String,
                  let ts = dict["timestamp"] as? Double else { return nil }
            
            return ChatMessagePayload(
                id: id,
                sessionKey: sessionKey,
                role: role,
                content: content,
                timestamp: Date(timeIntervalSince1970: ts),
                runId: dict["runId"] as? String
            )
        }
    }
    
    public func chatSend(sessionKey: String, message: String, idempotencyKey: String) async throws -> String {
        let params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(sessionKey),
            "message": AnyCodable(message),
            "idempotencyKey": AnyCodable(idempotencyKey)
        ]
        
        let response = try await gateway.call(method: "chat.send", params: params)
        guard let runId = response["runId"]?.value as? String else {
            throw NSError(domain: "RPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "chat.send did not return runId"])
        }
        return runId
    }
    
    public func chatAbort(sessionKey: String) async throws -> Bool {
        let params: [String: AnyCodable] = ["sessionKey": AnyCodable(sessionKey)]
        let response = try await gateway.call(method: "chat.abort", params: params)
        return response["ok"]?.value as? Bool ?? false
    }
}
