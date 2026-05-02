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
    /// Safety net: auto-reset streaming state if stuck for more than 90 seconds
    private var streamingTimeoutTask: Task<Void, Never>?
    private static let streamingTimeoutSeconds: TimeInterval = 90
    /// Safety net: auto-reset thinking state if no streaming starts within 15 seconds
    private var thinkingTimeoutTask: Task<Void, Never>?
    private static let thinkingTimeoutSeconds: TimeInterval = 15

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

    /// Normalises a session key for consistent comparison and dictionary lookup.
    /// Strips the `agent:main:` prefix and lowercases so that
    /// `agent:main:ABC`, `ABC`, and `agent:main:abc` all match.
    nonisolated func normalizedSessionKey(_ key: String) -> String {
        SessionKeyNormalizer.stripPrefix(key).lowercased()
    }

    /// Returns true if the given session key matches the currently streaming session.
    func isStreamingSession(_ sessionKey: String?) -> Bool {
        guard let current = streamingSessionKey, let other = sessionKey else { return false }
        return normalizedSessionKey(current) == normalizedSessionKey(other)
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
        Task { @MainActor in
            // Cancel thinking timeout — streaming has started
            self.cancelThinkingTimeout()

            // Normalise keys before comparison so bare UUIDs and full gateway keys match
            let normalizedIncoming = self.normalizedSessionKey(sessionKey)
            let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)

            // Mark unread if streaming started in a topic that isn't currently selected
            if normalizedIncoming != normalizedCurrent {
                self.unreadCounts[normalizedIncoming, default: 0] += 1
                BeeChatLogger.log("[ThinkingBee] didStartStreaming — mismatch (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")]) — counting unread")
                return
            }

            let oldState = self.thinkingState
            BeeChatLogger.log("[ThinkingBee] didStartStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .streaming")
            self.isStreaming = true
            self.streamingSessionKey = sessionKey
            self.thinkingState = .streaming
            self.startStreamingPoll()
            self.startStreamingTimeout()
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
        Task { @MainActor in
            let normalizedIncoming = self.normalizedSessionKey(sessionKey)
            let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)

            guard normalizedIncoming == normalizedCurrent else {
                BeeChatLogger.log("[ThinkingBee] didStopStreaming — GUARD SKIPPED (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")])")
                return
            }
            let oldState = self.thinkingState
            BeeChatLogger.log("[ThinkingBee] didStopStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .idle")
            self.resetStreamingState()
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String) {
        Task { @MainActor in
            self.autoResetting = true
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {
        Task { @MainActor in
            self.autoResetting = false
        }
    }

    /// Reset all streaming state back to idle
    private func resetStreamingState() {
        isStreaming = false
        streamingSessionKey = nil
        streamingContent = ""
        thinkingState = .idle
        stopStreamingPoll()
        cancelStreamingTimeout()
        cancelThinkingTimeout()
    }

    private func startStreamingPoll() {
        stopStreamingPoll()
        streamingPollTask = Task {
            while !Task.isCancelled {
                if let bridge = syncBridge {
                    let selectedKey = self.streamingSessionKey ?? ""
                    let content = await bridge.streamingContent(for: selectedKey)
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

    /// Safety net: if didStopStreaming never fires, auto-reset after timeout
    private func startStreamingTimeout() {
        cancelStreamingTimeout()
        streamingTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.streamingTimeoutSeconds * 1_000_000_000))
            } catch {
                return // Cancelled
            }
            guard !Task.isCancelled else { return }
            BeeChatLogger.log("[ThinkingBee] Streaming timeout — auto-resetting to idle (didStopStreaming never fired)")
            self.resetStreamingState()
        }
    }

    private func cancelStreamingTimeout() {
        streamingTimeoutTask?.cancel()
        streamingTimeoutTask = nil
    }

    /// Start thinking timeout safety net — if didStartStreaming never fires within 30s,
    /// auto-reset to idle so the bee doesn't spin forever
    func startThinkingTimeout() {
        cancelThinkingTimeout()
        thinkingTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.thinkingTimeoutSeconds * 1_000_000_000))
            } catch {
                return // Cancelled
            }
            guard !Task.isCancelled else { return }
            BeeChatLogger.log("[ThinkingBee] Thinking timeout — auto-resetting to idle (didStartStreaming never fired within \(Int(Self.thinkingTimeoutSeconds))s)")
            self.resetStreamingState()
        }
    }

    private func cancelThinkingTimeout() {
        thinkingTimeoutTask?.cancel()
        thinkingTimeoutTask = nil
    }

    /// Tracks unread assistant message counts per session key.
    /// Key = session key, Value = number of unread messages.
    /// Reset on topic selection. Lost on app restart (acceptable for a visual indicator).
    var unreadCounts: [String: Int] = [:]

    /// The session key of the currently selected topic.
    /// Set from MainWindow.sidebarSelection so didStartStreaming knows whether to count.
    var currentSelectedSessionKey: String?

    /// Clear the unread count for a given session key (called when user selects that topic).
    func clearUnread(for sessionKey: String?) {
        guard let key = sessionKey else { return }
        unreadCounts.removeValue(forKey: normalizedSessionKey(key))
    }

    /// Set to true while an auto-reset is in progress (for UI binding).
    var autoResetting: Bool = false


}