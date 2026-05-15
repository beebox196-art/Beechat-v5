# Fix C: Streaming Poll Safety Guard

**Spec version:** 1.1  
**Date:** 2026-05-10  
**Status:** APPROVED — No changes required  
**Fixes:** Potential CPU spin if streaming poll task doesn't terminate cleanly  
**Files:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

---

## Problem

`startStreamingPoll()` creates a `Task` that polls `streamingContent(for:)` every 50ms in a `while !Task.isCancelled` loop. If `resetStreamingState()` is called but the task cancellation doesn't propagate immediately (cooperative cancellation), or if `stopStreamingPoll()` is skipped due to a state machine race, the poll task could continue running after `isStreaming` has been set to `false`.

While the 50ms sleep makes a single runaway poll task unlikely to cause 99% CPU on its own, multiple leaked poll tasks over time could accumulate and cause sustained CPU usage.

---

## Changes

### Change C1: Add isStreaming guard and [weak self] to poll loop

**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

**Before:**
```swift
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
```

**After:**
```swift
private func startStreamingPoll() {
    stopStreamingPoll()
    streamingPollTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self, self.isStreaming else { return }
            if let bridge = self.syncBridge {
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
```

**Changes:**
1. **`guard let self, self.isStreaming else { return }`** — if `isStreaming` becomes `false` (via `resetStreamingState()`), the poll exits on the next iteration, even if `stopStreamingPoll()` wasn't called or its cancellation hasn't propagated yet.
2. **`[weak self]`** — prevents a retain cycle if the poll task outlives the observer. Since `SyncBridgeObserver` is `@MainActor @Observable`, the `Task` inherits MainActor context and reads `self.isStreaming` and `self.streamingSessionKey` on the correct actor. If `self` is deallocated, `guard let self` returns `nil` and the poll exits cleanly.

---

## Scenarios Verified

| Scenario | Before | After |
|----------|--------|-------|
| Normal: stream starts, poll runs, stream ends, `resetStreamingState()` called | `stopStreamingPoll()` cancels task → task exits | Same, plus `isStreaming` guard exits on next iteration |
| Edge case: `resetStreamingState()` called but `stopStreamingPoll()` skipped | Poll continues until `Task.isCancelled` — but cancellation was never triggered | Poll exits on next iteration when `isStreaming == false` |
| Edge case: Multiple `startStreamingPoll()` calls | `stopStreamingPoll()` cancels previous, starts new | Same |
| Edge case: Observer deallocated while poll running | Poll holds strong reference, continues running | `[weak self]` — `self` is `nil`, poll exits |
| Normal: `isStreaming` is `true` throughout | Poll runs normally, 50ms interval | Identical |

---

## What This Does NOT Change

- No changes to `didStartStreaming`, `didStopStreaming`, or any state machine logic
- No changes to `startStreamingTimeout()` or `startThinkingTimeout()`
- No changes to `resetStreamingState()` or `stopStreamingPoll()`
- The poll interval remains 50ms
- No changes to `GatewayClient` or `PendingRequestMap`

---

*Approved by Kieran. No amendments required. Ready for implementation.*