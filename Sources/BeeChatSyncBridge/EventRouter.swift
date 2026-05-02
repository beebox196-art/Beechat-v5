import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct EventRouter {
    private let syncBridge: SyncBridge

    public init(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }


    public func route(event: String, payload: [String: AnyCodable]?) async throws {
        switch event {
        case "chat":
            try await handleChatEvent(payload: payload)
        case "agent":
            try await handleAgentEvent(payload: payload)
        case "session.message":
            try await handleSessionMessage(payload: payload)
        case "health":
            await handleHealthEvent(payload: payload)
        case "sessions.changed":
            try await handleSessionsChanged()
        case "tick":
            await handleTick()
        default:
            print("Unknown event received: \(event)")
        }
    }

    private func handleChatEvent(payload: [String: AnyCodable]?) async throws {
        guard let payload = payload else { return }
        
        // Decode the payload into a typed struct via AnyCodable round-trip
        guard let payloadData = try? JSONEncoder().encode(payload),
              let chatEvent = try? JSONDecoder().decode(ChatEventPayload.self, from: payloadData) else {
            return
        }
        
        let sessionKey = chatEvent.sessionKey
        let state = chatEvent.state
        let errorMessage = chatEvent.errorMessage

        let messageText = chatEvent.message?.content.isEmpty == false ? chatEvent.message?.content : nil

        switch state {
        case "delta":
            if let text = messageText {
                await syncBridge.processChatDelta(sessionKey: sessionKey, text: text)
            }
        case "final":
            if let text = messageText, let msg = chatEvent.message {
                let messageId = msg.id ?? UUID().uuidString
                let timestamp = msg.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
                let message = Message(
                    id: messageId,
                    sessionId: sessionKey,
                    role: "assistant",
                    content: text,
                    agentId: msg.agentId ?? chatEvent.agentId ?? SyncBridge.agentId(fromSessionKey: sessionKey),
                    timestamp: Date(timeIntervalSince1970: Double(timestamp / 1000))
                )
                // Dedup guard — skip if already persisted (fail-open on DB error)
                let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
                if !exists {
                    try await syncBridge.saveGatewayMessage(message)
                }
            }
            try await syncBridge.processChatFinal(sessionKey: sessionKey)
        case "error":
            try await syncBridge.processChatError(sessionKey: sessionKey, errorMessage: errorMessage ?? "Unknown error")
        default:
            break
        }
    }

    private func handleSessionMessage(payload: [String: AnyCodable]?) async throws {
        guard let payload = payload else { return }
        
        // Decode the payload into a typed struct via AnyCodable round-trip
        guard let payloadData = try? JSONEncoder().encode(payload),
              let sessionMsg = try? JSONDecoder().decode(SessionMessagePayload.self, from: payloadData) else {
            return
        }
        
        let sessionKey = sessionMsg.sessionKey

        let ts = sessionMsg.ts ?? 0
        let messageId = sessionMsg.data.id ?? UUID().uuidString

        // Dedup guard — skip persisting if already saved, but still let assistant
        // session.message end the stream. Gateway 4.29 no longer sends chat final.
        let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
        if !exists {
            let message = Message(
                id: messageId,
                sessionId: sessionKey,
                role: sessionMsg.data.role,
                content: sessionMsg.data.content,
                agentId: sessionMsg.data.agentId ?? sessionMsg.agentId ?? SyncBridge.agentId(fromSessionKey: sessionKey),
                timestamp: Date(timeIntervalSince1970: Double(ts / 1000))
            )
            try await syncBridge.saveGatewayMessage(message)
        }

        if sessionMsg.data.role == "assistant" {
            try await syncBridge.processChatFinal(sessionKey: sessionKey)
        }
    }

    private func handleAgentEvent(payload: [String: AnyCodable]?) async throws {
        guard let payload = payload else { return }
        
        // Decode the payload into a typed struct via AnyCodable round-trip
        guard let payloadData = try? JSONEncoder().encode(payload),
              let agentEvent = try? JSONDecoder().decode(AgentEventPayload.self, from: payloadData) else {
            return
        }
        
        try await syncBridge.processAgentEvent(agentEvent)
    }

    private func handleHealthEvent(payload: [String: AnyCodable]?) async {
        // Health events are primarily for monitoring and not persisted
    }

    private func handleSessionsChanged() async throws {
        _ = try await syncBridge.fetchSessions()
    }

    private func handleTick() async {
        await syncBridge.updateLiveness()
    }
}