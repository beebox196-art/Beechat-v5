import SwiftUI
import BeeChatSyncBridge
import BeeChatGateway

@MainActor
@Observable
final class SyncBridgeObserver: SyncBridgeDelegate {
    var isStreaming: Bool = false
    var streamingSessionKey: String?
    var streamingContent: String = ""
    var connectionState: ConnectionState = .disconnected

    private var syncBridge: SyncBridge?
    private var streamingPollTask: Task<Void, Never>?

    func attach(_ bridge: SyncBridge) {
        self.syncBridge = bridge
        Task {
            await bridge.setDelegate(self)
        }
    }


    nonisolated func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        print("[SyncBridgeObserver] Error: \(error.localizedDescription)")
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = true
            self.streamingSessionKey = sessionKey
            self.startStreamingPoll()
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            self.isStreaming = false
            self.streamingSessionKey = nil
            self.stopStreamingPoll()
        }
    }


    private func startStreamingPoll() {
        stopStreamingPoll()
        streamingPollTask = Task {
            while !Task.isCancelled {
                if let bridge = syncBridge {
                    let content = await bridge.currentStreamingContent
                    self.streamingContent = content
                }
            }
        }
    }

    private func stopStreamingPoll() {
        streamingPollTask?.cancel()
        streamingPollTask = nil
    }
}