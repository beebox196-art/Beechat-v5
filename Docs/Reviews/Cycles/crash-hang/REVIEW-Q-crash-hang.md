# Q Review: Crash & Hang Evaluation

**Date:** 2026-05-10  
**Reviewer:** Q (code implementation specialist)  
**Spec:** EVALUATION-crash-hang-2026-05-10.md  
**Verdict:** Root cause analysis is **correct**. Proposed fixes are **mostly sound** but have gaps and one subtle safety concern.

---

## 1. Root Cause Analysis — Verification

### Bug A: CheckedContinuation Double-Resume ✅ Correct

I traced the code paths and confirmed the double-resume scenario:

```
GatewayClient.call() line 129-155:
  └─ withCheckedThrowingContinuation { continuation in
       └─ Task {
            ├─ pendingRequests.add() → registers resolve/reject callbacks + timeout timer
            ├─ JSONEncoder.encode(frame)
            ├─ transport.send(text)  // ← await point
            └─ catch {
                 ├─ pendingRequests.remove(id:reason:)  // ← removes entry, calls reject() if found
                 └─ continuation.resume(throwing: error)  // ← UNCONDITIONAL
               }
          }
     }
```

**The race:**

1. `pendingRequests.add()` registers a timeout timer (DispatchSource, fires after `config.requestTimeout`).
2. `transport.send(text)` is awaited.
3. **Timeout fires** → `DispatchSource` dispatches `Task { await self.remove(id:reason:) }` on `PendingRequestMap` actor → finds entry → calls `req.reject(error)` → reject closure runs → `continuation.resume(throwing: error)` → **first resume**.
4. **`transport.send()` throws** (e.g., WebSocket closed) → catch block → `await pendingRequests.remove(id:reason:)` → entry already gone → returns silently → `continuation.resume(throwing: error)` → **second resume** → `EXC_BREAKPOINT`.

The `remove()` method returns `void` and doesn't signal whether it already invoked the reject callback. The catch block has no way to know the continuation was already resumed. **Confirmed.**

**Additional double-resume path via `disconnect()`:**

`disconnect()` calls `pendingRequests.clearAll()` which iterates all pending entries and calls `req.reject()` on each. If a `call()` is in-flight during disconnect, `clearAll()` resumes the continuation via the reject callback. Then the catch block in `call()` also resumes it. Same crash. **Confirmed.**

### Bug B: Streaming State Machine — Session Key Mismatch ✅ Correct

Traced `SyncBridgeObserver.didStartStreaming` and `didStopStreaming`:

```
didStartStreaming(sessionKey: "agent:main:runXYZ")
  → normalizedIncoming = "runxyz"
  → normalizedCurrent = "topicabc" (from currentSelectedSessionKey)
  → mismatch → return early
  → thinkingState stays .thinking (set by onMessageSent)
  → isStreaming stays false (never set)
  → no poll started

60s later → thinkingTimeoutTask fires → resetStreamingState() → thinkingState = .idle

didStopStreaming(sessionKey: "agent:main:runXYZ")
  → mismatch → return early
  → streaming state never cleaned up for this session
```

**Confirmed.** The state machine conflates two concerns: (a) tracking which sessions are active, and (b) updating the UI for the currently-selected topic. When they diverge, neither works correctly.

**On the 99% CPU claim:** The evaluation attributes this to the streaming poll running in a tight loop. I disagree with this specific attribution. When `didStartStreaming` returns early for a mismatched key, `isStreaming` stays `false` and `startStreamingPoll()` is never called. The poll can't spin if it never starts.

The 99% CPU is more likely caused by:
- **Rapid `thinkingState` cycling**: `onMessageSent` → `.thinking` → 60s timeout → `.idle` → repeat. Each cycle triggers SwiftUI body recomputation.
- **SyncBridge streaming content processing**: The bridge may be processing and forwarding streaming data even when the observer doesn't display it.
- **Multiple overlapping cron jobs**: Each creates its own `Task { @MainActor in ... }` block. If cron jobs run every 5 minutes and each takes 30-60s to stream, you get overlapping task chains.

The 50ms poll is a red herring for this specific crash scenario, but Fix C (poll guard) is still good defensive hygiene.

---

## 2. Proposed Fixes — Safety Review

### Fix A1: hasResumed Guard

**Verdict: Safe and correct, with one caveat.**

The `hasResumed` flag prevents double-resume in all tested scenarios:

| Scenario | hasResumed check | Result |
|----------|-----------------|--------|
| Timeout fires before catch block | reject closure sets `hasResumed = true` → catch block sees `true` → returns | ✅ |
| Catch block runs before timeout | `remove()` calls reject → `hasResumed = true` → catch block sees `true` → returns | ✅ |
| `disconnect()` calls `clearAll()` | reject closure sets `hasResumed = true` → catch block sees `true` → returns | ✅ |
| Normal resolve path | resolve closure sets `hasResumed = true` → catch block never runs | ✅ |

**Caveat — Data race on `hasResumed`:**

`hasResumed` is a local `var` inside the `withCheckedThrowingContinuation` closure. It's accessed by:
- The resolve/reject closures (called from inside `PendingRequestMap` actor methods)
- The catch block (runs on the calling Task's executor)

While actor serialization + `await` provides practical ordering (the `await pendingRequests.remove()` in the catch block won't return until the actor method completes, by which point `hasResumed` is already set), this is technically a data race in the Swift concurrency model. The `Bool` is not `Sendable` and is accessed from different concurrency domains.

**In practice, this is safe** because:
1. The reject closure is called synchronously inside the actor's `remove()` method
2. The catch block's `await pendingRequests.remove()` provides a happens-before barrier
3. The probability of a race window is vanishingly small

**But for absolute correctness**, I recommend using `OSAllocatedUnfairLock<Bool>` or Swift Atomics `Atomic<Bool>`:

```swift
import Atomics  // or use OSAllocatedUnfairLock

let hasResumed = Atomic<Bool>(false)

// In closures:
guard !hasResumed.exchange(true, ordering: .relaxed) else { return }
continuation.resume(...)
```

This eliminates the theoretical race entirely. The cost is negligible.

### Fix A2: remove() Return Value

**Verdict: Good as defense-in-depth, but A1 is preferred as the primary fix.**

A2 changes `PendingRequestMap.remove()` to return `Bool`. This is cleaner architecturally — the actor owns the knowledge of whether the entry was found and its callback invoked. But:
- Every call site must check the return value (easy to miss one)
- The `clearAll()` method also needs a similar mechanism (returns `Int` count?)
- A1 is simpler and more defensive (the guard is in the closure itself, not at every call site)

**Recommendation:** Implement A1 as the primary fix. Consider A2 as a follow-up refactor for clarity, but don't block on it.

### Fix B1: Conditional Streaming Update

**Verdict: Logically sound but has a gap — topic switching needs additional handling.**

The core idea (always track streaming sessions, conditionally update UI) is correct. The modified `didStartStreaming` and `didStopStreaming` handle the main scenarios well:

| Scenario | Old behaviour | New behaviour (B1) |
|----------|--------------|-------------------|
| Background stream starts | return early, no tracking | `streamingSessionKey` set (if `!isStreaming`), unread counted |
| Background stream stops | return early, no cleanup | `resetStreamingState()` called if it was the streaming session |
| Active topic stream starts | full UI transition | same ✅ |
| Active topic stream stops | full UI reset | same ✅ |

**Gap: Topic switching doesn't restart the streaming state.**

When the user switches topics via `sidebarSelection`:
```swift
set: { newId in
    messageViewModel.selectTopic(id: id)
    syncBridgeObserver.currentSelectedSessionKey = messageViewModel.selectedTopic?.sessionKey
    syncBridgeObserver.clearUnread(for: messageViewModel.selectedTopic?.sessionKey)
}
```

If a stream is already active on the newly-selected topic (from a previous `didStartStreaming` that returned early), the streaming poll is NOT running for it. The user sees no streaming indicator.

**Fix:** Add logic to the sidebar selection setter:

```swift
set: { newId in
    if let id = newId, id != messageViewModel.selectedTopicId {
        messageViewModel.selectTopic(id: id)
        let newSessionKey = messageViewModel.selectedTopic?.sessionKey
        syncBridgeObserver.currentSelectedSessionKey = newSessionKey
        syncBridgeObserver.clearUnread(for: newSessionKey)
        
        // If this topic was already streaming (background stream), catch up the state
        if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key) {
            syncBridgeObserver.startStreamingPoll()
            syncBridgeObserver.thinkingState = .streaming
            syncBridgeObserver.startStreamingTimeout()
        }
    }
}
```

**Note:** `startStreamingPoll()` and `startStreamingTimeout()` are currently `private`. They'd need to be `internal` or the fix needs a different approach (e.g., a `catchUpStreaming(for:)` method).

**Secondary concern:** Setting `streamingSessionKey` for background sessions without starting the poll means `streamingSessionKey` holds a key for which no content is being polled. This is harmless for the UI (which checks `isStreaming` AND `streamingSessionKey` match), but could cause confusion in debugging.

### Fix C: Poll Guard

**Verdict: Good defensive measure, low risk.**

Adding `guard self.isStreaming else { return }` inside the poll loop ensures the poll terminates even if `stopStreamingPoll()` isn't called. This protects against:
- Race conditions where `resetStreamingState()` is called but the task cancellation doesn't propagate
- Future code changes that might forget to cancel the poll

The guard is cheap (one Bool check per iteration) and provides a safety net. **Recommended.**

---

## 3. Edge Cases the Evaluation Misses

### 3.1 `onMessageSent` → `thinkingState = .thinking` → Mismatch → Timeout

When the user sends a message, `onMessageSent` sets `thinkingState = .thinking` and starts the thinking timeout. If the response comes back on a different session key (e.g., gateway assigns a new run ID), `didStartStreaming` returns early and the thinking timeout fires after 60s, resetting to `.idle`.

**Problem:** If the user then switches to the streaming topic, the state is already reset to idle. There's no way to recover the streaming indicator. The response content is streaming but the UI shows nothing.

**Mitigation:** The Fix B1 + topic-switching catch-up (see above) partially addresses this. But if `resetStreamingState()` was already called by the timeout, `isStreaming` is `false` and `streamingSessionKey` is `nil`. The catch-up logic won't help.

**Better fix:** Track streaming state per-session-key (Fix B2 direction). For now, the 90s `streamingTimeoutTask` provides a safety net — if `didStopStreaming` never fires, the 90s timeout resets everything.

### 3.2 `autoResetting` Flag Has No Guard

`didStartAutoReset` and `didStopAutoReset` don't check session keys. They set `autoResetting = true/false` for ALL sessions. This means if ANY agent starts auto-resetting, the UI shows "Refreshing context..." for the current topic, even if the current topic isn't being reset.

**Low risk** — auto-reset is rare and short-lived. But it's a correctness issue.

### 3.3 `startStreamingPoll()` Doesn't Check `Task.isCancelled` Before Sleeping

```swift
private func startStreamingPoll() {
    stopStreamingPoll()
    streamingPollTask = Task {
        while !Task.isCancelled {
            if let bridge = syncBridge {
                let content = await bridge.streamingContent(for: selectedKey)
                self.streamingContent = content
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }
}
```

The `while !Task.isCancelled` check happens at the top of the loop. If the task is cancelled during `await bridge.streamingContent(for:)` or during `Task.sleep`, the `catch` block returns. But if cancellation happens between the `await` and the `sleep`, the task does one more iteration before checking `isCancelled`. This is a negligible issue — one extra iteration every 50ms — but Fix C's guard makes it cleaner.

### 3.4 `clearAll()` in `disconnect()` Has No Guard Against In-Flight `call()`

`disconnect()` calls `await pendingRequests.clearAll(reason:)` which rejects all pending entries. If a `call()` is in-flight, its continuation is resumed by `clearAll()`. Then the catch block in `call()` also tries to resume. Fix A1 handles this, but the evaluation doesn't explicitly test it.

**Testing checklist item A-CRASH-3 covers this.** Good.

### 3.5 `nextRequestId` Overflow

`nextRequestId` is an `Int` that increments on every `call()`. On 64-bit platforms, this would take ~300 years to overflow at 1000 calls/second. Not a real concern, but worth noting for completeness.

---

## 4. Simpler / More Robust Approaches

### For Bug A: Restructure `call()` to Avoid the Race Entirely

Instead of adding a guard, restructure the method so that `pendingRequests.remove()` is the **only** path to resuming the continuation:

```swift
return try await withCheckedThrowingContinuation { continuation in
    var resumed = false
    
    Task {
        await pendingRequests.add(id: id, timeout: config.requestTimeout,
            resolve: { [weak self] payload in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: payload)
            },
            reject: { [weak self] error in
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: error)
            }
        )
        
        do {
            let data = try JSONEncoder().encode(frame)
            guard let text = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "GatewayClient", code: -3, ...)
            }
            try await transport.send(text)
        } catch {
            // Don't resume here — let the reject callback handle it
            await pendingRequests.remove(id: id, reason: error.localizedDescription)
            // remove() calls reject() which resumes the continuation
            // If already removed (timeout fired), reject was already called
        }
    }
}
```

The key change: **remove the unconditional `continuation.resume(throwing:)` from the catch block**. The `pendingRequests.remove()` call already calls `reject()` which resumes the continuation. If the entry was already removed (by timeout), the reject was already called. No need for a second resume.

This eliminates the double-resume path entirely without needing a `hasResumed` guard. But it requires trusting that `remove()` always calls `reject()` when the entry exists, which it does.

**However**, this changes the error that gets thrown — the catch block's error is replaced by the timeout's error (if timeout fired first). This is acceptable since both are error states.

**I'd recommend Fix A1 as-is** because it's less invasive and the `hasResumed` guard is more explicit about intent. The restructured approach is clever but harder to reason about.

### For Bug B: Use a Set of Active Streaming Keys

The evaluation mentions Fix B2 (multi-stream tracking) as a "better long-term architecture." I agree. The current single-`streamingSessionKey` approach fundamentally can't handle multiple concurrent streams correctly. A `Set<String>` of active streaming keys would:

```swift
var activeStreamingKeys: Set<String> = []

func didStartStreaming(sessionKey: String) {
    activeStreamingKeys.insert(normalizedSessionKey(sessionKey))
    agentActivityTracker.didStartStreaming(sessionKey: sessionKey)
    
    if normalizedSessionKey(sessionKey) == normalizedSessionKey(currentSelectedSessionKey ?? "") {
        // Active topic — full UI transition
        cancelThinkingTimeout()
        thinkingState = .streaming
        isStreaming = true
        streamingSessionKey = sessionKey
        startStreamingPoll()
        startStreamingTimeout()
    } else {
        unreadCounts[normalizedSessionKey(sessionKey), default: 0] += 1
    }
}

func didStopStreaming(sessionKey: String) {
    activeStreamingKeys.remove(normalizedSessionKey(sessionKey))
    agentActivityTracker.didStopStreaming(sessionKey: sessionKey)
    
    if normalizedSessionKey(sessionKey) == normalizedSessionKey(streamingSessionKey ?? "") {
        resetStreamingState()
    }
}
```

This is more correct but requires more UI changes (showing streaming indicators per-topic in the sidebar). **Defer to next sprint as the evaluation recommends.**

---

## 5. Summary

| Fix | Verdict | Risk | Notes |
|-----|---------|------|-------|
| **A1: hasResumed guard** | ✅ **Approve** | Low | Minor data race on `hasResumed` (non-atomic), but ordering through `await` makes it safe in practice. Consider `Atomic<Bool>` for correctness. |
| **A2: remove() return value** | ⚠️ **Defer** | Medium | Cleaner architecturally but requires auditing all call sites. Use as follow-up. |
| **B1: Conditional streaming update** | ✅ **Approve with changes** | Medium | **Must add topic-switching catch-up logic** in `sidebarSelection` setter. Without it, switching to a streaming topic shows nothing. |
| **B2: Multi-stream tracking** | ⏳ **Defer** | High | Better long-term fix. Requires sidebar UI changes. |
| **C: Poll guard** | ✅ **Approve** | Low | Defensive measure, no downside. |

### Recommended Implementation Order

1. **Fix A1** — Immediate, prevents the crash. Add `Atomic<Bool>` if available, otherwise `hasResumed` is acceptable.
2. **Fix C** — Immediate, prevents poll accumulation.
3. **Fix B1 + topic-switching catch-up** — Addresses the hang. Must include the sidebar selection change.
4. **Fix B2** — Next sprint, proper multi-stream support.

### Testing Priorities

**Must-pass before merge:**
- A-CRASH-1 through A-CRASH-5 (crash scenarios)
- B-HANG-1 (responsive with concurrent streams)
- B-HANG-2 (switching to streaming topic shows content) — **new test for catch-up logic**

**Can defer:**
- B-HANG-3 (switching away doesn't leave stuck state) — covered by B1
- A-EDGE-1 (rapid connect/disconnect) — nice-to-have

---

_Reviewed by Q, 2026-05-10 16:56 GMT_
