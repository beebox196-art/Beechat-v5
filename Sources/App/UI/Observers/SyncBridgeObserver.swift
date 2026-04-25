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
    var thinkingState: ThinkingState = .idle

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
            let oldState = self.thinkingState
            BeeChatLogger.log("[ThinkingBee] didStartStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .streaming")
            self.isStreaming = true
            self.streamingSessionKey = sessionKey
            self.thinkingState = .streaming
            self.startStreamingPoll()
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            let oldState = self.thinkingState
            BeeChatLogger.log("[ThinkingBee] didStopStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .idle")
            self.isStreaming = false
            self.streamingSessionKey = nil
            self.thinkingState = .idle
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
                // Yield to prevent CPU spin — 50ms gives ~20fps update rate for streaming content
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopStreamingPoll() {
        streamingPollTask?.cancel()
        streamingPollTask = nil
    }
}