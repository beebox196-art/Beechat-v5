import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct EventRouter {
    private let syncBridge: SyncBridge
    
    public init(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }
    
    public func route(event: String, payload: [String: AnyCodable]?) async {
        switch event {
        case "agent":
            await handleAgentEvent(payload: payload)
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
    
    private func handleAgentEvent(payload: [String: AnyCodable]?) async {
        guard let payload = payload else { return }
        
        // Manual decode of AgentEventPayload from [String: AnyCodable]
        guard let runId = payload["runId"]?.value as? String,
              let stream = payload["stream"]?.value as? String,
              let sessionKey = payload["sessionKey"]?.value as? String,
              let dataDict = payload["data"]?.value as? [String: Any] else {
            return
        }
        
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
