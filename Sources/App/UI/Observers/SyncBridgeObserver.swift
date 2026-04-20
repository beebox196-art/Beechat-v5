import SwiftUI
import BeeChatSyncBridge
import BeeChatGateway

/// Bridges SyncBridge actor state to @Observable for SwiftUI consumption.
/// SwiftUI views cannot read actor properties synchronously; this observer
/// receives delegate callbacks and publishes them as @Observable properties.
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
        // Must assign delegate on the SyncBridge actor
        Task {
            await bridge.setDelegate(self)
        }
    }

    // MARK: - SyncBridgeDelegate

    nonisolated func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        // TODO: Surface error in UI (Phase 4B error banner)
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
            self.streamingContent = ""
            self.stopStreamingPoll()
        }
    }

    // MARK: - Streaming Content Polling

    /// Poll SyncBridge.currentStreamingContent at ~10 Hz so the UI can show
    /// partial text as it accumulates. SyncBridge is an actor so we can't
    /// read it synchronously from @MainActor.
    private func startStreamingPoll() {
        stopStreamingPoll()
        streamingPollTask = Task {
            while !Task.isCancelled {
                if let bridge = syncBridge {
                    let content = await bridge.currentStreamingContent
                    self.streamingContent = content
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func stopStreamingPoll() {
        streamingPollTask?.cancel()
        streamingPollTask = nil
    }
}