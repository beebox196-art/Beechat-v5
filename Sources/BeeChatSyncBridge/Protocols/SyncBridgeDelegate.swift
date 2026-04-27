import Foundation
import BeeChatGateway

public protocol SyncBridgeDelegate: AnyObject {
    func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState)
    func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error)
    func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String)
}
