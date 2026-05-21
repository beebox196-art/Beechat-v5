import Foundation
import BeeChatGateway

public protocol SyncBridgeDelegate: AnyObject {
    func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState)
    func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error)
    func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didFailSummaryInjection sessionKey: String)
}

public extension SyncBridgeDelegate {
    func syncBridge(_ bridge: SyncBridge, didFailSummaryInjection sessionKey: String) {
        // Default empty implementation — observers that don't care can omit this
    }
}
