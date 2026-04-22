import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct EventRouter {
    private let syncBridge: SyncBridge
    
    public init(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }
    
    /// Check whether a session key belongs to a BeeChat topic.
    /// Events from non-BeeChat sessions (Telegram, cron, subagents) are silently dropped.
    private func isBeeChatSession(_ sessionKey: String) async -> Bool {
        return await syncBridge.isBeeChatSession(sessionKey)
    }
    
    public func route(event: String, payload: [String: AnyCodable]?) async {
        switch event {
        case "chat":
            await handleChatEvent(payload: payload)
        case "agent":
            await handleAgentEvent(payload: payload)
        case "session.message":
            await handleSessionMessage(payload: payload)
        case "health":
            await handleHealthEvent(payload: payload)
        case "sessions.changed":
            await handleSessionsChanged()
        case "tick":
            await handleTick()
        default:
            print("Unknown event received: \(event)")
        }
    }
    
    private func handleChatEvent(payload: [String: AnyCodable]?) async {
        guard let payload = payload else { return }
        
        let sessionKey = payload["sessionKey"]?.value as? String ?? ""
        let state = payload["state"]?.value as? String ?? ""
        let errorMessage = payload["errorMessage"]?.value as? String
        
        // DROP all events from non-BeeChat sessions
        guard await isBeeChatSession(sessionKey) else { return }
        
        // Extract message text from payload
        let messageDict = payload["message"]?.value as? [String: Any]
        let messageText: String?
        if let msgDict = messageDict {
            if let contentStr = msgDict["content"] as? String {
                messageText = contentStr
            } else if let contentBlocks = msgDict["content"] as? [[String: Any]] {
                // ContentBlock[] format — extract text blocks
                messageText = contentBlocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
            } else {
                messageText = nil
            }
        } else {
            messageText = nil
        }
        
        switch state {
        case "delta":
            // Gateway sends accumulated text (not incremental)
            if let text = messageText {
                await syncBridge.processChatDelta(sessionKey: sessionKey, text: text)
            }
        case "final":
            if let text = messageText {
                let messageId = messageDict?["id"] as? String ?? UUID().uuidString
                let timestamp = messageDict?["timestamp"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000)
                let message = Message(
                    id: messageId,
                    sessionId: sessionKey,
                    role: "assistant",
                    content: text,
                    timestamp: Date(timeIntervalSince1970: Double(timestamp / 1000))
                )
                await syncBridge.saveGatewayMessage(message)
            }
            await syncBridge.processChatFinal(sessionKey: sessionKey)
        case "error":
            await syncBridge.processChatError(sessionKey: sessionKey, errorMessage: errorMessage ?? "Unknown error")
        default:
            break
        }
    }
    
    private func handleSessionMessage(payload: [String: AnyCodable]?) async {
        guard let payload = payload else { return }
        
        guard let sessionKey = payload["sessionKey"]?.value as? String,
              let dataDict = payload["data"]?.value as? [String: Any],
              let content = dataDict["content"] as? String,
              let role = dataDict["role"] as? String else {
            return
        }
        
        // DROP all events from non-BeeChat sessions
        guard await isBeeChatSession(sessionKey) else { return }
        
        let ts = payload["ts"]?.value as? Int64 ?? 0
        let messageId = dataDict["id"] as? String ?? UUID().uuidString
        
        let message = Message(
            id: messageId,
            sessionId: sessionKey,
            role: role,
            content: content,
            timestamp: Date(timeIntervalSince1970: Double(ts / 1000))
        )
        
        await syncBridge.saveGatewayMessage(message)
    }
    
    private func handleAgentEvent(payload: [String: AnyCodable]?) async {
        guard let payload = payload else { return }
        
        // Manual decode of AgentEventPayload from [String: AnyCodable]
        guard let runId = payload["runId"]?.value as? String,
              let stream = payload["stream"]?.value as? String,
              let sessionKey = payload["sessionKey"]?.value as? String,
              let dataDict = payload["data"]?.value as? [String: Any] else {
            return
        }
        
        // DROP all events from non-BeeChat sessions
        guard await isBeeChatSession(sessionKey) else { return }
        
        let seq = payload["seq"]?.value as? Int
        let ts = payload["ts"]?.value as? Int64 ?? 0
        
        let data = AgentEventData(
            itemId: dataDict["itemId"] as? String,
            phase: dataDict["phase"] as? String,
            kind: dataDict["kind"] as? String,
            title: dataDict["title"] as? String,
            status: dataDict["status"] as? String,
            name: dataDict["name"] as? String,
            text: dataDict["text"] as? String,
            toolCallId: dataDict["toolCallId"] as? String,
            meta: dataDict["meta"] as? String,
            progressText: dataDict["progressText"] as? String,
            output: dataDict["output"] as? String
        )
        
        let eventPayload = AgentEventPayload(
            runId: runId,
            stream: stream,
            data: data,
            sessionKey: sessionKey,
            seq: seq,
            ts: ts
        )
        
        await syncBridge.processAgentEvent(eventPayload)
    }
    
    private func handleHealthEvent(payload: [String: AnyCodable]?) async {
        // Health events are primarily for monitoring and not persisted
    }
    
    private func handleSessionsChanged() async {
        try? await syncBridge.fetchSessions()
    }
    
    private func handleTick() async {
        await syncBridge.updateLiveness()
    }
}