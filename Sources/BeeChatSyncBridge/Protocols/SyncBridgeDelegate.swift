import Foundation
import BeeChatGateway

public protocol SyncBridgeDelegate: AnyObject {
    func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState)
    func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error)
    func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String)
    /// Called when the gateway fires a sessions.changed event.
    /// Delegate should call fetchSessionInfos() + upsertTopicsFromGateway() to refresh.
    /// Default: no-op. Only iPhone ViewModel overrides this.
    func syncBridgeSessionsChanged(_ bridge: SyncBridge)
    /// Called when the session reset summary injection fails after retry.
    /// Allows UI to show a toast notifying the user that context was not carried forward.
    func syncBridgeDidFailSummaryInjection(_ bridge: SyncBridge)
}

// MARK: - Default no-op extensions (B9 fix — Mac compiles without changes)
extension SyncBridgeDelegate {
    nonisolated func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
        // Default: no-op. Mac's SyncBridgeObserver doesn't need this.
    }
    nonisolated func syncBridgeDidFailSummaryInjection(_ bridge: SyncBridge) {
        // Default: no-op. Observers override to show toast.
    }
}
