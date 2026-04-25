# FIX-003: Streaming Poll Spin Loop + Thinking Bee State Transitions

**Priority:** High  
**Status:** Spec — awaiting review  
**Author:** Bee (Coordinator)  
**Date:** 2026-04-25

## Problem

Two issues reported by Adam after testing FEAT-002:

1. **BeeChat is very slow to respond** compared to Telegram. The streaming poll in `SyncBridgeObserver.startStreamingPoll()` is a tight `while` loop with no sleep — it polls `currentStreamingContent` from the actor as fast as the CPU allows. This is a spin loop hammering the main actor and likely causing noticeable lag.

2. **Thinking bee only appeared once** — on repeat sends, the bee doesn't reappear. The state machine should cycle: `idle → thinking (on send) → streaming (on first delta) → idle (on stream end)`. Either the transitions aren't firing on repeat sends, or SwiftUI isn't re-rendering the view.

## Scope

**In scope:**
- Fix 1: Add 50ms sleep to streaming poll loop
- Fix 2: Add debug logging to all `thinkingState` transitions to diagnose why bee doesn't reappear

**Out of scope:**
- No changes to `EventRouter`, `SyncBridge`, `BeeChatPersistence`, or `BeeChatGateway`
- No changes to RPC timeout or request pipeline
- No changes to the ThinkingBee component itself (unless diagnostics reveal a bug there)

---

## Fix 1: Streaming Poll Sleep

### Current Code (SyncBridgeObserver.swift)

```swift
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
```

### Problem

This loop runs as fast as the CPU allows — potentially thousands of times per second. Each iteration crosses the actor boundary (`await bridge.currentStreamingContent`). This is:
- Wasting CPU cycles
- Starving other MainActor work
- Likely contributing to perceived slowness

### Solution

Add a 50ms sleep between polls with proper cancellation handling:

```swift
private func startStreamingPoll() {
    stopStreamingPoll()
    streamingPollTask = Task {
        while !Task.isCancelled {
            if let bridge = syncBridge {
                let content = await bridge.currentStreamingContent
                self.streamingContent = content
            }
            // Yield to prevent CPU spin — 50ms gives ~20fps update rate for streaming content
            // Use do/catch so CancellationError triggers immediate exit (not a wasted loop iteration)
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }
}
```

**Why 50ms?** Streaming deltas arrive via WebSocket events (push), not polling. The poll only reads the already-updated `currentStreamingContent` property from the actor. 50ms gives ~20fps UI updates — more than enough for text streaming. Telegram's typing indicator updates at ~10fps. This is a reasonable trade-off between responsiveness and CPU usage.

**Note:** This fixes the CPU spin (streaming smoothness) but does NOT fix time-to-first-token (initial delay). The initial delay is dominated by RPC round-trip + gateway LLM inference. A separate diagnostic pass may be needed for that (see Fix 3 below).

---

## Fix 2: Thinking Bee State Transition Logging

### Current State Machine

| Transition | Trigger | Code Location |
|---|---|---|
| `idle → thinking` | `onMessageSent` callback | `MainWindow.rewireForGateway` |
| `thinking → streaming` | `didStartStreaming` | `SyncBridgeObserver` |
| `streaming → idle` | `didStopStreaming` | `SyncBridgeObserver` |
| `thinking → idle` | `didStopStreaming` (no deltas) | `SyncBridgeObserver` |

### Problem

On repeat sends, the bee doesn't reappear. Possible causes:
1. `onMessageSent` callback not firing on subsequent sends
2. `thinkingState` stuck in a state (e.g., never transitions back to `.idle` after first stream)
3. SwiftUI not re-rendering `ThinkingBeeIndicator` when `thinkingState` changes
4. `rewireForGateway` only called once (`guard !isGatewayWired`), so the closure might be capturing stale state

### Solution

Add debug logging at every state transition point, including callback invocation and guard bails:

```swift
// In MainWindow.rewireForGateway — log entry point:
private func rewireForGateway(_ bridge: SyncBridge) {
    print("[ThinkingBee] rewireForGateway called — isGatewayWired=\(isGatewayWired)")
    guard !isGatewayWired else { return }
    isGatewayWired = true
    
    // ... existing code ...
    
    composerViewModel.onMessageSent = { [weak syncBridgeObserver] in
        let currentState = syncBridgeObserver?.thinkingState ?? .idle
        print("[ThinkingBee] onMessageSent fired — current state: \(currentState)")
        guard currentState != .streaming else {
            print("[ThinkingBee] Guarded: already streaming, not transitioning to .thinking")
            return
        }
        syncBridgeObserver?.thinkingState = .thinking
        print("[ThinkingBee] Transition: \(currentState) → .thinking")
    }
}

// In ComposerViewModel.send() — log at the call site:
func send() async {
    guard canSend else { return }
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    inputText = ""
    print("[ThinkingBee] ComposerViewModel.send() — about to call onMessageSent")
    onMessageSent?()
    print("[ThinkingBee] ComposerViewModel.send() — onMessageSent callback returned")
    do {
        try await messageViewModel?.sendMessage(text: text)
        print("[ThinkingBee] sendMessage RPC completed successfully")
    } catch {
        print("[ThinkingBee] Send failed: \(error)")
    }
}

// In SyncBridgeObserver.didStartStreaming:
nonisolated func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String) {
    Task { @MainActor in
        let oldState = self.thinkingState
        print("[ThinkingBee] didStartStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .streaming")
        self.isStreaming = true
        self.streamingSessionKey = sessionKey
        self.thinkingState = .streaming
        self.startStreamingPoll()
    }
}

// In SyncBridgeObserver.didStopStreaming:
nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
    Task { @MainActor in
        let oldState = self.thinkingState
        print("[ThinkingBee] didStopStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .idle")
        self.isStreaming = false
        self.streamingSessionKey = nil
        self.thinkingState = .idle
        self.stopStreamingPoll()
    }
}

// In MessageCanvas — add logging when thinkingState changes:
.onChange(of: thinkingState) { oldState, newState in
    print("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
}
```

**This is diagnostic only.** No logic changes beyond logging. The logs will tell us exactly which transitions fire (or don't) on repeat sends, including:
- Whether `rewireForGateway` is called (and whether it bails)
- Whether `onMessageSent` callback is invoked
- Whether the `.streaming` guard blocks the transition
- Whether `didStartStreaming` / `didStopStreaming` fire
- The full state transition chain: `idle → thinking → streaming → idle`

---

## Files Changed

| File | Change |
|---|---|
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | Add 50ms sleep to `startStreamingPoll()`, add debug logging to `didStartStreaming` and `didStopStreaming` |
| `Sources/App/UI/MainWindow.swift` | Add debug logging to `onMessageSent` callback |
| `Sources/App/UI/Components/MessageCanvas.swift` | Add `.onChange` logging for `thinkingState` |

## Validation Criteria

1. **Build:** `xcodebuild -scheme BeeChatApp -destination 'platform=macOS' build` passes
2. **No regressions:** App connects, shows topics, displays messages, sends messages, streams AI responses — same as baseline
3. **CPU usage:** Streaming poll no longer hammers the main actor — CPU usage noticeably lower during streaming
4. **Diagnostics:** Console logs show the full state transition chain on every send:
   ```
   [ThinkingBee] ComposerViewModel.send() — about to call onMessageSent
   [ThinkingBee] onMessageSent fired — current state: idle
   [ThinkingBee] Transition: idle → .thinking
   [ThinkingBee] MessageCanvas: thinkingState changed idle → .thinking
   [ThinkingBee] didStartStreaming(sessionKey=xxx) — Transition: .thinking → .streaming
   [ThinkingBee] MessageCanvas: thinkingState changed .thinking → .streaming
   [ThinkingBee] sendMessage RPC completed successfully
   [ThinkingBee] didStopStreaming(sessionKey=xxx) — Transition: .streaming → .idle
   [ThinkingBee] MessageCanvas: thinkingState changed .streaming → .idle
   ```
5. **If bee doesn't reappear:** Logs will reveal exactly which transition is missing or blocked

## Rollback

Revert 3 files to previous state. No data layer changes, no schema changes.

## Next Steps (after diagnostics)

**If logs show `didStopStreaming` never fires:** The gateway isn't sending a stop event (or the delegate isn't wired). Need a timeout guard — if state is `.streaming` for >30s without deltas, force back to `.idle`.

**If logs show state stuck in `.streaming` but `didStopStreaming` fires:** MainActor Task ordering issue — `didStartStreaming` and `didStopStreaming` Tasks execute out of order. Fix: add `isStreaming` boolean check before setting state.

**If logs show `onMessageSent` never called on repeat sends:** `ComposerViewModel.send()` isn't being called — check `Composer` view's send button binding.

**If logs show `onMessageSent` called but guard blocks:** State is stuck at `.streaming` — same as above, investigate why `didStopStreaming` isn't resetting it.

**If `didStopStreaming` fires but state doesn't reset:** `Task { @MainActor }` ordering issue — `didStartStreaming` runs after `didStopStreaming` on MainActor. Fix: check `isStreaming` boolean in the Task before setting state.