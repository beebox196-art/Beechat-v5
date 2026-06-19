# Fix B: Streaming State Machine — Session Key Mismatch + Topic Switching

**Spec version:** 1.1  
**Date:** 2026-05-10  
**Status:** APPROVED — Amendments incorporated (last-wins comment, defensive else branch in didStopStreaming)  
**Fixes:** Hang bug — UI stuck in thinking state when streaming events arrive for background sessions  
**Files:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`, `Sources/App/UI/MainWindow.swift`

---

## Problem

When a stream starts on a session key that doesn't match the currently-selected topic (e.g., a cron job or subagent), `didStartStreaming` returns early without updating any streaming state. When `didStopStreaming` arrives for the same session, it also returns early. Net result:

1. The thinking timeout fires after 60s, resetting to idle
2. The active topic never shows streaming content
3. If the user switches to the background-streaming topic, no poll is running — the UI shows nothing
4. Rapid state cycling (thinking → timeout → idle → thinking) causes SwiftUI recomputation spikes

---

## Changes

### Change B1: SyncBridgeObserver — Always track streaming, conditionally update UI

**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

**Before (`didStartStreaming`):**
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
    Task { @MainActor in
        let normalizedIncoming = self.normalizedSessionKey(sessionKey)
        let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)

        self.agentActivityTracker.didStartStreaming(sessionKey: sessionKey)

        if normalizedIncoming != normalizedCurrent {
            self.unreadCounts[normalizedIncoming, default: 0] += 1
            BeeChatLogger.log("[ThinkingBee] didStartStreaming — mismatch (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")]) — counting unread")
            return
        }

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
```

**After:**
```swift
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
```

**Key changes:**
- Background sessions: set `streamingSessionKey` (if nothing else is streaming) so topic-switching can find it later. **Do NOT set `isStreaming = true` or `thinkingState = .streaming`** — those are UI state for the active topic only.
- Active sessions: unchanged.
- Agent activity tracking: always happens (moved before the guard).
- Comment documents the last-wins behavior for `streamingSessionKey` and references future Fix B2.

---

**Before (`didStopStreaming`):**
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
    Task { @MainActor in
        self.agentActivityTracker.didStopStreaming(sessionKey: sessionKey)

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
```

**After:**
```swift
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
```

**Key changes:**
- If the stopping session matches `streamingSessionKey`, reset — even if it's not the active topic.
- If it's a background session not being tracked, just log.
- **Defensive `else` branch:** If `normalizedIncoming == normalizedCurrent` but doesn't match `streamingSessionKey`, reset anyway. This handles the edge case where `streamingSessionKey` becomes stale (e.g., overwritten by a background session) — the UI should never get stuck in a streaming state.

---

### Change B2: Add catch-up method

**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

Add a new method:

```swift
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
```

---

### Change B3: MainWindow sidebarSelection — Catch up streaming on topic switch

**File:** `Sources/App/UI/MainWindow.swift`

**Before:**
```swift
private var sidebarSelection: Binding<String?> {
    Binding(
        get: { messageViewModel.selectedTopicId },
        set: { newId in
            if let id = newId, id != messageViewModel.selectedTopicId {
                messageViewModel.selectTopic(id: id)
                // Update observer's knowledge of which session is selected
                syncBridgeObserver.currentSelectedSessionKey = messageViewModel.selectedTopic?.sessionKey
                // Clear unread for the newly selected topic
                syncBridgeObserver.clearUnread(for: messageViewModel.selectedTopic?.sessionKey)
            }
        }
    )
}
```

**After:**
```swift
private var sidebarSelection: Binding<String?> {
    Binding(
        get: { messageViewModel.selectedTopicId },
        set: { newId in
            if let id = newId, id != messageViewModel.selectedTopicId {
                messageViewModel.selectTopic(id: id)
                let newSessionKey = messageViewModel.selectedTopic?.sessionKey
                // Update observer's knowledge of which session is selected
                syncBridgeObserver.currentSelectedSessionKey = newSessionKey
                // Clear unread for the newly selected topic
                syncBridgeObserver.clearUnread(for: newSessionKey)
                // If this topic is already streaming in the background, catch up the UI
                if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key) {
                    syncBridgeObserver.catchUpStreaming(for: key)
                }
            }
        }
    )
}
```

---

## Scenarios Verified

| Scenario | Before | After |
|----------|--------|-------|
| Background stream starts | Returns early, no tracking | Sets `streamingSessionKey` (if not streaming), increments unread. Last background session wins for `streamingSessionKey`. |
| Background stream ends | Returns early, no cleanup | Resets streaming state if it was the tracked session; logs if not tracked |
| Background stream ends (stale `streamingSessionKey`) | N/A | Defensive reset if it matches current topic |
| User switches to background-streaming topic | No poll running, UI blank | `catchUpStreaming()` starts poll, transitions UI |
| User switches away from streaming topic | N/A | Same (handled by `didStopStreaming`) |
| Thinking timeout fires after 60s | Resets to idle | Same (safety net still active) |
| Multiple background streams | N/A | Last one tracked for `streamingSessionKey`. All tracked by `agentActivityTracker` and `unreadCounts`. |
| Active topic stream | Full UI transition | Same, unchanged |

---

## Known Limitation

If the user sends a message and the gateway assigns a different session key for the response (e.g., appends a run ID), `didStartStreaming` will mismatch and the thinking timeout will reset to idle after 60s. The user won't see the response in real-time.

This is a **pre-existing bug**, not introduced by this fix. It should be addressed by Fix B2 (multi-stream tracking with `Set<String>`) in a future sprint.

---

*Approved by Q and Kieran. Ready for implementation.*