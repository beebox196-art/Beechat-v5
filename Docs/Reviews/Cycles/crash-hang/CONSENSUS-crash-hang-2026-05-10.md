# Crash & Hang Review — Consensus Summary

**Date:** 2026-05-10  
**Reviewers:** Q (implementation), Kieran (challenge), Bee (coordinator)  
**Based on:** EVALUATION-crash-hang-2026-05-10.md, REVIEW-Q-crash-hang.md, REVIEW-KIERAN-crash-hang.md

---

## Agreed Findings

All three reviewers agree on:

1. **Bug A diagnosis is correct.** The `CheckedContinuation` double-resume in `GatewayClient.call()` is a real crash path. The timeout's `reject` callback and the catch block both attempt to resume the same continuation.

2. **Bug B diagnosis is correct.** The session key mismatch guard in `SyncBridgeObserver` causes streaming events for background sessions to be silently dropped, leaving the UI stuck in thinking state that times out after 60s.

3. **Fix C (poll guard) is safe and low-risk.** Adding `guard self.isStreaming else { return }` to the poll loop is good defensive hygiene.

4. **Fix B2 (multi-stream tracking) should be deferred.** It's the right long-term architecture but requires sidebar UI changes.

---

## Resolved Disagreements

### A1 vs A2 — hasResumed guard vs remove() return value

**Q's position:** A1 is preferred — simpler, more defensive, guard is at the closure level.
**Kieran's position:** A2 is preferred — A1 introduces a cross-actor data race on `hasResumed` (non-Sendable Bool accessed from different actor boundaries).

**Consensus: Use A2 as the primary fix, with A1-style guards in the closures as defense-in-depth.**

Rationale:
- Kieran is correct that `hasResumed` is technically a data race (non-atomic Bool captured across actor boundaries). In Swift 6 strict concurrency mode, this would be a compile error.
- A2 is cleaner from a concurrency perspective — `PendingRequestMap` (an actor) owns the decision, and the return value is deterministic.
- However, A2 alone has a subtle gap: if `remove()` returns `false` because the entry was already *resolved* (not rejected), the catch block would silently swallow its error. This is acceptable (the caller already got a successful payload), but it needs a comment explaining why.
- Defense-in-depth: add `hasResumed` guards *inside* the resolve/reject closures passed to `add()`, so even if `remove()` semantics change later, the continuation can't be double-resumed.

**Implementation:**

```swift
// PendingRequestMap.swift — change remove() to return Bool
@discardableResult
public func remove(id: String, reason: String) -> Bool {
    if let req = pending.removeValue(forKey: id) {
        req.timer.cancel()
        req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
        return true  // Continuation was resumed via reject
    }
    return false  // Entry already gone — continuation already resumed
}

// GatewayClient.swift — call() method
return try await withCheckedThrowingContinuation { continuation in
    var hasResumed = false  // Defense-in-depth, not sole protection
    
    Task {
        await pendingRequests.add(id: id, timeout: config.requestTimeout,
            resolve: { payload in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: payload)
            },
            reject: { error in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(throwing: error)
            }
        )
        
        do {
            let data = try JSONEncoder().encode(frame)
            guard let text = String(data: data, encoding: .utf8) else {
                let error = NSError(domain: "GatewayClient", code: -3, ...)
                let alreadyHandled = await pendingRequests.remove(id: id, reason: error.localizedDescription)
                if !alreadyHandled {
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
                return
            }
            try await transport.send(text)
        } catch {
            let alreadyHandled = await pendingRequests.remove(id: id, reason: error.localizedDescription)
            if !alreadyHandled {
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**Why both:** A2 provides the architecturally correct signal (did `remove()` handle it?). A1's `hasResumed` catches any remaining edge cases where the resolve/reject closure fires after the catch block (e.g., `disconnect()` → `clearAll()` fires while catch block is also running). The `hasResumed` flag is a safety net, not the primary mechanism.

---

### Cancellation handling in call()

**Kieran's position:** P0 — if the caller's Task is cancelled, `withCheckedThrowingContinuation` traps on non-resumed continuation.
**Q's position:** Not explicitly flagged.

**Consensus: Add cancellation handling as part of Fix A.**

The `withCheckedThrowingContinuation` documentation states that the continuation must be resumed exactly once. If the calling Task is cancelled, the continuation must still be resumed. Currently, there's no cancellation handling.

**Implementation — add to call() method:**

```swift
return try await withCheckedThrowingContinuation { continuation in
    // ... existing code ...
    
    // Cancellation handling: resume with CancellationError if task is cancelled
    // before any other resume path fires.
    Task {
        try Task.checkCancellation()  // Check immediately
        // The withCheckedThrowingContinuation already handles cancellation
        // by resuming with CancellationError when the calling task is cancelled.
        // But the inner Task keeps running. We need to clean up.
    }
}
```

Actually — Swift's `withCheckedThrowingContinuation` does NOT auto-resume on cancellation. It's `withTaskCancellationHandler` that provides cancellation handling. We need to wrap the call properly:

```swift
public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
    guard state == .connected else {
        throw NSError(domain: "GatewayClient", code: -1, ...)
    }
    
    let id = "bc-\(nextRequestId)"
    nextRequestId += 1
    let frame = RequestFrame(id: id, method: method, params: params)
    
    return try await withTaskCancellationHandler(
        onCancel: {
            Task { await self.pendingRequests.remove(id: id, reason: "Request cancelled") }
        }
    ) {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            Task {
                await pendingRequests.add(id: id, timeout: config.requestTimeout,
                    resolve: { payload in
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(returning: payload)
                    },
                    reject: { error in
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                )
                
                do {
                    let data = try JSONEncoder().encode(frame)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw NSError(domain: "GatewayClient", code: -3, ...)
                    }
                    try await transport.send(text)
                    // Send succeeded — response will come via handleResponse()
                } catch {
                    let alreadyHandled = await pendingRequests.remove(id: id, reason: error.localizedDescription)
                    if !alreadyHandled {
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
```

The `onCancel` handler removes the pending request (which calls `reject` → `hasResumed = true` → continuation resumed with error). This prevents the non-resume trap.

**Note:** The `onCancel` handler creates a detached `Task` to call `remove()`. This is necessary because `onCancel` is synchronous and can't `await` an actor method directly.

---

### 99% CPU root cause

**Q's position:** Not the streaming poll (it's not running). Likely SwiftUI recomputation from rapid state cycling + MainActor contention.
**Kieran's position:** Not confirmed — needs instrumentation. Could be `streamingContent(for:)` overhead or MainActor starvation.

**Consensus: Fix the state machine (Bug B) first, then measure.**

Both reviewers agree the 50ms poll can't produce 99% CPU on its own. The most likely cause is the rapid cycling of `thinkingState` (`.thinking` → 60s timeout → `.idle` → user sends message → `.thinking` → ...) causing continuous SwiftUI recomputation, combined with MainActor task queuing from overlapping cron streams.

Fixing Bug B (preventing the state machine from getting stuck) should resolve the hang. If CPU remains high after the fix, we'll instrument with `os_signpost` to identify the actual bottleneck.

---

### Topic-switching gap in B1

**Both reviewers flag this.** If a background stream starts and the user later switches to that topic, no poll is running and the UI shows nothing.

**Consensus: Must include topic-switching catch-up logic in the `sidebarSelection` setter.**

```swift
// In MainWindow.swift, sidebarSelection setter:
set: { newId in
    if let id = newId, id != messageViewModel.selectedTopicId {
        messageViewModel.selectTopic(id: id)
        let newSessionKey = messageViewModel.selectedTopic?.sessionKey
        syncBridgeObserver.currentSelectedSessionKey = newSessionKey
        syncBridgeObserver.clearUnread(for: newSessionKey)
        
        // Catch-up: if this topic is already streaming, restart the poll
        if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key) {
            syncBridgeObserver.catchUpStreaming(for: key)
        }
    }
}
```

Add a `catchUpStreaming(for:)` method to `SyncBridgeObserver`:

```swift
func catchUpStreaming(for sessionKey: String) {
    cancelThinkingTimeout()
    thinkingState = .streaming
    isStreaming = true
    streamingSessionKey = sessionKey
    startStreamingPoll()
    startStreamingTimeout()
}
```

This method must be `internal` (not `private`) so it can be called from `MainWindow`.

---

### onMessageSent → session key mismatch

**Kieran's position:** P1 critical gap — if the gateway assigns a different session key, the user never sees their response.
**Q's position:** Mentioned as an edge case but not flagged as critical.

**Consensus: Document as a known limitation of B1. Not a regression — this bug exists today.**

The current code already has this problem: if the gateway assigns a different session key, `didStartStreaming` mismatches and the thinking timeout fires. B1 doesn't make this worse. B2 (multi-stream tracking) would fix it properly by matching streams to topics rather than exact session keys.

**Action:** Add a comment in the code and a test case (B-SESSION-1) for future B2 work.

---

## Final Approved Fix List

| # | Fix | Priority | Risk | Notes |
|---|-----|----------|------|-------|
| A | `call()` double-resume guard | **P0** | Low | A2 (return value) + A1 (hasResumed) defense-in-depth + cancellation handler |
| B | Streaming state machine | **P1** | Medium | B1 + topic-switching catch-up. Document session-key mismatch as known limitation |
| C | Poll guard | **P1** | Low | Add `guard isStreaming` check. Verify MainActor isolation of poll task |

**Implementation order:**
1. Fix A (crash prevention — highest severity)
2. Fix C (poll guard — can be done alongside A, low risk)
3. Fix B (hang prevention — needs careful topic-switch testing)

---

## Additional Items (Not Blocking, Track for vNext)

| Item | Priority | Notes |
|------|----------|-------|
| `autoResetting` flag has no session-key guard | P2 | Shows "Refreshing..." for any agent's reset, not just current topic |
| B2: Multi-stream tracking with `Set<String>` | P3 | Proper fix for session key mismatches |
| `hasResumed` → `Atomic<Bool>` | P3 | Eliminate theoretical data race in strict Swift 6 mode |
| `streamingContent(for:)` performance audit | P3 | Instrument to confirm it's not a CPU bottleneck |
| Sendable annotation audit | P3 | `resolve`/`reject` closures in PendingRequestMap should be `@Sendable` |
| 7 missing test cases (Kieran §4) | P2 | Cancellation, threading, integration scenarios |

---

## Testing Requirements (Updated)

### Must-pass before merge:

- [ ] A-CRASH-1: No crash on WebSocket disconnect during active `call()`
- [ ] A-CRASH-2: No crash when timeout and catch block fire simultaneously
- [ ] A-CRASH-3: No crash on `disconnect()` during in-flight `call()`
- [ ] A-CANCEL-1: No crash when caller Task is cancelled during `call()`
- [ ] A-CANCEL-2: No leaked pending entries after rapid connect/disconnect cycles
- [ ] B-HANG-1: App remains responsive with concurrent cron streams
- [ ] B-HANG-2: Switching to an already-streaming topic shows streaming content
- [ ] B-HANG-6: CPU usage returns to baseline when no streaming is active
- [ ] C-POLL-1: Streaming poll terminates within 100ms of `isStreaming = false`

### Should-pass (regression):

- [ ] A-CRASH-4: Normal `call()` → resolve path works
- [ ] A-CRASH-5: Normal `call()` → reject path works
- [ ] B-HANG-3: Switching away from streaming topic doesn't leave stuck state
- [ ] B-HANG-4: Thinking timeout (60s) correctly resets
- [ ] B-HANG-5: Streaming timeout (90s) correctly resets
- [ ] B-HANG-7: Unread counts still increment for background topics

### Instrumentation (pre-B fix):

- [ ] CPU-1: Run Instruments time profiler with 3 concurrent streams. Identify actual bottleneck.

---

*Consensus reached 2026-05-10. All reviewers signed off on this document.*