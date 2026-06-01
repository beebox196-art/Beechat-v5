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
    /// Safety net: auto-reset thinking state if no streaming starts within 60 seconds.
    /// The gateway can take 30+ seconds to begin streaming for complex requests,
    /// so this must be longer than typical model response latency.
    /// This is a last resort — the normal path is didStartStreaming cancelling this timer.
    private var thinkingTimeoutTask: Task<Void, Never>?
    private static let thinkingTimeoutSeconds: TimeInterval = 60

    func attach(_ bridge: SyncBridge) {
        self.syncBridge = bridge
        Task {
            await bridge.setDelegate(self)
        }
    }


    nonisolated func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState) {
        Task { @MainActor in
            self.connectionState = state
            // When connected, fetch sessions to populate the agent activity tracker
            // with idle agents that haven't streamed yet
            if state == .connected, let bridge = self.syncBridge {
                do {
                    let sessions = try await bridge.fetchSessions()
                    // Extract agent data from Session objects (avoids importing BeeChatPersistence)
                    let agentData: [(agentId: String, lastMessageAt: Date)] = sessions.compactMap {
                        guard let lastAt = $0.lastMessageAt else { return nil }
                        return (agentId: $0.agentId, lastMessageAt: lastAt)
                    }
                    self.agentActivityTracker.updateFromAgentData(agentData)
                } catch {
                    // Non-critical — tracker just won't show idle agents until they stream
                }
            }
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error) {
        print("[SyncBridgeObserver] Error: \(error.localizedDescription)")
        // NOTE: The SyncBridgeDelegate protocol does not pass a session key in
        // didEncounterError, so we cannot determine which agent errored.
        // All errors are attributed to Bee as a known limitation.
        // To fix: extend the protocol to include session context in error callbacks.
        let sessionKey = "agent:main:unknown"
        Task { @MainActor in
            self.agentActivityTracker.didEncounterError(sessionKey: sessionKey)
        }
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
            let normalizedIncoming = self.normalizedSessionKey(sessionKey)
            let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)

            // Always track agent activity for all sessions
            self.agentActivityTracker.didStartStreaming(sessionKey: sessionKey)

            if normalizedIncoming != normalizedCurrent {
                // Background session — count as unread and track for later catch-up
                self.unreadCounts[normalizedIncoming, default: 0] += 1
                BeeChatLogger.log("[ThinkingBee] didStartStreaming — mismatch (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")]) — counting unread")

                // Track background streaming session for topic-switching catch-up.
                // Note: if multiple background sessions start while nothing is streaming,
                // the last one wins for streamingSessionKey. Full multi-session tracking
                // requires Set<String> — tracked as future Fix B2.
                if !self.isStreaming {
                    self.streamingSessionKey = sessionKey
                }
                return
            }

            // Active topic — full UI transition
            self.cancelThinkingTimeout()

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
            // Always update agent activity tracker
            self.agentActivityTracker.didStopStreaming(sessionKey: sessionKey)

            let normalizedIncoming = self.normalizedSessionKey(sessionKey)
            let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)

            // Clean up streaming state if this was the tracked streaming session,
            // regardless of whether it matches the current topic.
            if self.normalizedSessionKey(self.streamingSessionKey ?? "") == normalizedIncoming {
                let oldState = self.thinkingState
                BeeChatLogger.log("[ThinkingBee] didStopStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .idle")
                self.resetStreamingState()
            } else if normalizedIncoming != normalizedCurrent {
                // Background session we weren't tracking — just log
                BeeChatLogger.log("[ThinkingBee] didStopStreaming — background session ended (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")])")
            } else {
                // Current topic stopped streaming but streamingSessionKey was stale.
                // Defensive: reset anyway to avoid stuck state.
                BeeChatLogger.log("[ThinkingBee] didStopStreaming — current topic but stale streamingSessionKey, resetting defensively (incoming=\(sessionKey))")
                self.resetStreamingState()
            }
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
            self.showAutoResetToast = true
            // Auto-dismiss toast after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.showAutoResetToast = false
            }
        }
    }

    /// Called when the user switches to a topic that is already streaming in the background.
    /// Restarts the poll and transitions UI to streaming state.
    func catchUpStreaming(for sessionKey: String) {
        cancelThinkingTimeout()
        thinkingState = .streaming
        isStreaming = true
        streamingSessionKey = sessionKey
        startStreamingPoll()
        startStreamingTimeout()
        BeeChatLogger.log("[ThinkingBee] catchUpStreaming(sessionKey=\(sessionKey)) — restarted streaming for selected topic")
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
        streamingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isStreaming else { return }
                if let bridge = self.syncBridge {
                    let selectedKey = self.streamingSessionKey ?? ""
                    let content = await bridge.streamingContent(for: selectedKey)
                    // Diff guard: only mutate state when content actually changes.
                    // Without this, identical 50 ms polls invalidate SwiftUI body
                    // and trigger LazyVStack infinite layout recomputation.
                    if self.streamingContent != content {
                        self.streamingContent = content
                    }
                }
                // Yield to prevent CPU spin — 200ms gives ~5fps update rate for streaming text.
                // Chat text arrives in bursts; 5fps is imperceptible as "live" while
                // dramatically reducing SwiftUI layout recalculations (75% fewer vs 50ms).
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
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
    /// Set to true while a manual reset is in progress (for UI binding).
    var manualResetting: Bool = false
    /// Set to true briefly when an auto-reset completes (for toast).
    var showAutoResetToast: Bool = false

    nonisolated func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) {
        Task { @MainActor in
            self.manualResetting = true
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) {
        Task { @MainActor in
            self.manualResetting = false
        }
    }

    nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
        // sessions.changed events are handled by the iPhone via REST re-fetch.
        // No action needed on the Mac side — TopicServer serves current data on demand.
    }

    // MARK: - Agent Activity Tracking (C2)

    @MainActor
    @Observable
    final class AgentActivityTracker {
        struct AgentActivity: Sendable {
            let agentId: String
            var status: AgentStatus
            var lastActivityAt: Date
            var sessionKey: String?
        }
        enum AgentStatus: Sendable { case working, idle, error }
        struct RecentEvent: Sendable, Identifiable {
            let id = UUID()
            let agentId: String
            let kind: EventKind
            let timestamp: Date
            enum EventKind: Sendable { case completed, errored }
        }

        var agents: [String: AgentActivity] = [:]
        var recentEvents: [RecentEvent] = []
        private var activeSessions: [String: Set<String>] = [:] // agentId -> sessionKeys
        private var streamStartTimes: [String: Date] = [:] // sessionKey -> when streaming started

        /// Streams shorter than this are treated as heartbeat noise, not real activity
        private static let minimumActivityDuration: TimeInterval = 2.0

        private static let emojiMap: [String: String] = [
            "main": "🐝", "q": "🛠", "mel": "🎨", "kieran": "📋", "gav": "🔍"
        ]

        static func agentEmojiAndName(for agentId: String) -> (emoji: String, name: String) {
            let emoji = emojiMap[agentId.lowercased()] ?? "🤖"
            let name: String
            switch agentId.lowercased() {
            case "main": name = "Bee"
            case "q": name = "Q"
            case "mel": name = "Mel"
            case "kieran": name = "Kieran"
            case "gav": name = "Gav"
            default: name = agentId
            }
            return (emoji, name)
        }

        static func extractAgentId(from sessionKey: String) -> String {
            let parts = sessionKey.split(separator: ":")
            // Patterns: agent:main:... → main; agent:q:main:subagent:... → q; agent:main:cron:... → main
            if parts.count >= 3, parts[0] == "agent" {
                let second = String(parts[1])
                let third = parts.count >= 4 ? String(parts[2]) : nil
                if second == "main" {
                    if let third = third, third == "cron" {
                        return "main"
                    }
                    return "main"
                }
                return second
            }
            return "unknown"
        }

        var hasWorkingAgents: Bool {
            agents.values.contains { $0.status == .working }
        }

        func didStartStreaming(sessionKey: String) {
            let agentId = Self.extractAgentId(from: sessionKey)
            streamStartTimes[sessionKey] = Date()
            var agent = agents[agentId] ?? AgentActivity(agentId: agentId, status: .idle, lastActivityAt: Date(), sessionKey: nil)
            agent.status = .working
            agent.lastActivityAt = Date()
            agent.sessionKey = sessionKey
            agents[agentId] = agent
            activeSessions[agentId, default: []].insert(sessionKey)
        }

        func didStopStreaming(sessionKey: String) {
            let agentId = Self.extractAgentId(from: sessionKey)
            let startTime = streamStartTimes.removeValue(forKey: sessionKey)
            let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
            activeSessions[agentId]?.remove(sessionKey)
            var agent = agents[agentId] ?? AgentActivity(agentId: agentId, status: .idle, lastActivityAt: Date(), sessionKey: nil)
            if activeSessions[agentId]?.isEmpty ?? true {
                agent.status = .idle
                agent.sessionKey = nil
            }
            agent.lastActivityAt = Date()
            agents[agentId] = agent
            // Only add to recent events if the stream lasted long enough to be real activity
            // (not a heartbeat that fires and completes in under 2 seconds)
            if duration >= Self.minimumActivityDuration {
                recentEvents.insert(RecentEvent(agentId: agentId, kind: .completed, timestamp: Date()), at: 0)
                if recentEvents.count > 5 { recentEvents.removeLast() }
            }
        }

        func didEncounterError(sessionKey: String) {
            let agentId = Self.extractAgentId(from: sessionKey)
            activeSessions[agentId]?.remove(sessionKey)
            var agent = agents[agentId] ?? AgentActivity(agentId: agentId, status: .idle, lastActivityAt: Date(), sessionKey: nil)
            agent.status = .error
            agent.lastActivityAt = Date()
            agent.sessionKey = nil
            agents[agentId] = agent
            recentEvents.insert(RecentEvent(agentId: agentId, kind: .errored, timestamp: Date()), at: 0)
            if recentEvents.count > 5 { recentEvents.removeLast() }
        }

        func updateFromSessions(_ sessions: [SessionInfo]) {
            for session in sessions {
                let agentId = session.agentId ?? Self.extractAgentId(from: session.key)
                var agent = agents[agentId] ?? AgentActivity(agentId: agentId, status: .idle, lastActivityAt: Date(), sessionKey: nil)
                // Only update lastActivityAt if session list has newer data and agent isn't currently working
                if agent.status != AgentStatus.working {
                    if let lastMsgStr = session.lastMessageAt,
                       let lastMsg = ISO8601DateFormatter().date(from: lastMsgStr),
                       lastMsg > agent.lastActivityAt {
                        agent.lastActivityAt = lastMsg
                    }
                }
                agents[agentId] = agent
            }
        }

        /// Update tracker from lightweight agent data (avoids cross-module dependency on Session type)
        func updateFromAgentData(_ data: [(agentId: String, lastMessageAt: Date)]) {
            for item in data {
                let agentId = item.agentId
                var agent = agents[agentId] ?? AgentActivity(agentId: agentId, status: .idle, lastActivityAt: Date(), sessionKey: nil)
                if agent.status != AgentStatus.working {
                    if item.lastMessageAt > agent.lastActivityAt {
                        agent.lastActivityAt = item.lastMessageAt
                    }
                }
                agents[agentId] = agent
            }
        }
    }

    let agentActivityTracker = AgentActivityTracker()

}