# Independent Review: Crash & Hang Evaluation Spec

**Reviewer:** Kieran (independent challenger)  
**Date:** 2026-05-10  
**Spec under review:** `EVALUATION-crash-hang-2026-05-10.md`  
**Verdict:** **CONDITIONALLY APPROVED** — diagnosis is sound, but several gaps and risks need addressing before implementation.

---

## 1. Diagnosis Validity

### 1.1 Crash Bug (CheckedContinuation double-resume)

**Verdict: Likely correct, but incomplete causal chain.**

The spec identifies a genuine double-resume scenario: timeout fires → `remove()` calls `reject` → continuation resumes → catch block resumes again. This is a real bug.

**What the spec may be missing:**

There's a **third path** that's equally dangerous and not explicitly called out. Look at the `call()` method in `GatewayClient.swift`:

```swift
return try await withCheckedThrowingContinuation { continuation in
    Task {
        await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { ... }, reject: { ... })
        // ... send ...
    }
}
```

The `withCheckedThrowingContinuation` itself has a completion handler that runs when the inner `Task` completes *without* resuming the continuation. If the `Task` body throws (e.g., `transport.send` throws something unexpected that isn't caught), or if the `Task` is cancelled before any resume path fires, the `withCheckedThrowingContinuation` will **itself** trap because the continuation was never resumed at all.

This is the opposite problem — **non-resume** rather than double-resume — and it's equally catastrophic. The spec doesn't address this.

**Additional concern:** The `Task` inside `withCheckedThrowingContinuation` is fire-and-forget from the continuation's perspective. If the outer `call()` method is cancelled (e.g., the calling Task is cancelled), the `withCheckedThrowingContinuation` will resume with a `CancellationError`, but the inner `Task` continues running. When the timeout fires or the response arrives, it will try to resume an already-resumed continuation. **This is a cancellation-safety hole.**

### 1.2 Hang Bug (Session key mismatch)

**Verdict: Correct diagnosis, but the 99% CPU cause may be misattributed.**

The spec attributes 99% CPU to `streamingPoll` running in a tight loop. Looking at the actual code:

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
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }
}
```

This polls every 50ms with `Task.sleep`. Even running continuously, this should produce ~20fps of `streamingContent` reads — not 99% CPU. **The 99% CPU is more likely caused by one of:**

1. **Multiple `startStreamingPoll()` calls without cancelling previous ones** — if `resetStreamingState()` isn't called and a new stream starts, `stopStreamingPoll()` cancels the old task, but cancellation is cooperative. If the old task is mid-`Task.sleep`, it takes up to 50ms to exit. With rapid state transitions, you could accumulate 2-3 poll tasks briefly, but not enough for 99% CPU.

2. **The `resetStreamingState()` → `startThinkingTimeout()` loop** — this is the more likely culprit. When `didStopStreaming` returns early (guard mismatch), the thinking timeout fires after 60s, calls `resetStreamingState()`, which may trigger a re-send or auto-reset, which starts a new thinking timeout, which fires again. But even this is a 60s cycle, not a tight loop.

3. **`streamingContent(for:)` itself may be the CPU hog** — if `SyncBridge.streamingContent()` does heavy work (string concatenation, regex, large data processing) and is called every 50ms, this could produce sustained high CPU. The spec doesn't examine this method.

4. **MainActor contention** — `SyncBridgeObserver` is `@MainActor`. If `didStartStreaming` and `didStopStreaming` callbacks are firing rapidly from background threads (via `Task { @MainActor in ... }`), they queue up on the MainActor run loop. If the main thread is also blocked rendering UI or processing other MainActor work, this creates a backlog. The "beachball" could be MainActor starvation, not CPU spin.

**Recommendation:** Before fixing, instrument with `os_signpost` or Instruments to identify which thread is actually consuming CPU. The fix may need to target a different bottleneck than the spec assumes.

---

## 2. Fix-by-Fix Analysis

### 2.1 Fix A1 — Boolean `hasResumed` Guard

**Strengths:**
- Minimal change, easy to verify
- Guards all four resume paths (resolve, reject, encoding error, send error)
- Works correctly with `clearAll()` during disconnect

**Weaknesses and risks:**

1. **`hasResumed` is a `var` captured by two closures inside a `Task`.** Since `GatewayClient` is an `actor`, and the closures are passed to `PendingRequestMap` (also an `actor`), the `hasResumed` variable is **non-Sendable state captured across actor boundaries**. Swift 6 strict concurrency would flag this. At minimum, this is undefined behaviour — two actors (GatewayClient's internal Task and PendingRequestMap's timer queue) can read/write `hasResumed` concurrently without synchronisation.

   **Fix:** Make `hasResumed` an `AtomicBool` (using `OSAllocatedUnsafeAtomic` in Swift 6, or a simple `NSLock`-backed wrapper), or better yet, use `Unmanaged`-safe patterns.

2. **The `Task` inside `withCheckedThrowingContinuation` is not linked to the continuation's lifecycle.** If the caller of `call()` cancels their awaiting Task, the continuation resumes with `CancellationError`, but the inner `Task` keeps running. The `hasResumed` guard prevents the crash, but the continuation has already been resumed — so the resolve/reject callbacks become no-ops. This is safe but leaks the pending request entry until timeout. The entry should be removed on cancellation.

3. **`hasResumed` is declared inside the `withCheckedThrowingContinuation` closure but captured by the inner `Task`.** This creates a retain cycle risk: the `Task` holds the closures, the closures capture `hasResumed` (which is stack-allocated in the outer closure). In practice, Swift handles this by heap-allocating the capture, but it's worth verifying with Instruments that no leak occurs during rapid call/disconnect cycles.

### 2.2 Fix A2 — `remove()` Return Value

**Strengths:**
- Clean ownership semantics: `PendingRequestMap` owns the decision of whether the continuation was resumed
- No cross-actor mutable state

**Weaknesses:**
- The spec recommends A1 over A2, but **A2 is actually safer from a concurrency perspective**. A1 introduces a data race on `hasResumed`; A2 doesn't.
- The concern about "every call site must check" is overstated — there are only two call sites in `call()` (encoding error and send error), both visible in one method.
- However, `remove()` currently calls `reject()` on the pending entry. If we change it to return `true` only when it actually removed and rejected, the caller needs to know: did the rejection already happen (return true), or was the entry already gone (return false)? If it was already resolved (not rejected), `remove()` returns false and the caller should resume with error. This semantic is subtle and error-prone.

**Recommendation:** Actually, **neither A1 nor A2 alone is sufficient**. The right approach is A2 (return value from `remove()`) **plus** cancellation handling. When A2 returns `true`, the caller does nothing. When it returns `false`, the entry was already resolved OR already removed — in either case, the caller should NOT resume because something else already did. But what if the entry was resolved (not removed)? Then `remove()` returns `false`, and the caller also doesn't resume. The continuation was already resumed by `resolve()`. This is correct.

**But wait — there's a gap:** If `resolve()` was called (continuation resumed with payload), and then the catch block runs (because `transport.send` threw after the response arrived — unlikely but possible in theory), `remove()` returns `false`, and the catch block doesn't resume. Correct. But the `catch` block's error is silently swallowed. The caller gets the successful payload, which is fine — but the error is lost. This is acceptable for a fire-and-forget send, but worth noting.

### 2.3 Fix B1 — Conditional Streaming Update

**Strengths:**
- Separates tracking from UI concern
- Prevents the `didStopStreaming` guard from silently dropping events

**Weaknesses and risks:**

1. **The spec's B1 code has a logic error.** Look at this path:

   ```swift
   if normalizedIncoming != normalizedCurrent {
       unreadCounts[normalizedIncoming, default: 0] += 1
       if !isStreaming {
           streamingSessionKey = sessionKey
       }
       return
   }
   ```

   If `isStreaming` is `false` (idle), and a background session starts streaming, this sets `streamingSessionKey` to the background session's key — but does NOT set `isStreaming = true` and does NOT start the poll. Then when the user switches to that topic, `currentSelectedSessionKey` changes, but nothing triggers `didStartStreaming` again (the stream already started). The UI won't show streaming content because the poll was never started.

   **The fix:** When the user switches topics (in `sidebarSelection`'s setter), check if the new topic is actively streaming and if so, start the poll and set `isStreaming = true`. This is mentioned in the spec's side effects but not addressed in the code.

2. **`didStopStreaming` in B1 calls `resetStreamingState()` if the stopping session matches `streamingSessionKey`.** But `resetStreamingState()` resets `thinkingState = .idle`, `isStreaming = false`, etc. — all for the UI. If the user is currently viewing a *different* topic that is also streaming (or in thinking state), this resets the wrong topic's state. The single `thinkingState` / `isStreaming` model cannot handle multiple concurrent streams, which is why B2 was proposed. B1 paper-overs this by assuming only one stream at a time, but that assumption is demonstrably false (cron jobs + user messages overlap).

3. **The `onMessageSent` → `thinkingState = .thinking` path is unchanged.** If the user sends a message and the response comes back on a different session key (e.g., gateway assigns a new run ID), `didStartStreaming` will mismatch, the thinking timeout fires, and the state resets to idle — the user never sees their response. This is a **critical gap** that B1 doesn't address. The fix needs to either: (a) ensure the session key is stable across send/receive, or (b) relax the matching logic to handle gateway-assigned run IDs.

### 2.4 Fix C — Poll Guard

**Strengths:**
- Simple defensive check
- `guard self.isStreaming` ensures the poll exits even without explicit cancellation

**Weaknesses:**

1. **The spec's proposed code uses `[weak self]` in the poll task, but `SyncBridgeObserver` is `@Observable` and `@MainActor`.** The `self.isStreaming` read needs to be on the MainActor. The current code (without `[weak self]`) already runs on MainActor because `startStreamingPoll()` is called from MainActor methods. Adding `[weak self]` and then reading `self.isStreaming` from a non-isolated `Task` closure would need `@MainActor` annotation or a `Task { @MainActor in ... }` wrapper. The spec's code doesn't show this.

2. **The existing code already has `stopStreamingPoll()` called at the start of `startStreamingPoll()`.** The guard is redundant in the happy path. It only helps if `resetStreamingState()` fails to call `stopStreamingPoll()`. Given that `resetStreamingState()` explicitly calls `stopStreamingPoll()`, this is a belt-and-suspenders fix — harmless but low value.

---

## 3. Interaction Risks Between Fixes

| Interaction | Risk | Assessment |
|---|---|---|
| A1 + B1 | If `hasResumed` prevents a crash during disconnect, and B1's `didStopStreaming` fires during the same disconnect, the order of operations matters. `clearAll()` rejects all pending requests → triggers `didStopStreaming` callbacks → B1 resets streaming state. This is safe. | Low risk |
| A1 + C | The poll guard (`guard isStreaming`) and `hasResumed` guard are independent. No interaction. | No risk |
| B1 + C | If B1 sets `streamingSessionKey` for a background topic but doesn't start the poll, and C's guard exits early because `isStreaming` is false, switching to that topic won't restart anything. | **Medium risk — topic switching gap** |
| A2 + B1 | A2 changes `remove()` semantics. B1 doesn't call `remove()` directly, so no interaction. | No risk |

---

## 4. Testing Checklist Gaps

### Missing tests:

1. **A-CANCEL-1:** Caller's Task is cancelled while `call()` is awaiting. Verify no crash and no leaked continuation.
2. **A-CANCEL-2:** Rapid fire 10 `call()`s, cancel all after 1s. Verify no crashes, no leaked pending entries.
3. **B-THREAD-1:** `didStartStreaming` and `didStopStreaming` fire from different threads simultaneously. Verify no data race on `isStreaming`, `streamingSessionKey`, `thinkingState`.
4. **B-SESSION-1:** User sends a message, gateway assigns a different session key for the response. Verify `didStartStreaming` matches correctly.
5. **B-RECONNECT-1:** Connection drops mid-stream, reconnects, stream resumes on same or different session key. Verify state doesn't get stuck.
6. **CPU-1:** Run with 3 concurrent cron job streams + user on a different topic. Measure actual CPU with Instruments. Verify it stays below 15%.
7. **INTEGRATION-1:** Full cycle: send message → stream starts → switch topic → switch back → stream ends. Verify all state transitions are correct.

### Tests that should be removed or deprioritised:

- **A-CRASH-4 / A-CRASH-5** (normal paths) are regression tests, not crash tests. Keep them, but they're lower priority than the cancellation tests.

---

## 5. Implementation Order

The spec doesn't explicitly state an order, but implies A → B → C. I agree with this order, with one modification:

1. **Fix A (A2 preferred over A1)** — This is the highest severity (crash). Fix first. Use A2 (return value from `remove()`) because it avoids the cross-actor data race in A1. Add cancellation handling at the same time.
2. **Fix C** — Low risk, defensive. Can be done alongside A.
3. **Fix B1** — Higher risk, needs topic-switching logic added. Do this last and test thoroughly with concurrent streams.

**Why not B1 first?** B1 doesn't fix the crash. The crash is P1. B1 fixes a hang that may have a different root cause (see §1.2 above). Fix the definite crash first, instrument the hang to confirm the root cause, then fix.

---

## 6. Swift Concurrency Concerns

### 6.1 Actor Isolation

- `GatewayClient` is an `actor`. The `Task` inside `withCheckedThrowingContinuation` captures `hasResumed` (a non-Sendable `var`) and passes closures capturing it to `PendingRequestMap` (another `actor`). **This violates Swift concurrency safety.** The closures are executed on `DispatchQueue.global()` (from `DispatchSourceTimer`), which is non-isolated. Reading/writing `hasResumed` from multiple queues without synchronisation is a data race.

- `SyncBridgeObserver` is `@MainActor @Observable`. The `syncBridge(_:didStartStreaming:)` and `syncBridge(_:didStopStreaming:)` methods are `nonisolated` and dispatch to MainActor via `Task { @MainActor in ... }`. This is correct, but if callbacks fire faster than the MainActor can process them, the `Task`s queue up. With rapid cron job streams, this could contribute to MainActor starvation.

### 6.2 Sendable

- `AgentActivityTracker` and its nested types are marked `Sendable`, which is correct.
- The `resolve` and `reject` closures in `PendingRequestMap.PendingRequest` are `@escaping` but not explicitly `@Sendable`. In Swift 6 strict mode, this would be an error if the closures capture non-Sendable state. Currently, they capture the `continuation` from `GatewayClient.call()`, which is not `Sendable`. This compiles today but would fail under strict concurrency.

### 6.3 MainActor Assumptions

- `SyncBridgeObserver` methods like `resetStreamingState()`, `startStreamingPoll()`, `stopStreamingPoll()` are all called from MainActor contexts (via `Task { @MainActor in ... }`). This is correct. But `streamingPollTask`'s `Task` closure is not explicitly MainActor-isolated. It reads `self.streamingSessionKey` and writes `self.streamingContent` — both MainActor-isolated properties. This works because `@Observable` classes propagate the actor isolation, but it's worth verifying that the poll task actually runs on MainActor.

---

## 7. The `hasResumed` Leak Question (Question 7 from spec)

**"Could the `hasResumed` boolean in Fix A1 cause a leak if the continuation is never resumed at all?"**

**Answer:** Not a memory leak, but a **logical leak**. If the continuation is never resumed:

1. The `withCheckedThrowingContinuation` will trap (Swift checks for non-resumed continuations when the closure scope exits without a resume).
2. So the app crashes anyway — just with a different trap (non-resume instead of double-resume).

The `hasResumed` flag itself doesn't leak because it's captured by the closures and released when the closures are released (when `PendingRequestMap` removes the entry). But if the entry is never removed (e.g., `pendingRequests` is never called with `remove`, `resolve`, `reject`, or `clearAll` for that ID), the closures and their captures persist until `GatewayClient` is deallocated. This is a minor leak but not critical.

**The real question is:** Under what circumstances would the continuation never be resumed? The only path is if the `Task` inside `withCheckedThrowingContinuation` is cancelled before any resume path fires, AND the `withCheckedThrowingContinuation` doesn't auto-resume on cancellation. This is the **cancellation gap** I identified in §2.1.

---

## 8. Summary of Recommendations

| Priority | Action | Rationale |
|---|---|---|
| **P0** | Use A2 (return value from `remove()`) instead of A1 | Avoids cross-actor data race on `hasResumed` |
| **P0** | Add cancellation handling to `call()` | Prevents non-resume trap and leaked pending entries |
| **P1** | Instrument CPU before fixing B1 | 99% CPU may not be caused by what the spec assumes |
| **P1** | Add topic-switching logic to B1 | Without it, switching to a streaming topic won't show content |
| **P1** | Address `onMessageSent` → session key mismatch | Critical gap: user sends message, response on different key, never shown |
| **P2** | Add `[weak self]` + `@MainActor` to poll task in Fix C | Prevents retain cycle and ensures correct actor isolation |
| **P2** | Add 7 missing test cases listed in §4 | Covers cancellation, threading, and integration scenarios |
| **P3** | Consider B2 (multi-stream tracking) for v5.1 | B1 is a patch; the single-stream model is fundamentally limited |

---

## 9. Final Verdict

The spec's **diagnosis of the crash is sound** but the **proposed Fix A1 introduces a data race** that could cause undefined behaviour under Swift concurrency. **Fix A2 is safer** and should be preferred, with cancellation handling added.

The **hang diagnosis is plausible but not confirmed** — the 99% CPU may have a different root cause. Instrument before fixing.

**Fix B1 has a logic gap** in the topic-switching path that would leave the UI unable to show streaming content for background topics. This must be addressed.

**Overall: APPROVE with conditions** — address the concurrency safety of Fix A, instrument the hang before fixing B, and add the missing topic-switching logic.

---

*Kieran — 2026-05-10*
