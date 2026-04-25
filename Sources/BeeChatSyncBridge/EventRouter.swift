import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct EventRouter {
    private let syncBridge: SyncBridge

    public init(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }

    private func isBeeChatSession(_ sessionKey: String) async throws -> Bool {
        return try await syncBridge.isBeeChatSession(sessionKey)
    }

    public func route(event: String, payload: [String: AnyCodable]?) async throws {
        print("[EventRouter] Received event: \(event)")
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

        guard try await isBeeChatSession(sessionKey) else { return }

        let messageText = chatEvent.message?.content.isEmpty == false ? chatEvent.message?.content : nil

        switch state {
        case "delta":
            if let text = messageText {
                await syncBridge.processChatDelta(sessionKey: sessionKey, text: text)
            }
        case "final":
            print("[EventRouter] chat final event for sessionKey=\(sessionKey)")
            if let text = messageText, let msg = chatEvent.message {
                let messageId = msg.id ?? UUID().uuidString
                let timestamp = msg.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
                let message = Message(
                    id: messageId,
                    sessionId: sessionKey,
                    role: "assistant",
                    content: text,
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
            print("[EventRouter] chat error event for sessionKey=\(sessionKey)")
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
        
        guard try await isBeeChatSession(sessionKey) else { return }

        let ts = sessionMsg.ts ?? 0
        let messageId = sessionMsg.data.id ?? UUID().uuidString

        // Dedup guard — skip if already persisted (fail-open on DB error)
        let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
        if exists {
            return
        }

        let message = Message(
            id: messageId,
            sessionId: sessionKey,
            role: sessionMsg.data.role,
            content: sessionMsg.data.content,
            timestamp: Date(timeIntervalSince1970: Double(ts / 1000))
        )

        print("[EventRouter] session.message role=\(sessionMsg.data.role) sessionKey=\(sessionKey) id=\(messageId)")

        try await syncBridge.saveGatewayMessage(message)

        // If this is an assistant message arriving for a currently-streaming session,
        // it means the gateway delivered the final message via session.message instead of
        // chat event with state="final". We must stop streaming to unblock the UI.
        if message.role == "assistant" {
            print("[EventRouter] session.message is assistant — calling processChatFinal for sessionKey=\(sessionKey)")
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
        
        let sessionKey = agentEvent.sessionKey
        
        guard try await isBeeChatSession(sessionKey) else { return }

        try await syncBridge.processAgentEvent(agentEvent)
    }

    private func handleHealthEvent(payload: [String: AnyCodable]?) async {
        // Health events are primarily for monitoring and not persisted
    }

    private func handleSessionsChanged() async throws {
        try await syncBridge.fetchSessions()
    }

    private func handleTick() async {
        await syncBridge.updateLiveness()
    }
}