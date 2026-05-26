# Final Review: Fix B (Streaming State Machine) & Fix C (Poll Safety Guard)

**Reviewer:** Kieran (independent challenger)  
**Date:** 2026-05-10  
**Specs reviewed:** SPEC-FIX-B-streaming-state.md v1.0, SPEC-FIX-C-poll-guard.md v1.0  
**Source reviewed:** SyncBridgeObserver.swift (current HEAD)

---

## 1. Fix C "Before" code accuracy

**Verdict: ✅ EXACT MATCH**

The spec's "Before" block for `startStreamingPoll()` matches the current source character-for-character. No drift issues.

---

## 2. `[weak self]` safety on `@MainActor @Observable` class

**Verdict: ✅ SAFE**

`SyncBridgeObserver` is `@MainActor @Observable final class`. The `Task { }` created inside inherits `@MainActor` context (Swift concurrency rule: tasks created in a `@MainActor` scope run on `@MainActor`). So:

- `guard let self` — captures `self` strongly for the scope if non-nil. No data race because `self` can only be deallocated on MainActor, and this code runs on MainActor.
- If `self` is deallocated while the poll is sleeping, `guard let self` returns `nil` → poll exits cleanly. No crash on `self.streamingContent = content` because we never reach it.
- `[weak self]` is actually *better* than the current strong capture: without it, a leaked poll task holds a strong reference to the observer, preventing deallocation. With `[weak self]`, the observer can be deallocated and the poll gracefully exits.

**One subtlety worth noting:** Since `@Observable` objects are reference types, their lifecycle is tied to whoever holds them (likely the view hierarchy). If the view disappears and the observer is deallocated, the poll stops — correct behaviour. The `[weak self]` prevents the observer from being *kept alive* by a stale poll, which is an improvement.

---

## 3. `self.isStreaming` actor isolation

**Verdict: ✅ CORRECT**

The `Task { }` in `startStreamingPoll()` is created inside a `@MainActor` class method. Per Swift concurrency rules, this task inherits `@MainActor` context. Both `self.isStreaming` and `self.streamingSessionKey` are `@MainActor`-isolated properties. Reading them inside a `@MainActor` task is safe — no data race.

**Confirmed:** The guard `self.isStreaming` is read on the correct actor.

---

## 4. Fix B `didStopStreaming` — regression risk for current-topic stream reset

**Analysis:**

The old code:
```swift
guard normalizedIncoming == normalizedCurrent else { return }
resetStreamingState()
```

The new code:
```swift
if normalizedSessionKey(streamingSessionKey ?? "") == normalizedIncoming {
    resetStreamingState()
} else if normalizedIncoming != normalizedCurrent {
    // just log
}
```

**Walk-through of the specified scenario:** incoming key matches current key AND matches `streamingSessionKey`:

- `normalizedSessionKey(streamingSessionKey ?? "") == normalizedIncoming` → **TRUE** → `resetStreamingState()` runs. ✅ No regression.

**Walk-through of a different scenario:** incoming key matches current key but does NOT match `streamingSessionKey`:

- First condition FALSE (streamingSessionKey points elsewhere or is nil).
- Second condition: `normalizedIncoming != normalizedCurrent` → FALSE (they match).
- No branch taken. **No reset happens.**

When could this happen? If `streamingSessionKey` was set to a *background* session key (via the new `didStartStreaming` mismatch branch), and then `didStopStreaming` fires for the *current* topic. In that case, `streamingSessionKey` points to the background session, not the current one, so the reset is skipped.

**Is this realistic?** The current topic's `didStartStreaming` would set `streamingSessionKey` to the current key. A background stream starting afterward wouldn't overwrite it (because `!isStreaming` is false — the foreground stream is active). So `streamingSessionKey` would still point to the current topic. The scenario requires `streamingSessionKey` to be set to a background key *while the current topic has no stream tracked*, which only happens if the current topic never started streaming.

**Risk: LOW** but not zero. If `streamingSessionKey` becomes stale (e.g., a bug or race resets it to nil while a foreground stream is active), `didStopStreaming` for the current topic would silently skip the reset. Recommend adding an `else` branch that at least logs when `normalizedIncoming == normalizedCurrent` but doesn't match `streamingSessionKey`, so this edge case is visible in logs.

**Verdict: ⚠️ APPROVE WITH CHANGES** — add a defensive `else` clause for the case where `normalizedIncoming == normalizedCurrent` but `streamingSessionKey` doesn't match. This shouldn't happen in normal flow, but if it does, you want `resetStreamingState()` to run, not to silently do nothing.

**Suggested addition:**
```swift
if normalizedSessionKey(streamingSessionKey ?? "") == normalizedIncoming {
    // Matched the tracked streaming session — reset
    resetStreamingState()
} else if normalizedIncoming != normalizedCurrent {
    // Background session we weren't tracking — just log
    BeeChatLogger.log("...")
} else {
    // Current topic stopped streaming but streamingSessionKey was stale.
    // Defensive: reset anyway to avoid stuck state.
    BeeChatLogger.log("[ThinkingBee] didStopStreaming — current topic mismatch with streamingSessionKey, resetting defensively")
    resetStreamingState()
}
```

---

## 5. `catchUpStreaming(for:)` overwriting `.thinking` state

**Analysis:**

`catchUpStreaming` unconditionally sets `thinkingState = .streaming`. If the user switches to a streaming topic and has just sent a message (so `thinkingState = .thinking`), this overwrites it to `.streaming`.

**Is this correct?** Yes. The stream IS already active on that topic. The `.thinking` state was a transient placeholder meaning "waiting for stream to start." Since the stream has already started (that's why we're catching up), `.streaming` is the correct state. The state machine transition `.thinking → .streaming` is the same path the normal `didStartStreaming` would take.

**Could it overwrite a legitimate `.thinking` from a new user message?** Theoretically: user switches topic → `catchUpStreaming` sets `.streaming` → user immediately types and sends → `thinkingState = .thinking` → gateway's `didStartStreaming` for the new message sets `.streaming`. This sequence is fine — no stuck state.

**But there's a subtlety:** If `catchUpStreaming` is called *after* the user sends a new message on that topic (but before `didStartStreaming` fires for the new message), it would set `.streaming` for the *old* stream while the user expects to see thinking state for the *new* message. However, `catchUpStreaming` starts a new poll that fetches content for the current `streamingSessionKey`. If the gateway has already transitioned to a new stream, the poll would pick up the new content anyway.

**Verdict: ✅ NO ISSUE** — the overwrite is semantically correct. The stream is active, so `.streaming` is the right state regardless of what was there before. This mirrors what `didStartStreaming` already does.

---

## 6. Interactions between Fix B and Fix C

**Analysis:**

The question: does `catchUpStreaming()` → `startStreamingPoll()` work correctly with Fix C's `isStreaming` guard?

Flow:
1. `catchUpStreaming()` sets `isStreaming = true`
2. `catchUpStreaming()` calls `startStreamingPoll()`
3. `startStreamingPoll()` calls `stopStreamingPoll()` (cancels any existing task)
4. `startStreamingPoll()` creates new `Task { [weak self] in ... }`
5. Inside task: `guard let self, self.isStreaming else { return }` — `isStreaming` is `true`, passes ✅

**What if `resetStreamingState()` runs between iterations?** `isStreaming` becomes `false`, guard fails, poll exits. ✅

**What if `catchUpStreaming` is called while a previous poll is still running?** `startStreamingPoll()` calls `stopStreamingPoll()` first, which cancels the old task. The old task exits on `Task.isCancelled` or the `isStreaming` guard. ✅

**What about `startStreamingPoll()` being called from `didStartStreaming` (normal path)?** Same — `isStreaming` is set to `true` before `startStreamingPoll()` is called, so the guard passes. ✅

**Verdict: ✅ NO PROBLEMATIC INTERACTIONS** — Fix B's `catchUpStreaming` correctly sets `isStreaming = true` before calling `startStreamingPoll()`, so Fix C's guard always passes on first iteration. The guard is purely defensive for subsequent iterations.

---

## Summary Verdicts

| Fix | Verdict | Notes |
|-----|---------|-------|
| **Fix C** (Poll Safety Guard) | **✅ APPROVE** | Clean, defensive, no issues found. `[weak self]` is safe and actually an improvement. |
| **Fix B** (Streaming State Machine) | **⚠️ APPROVE WITH CHANGES** | Core logic is sound. One defensive change recommended: add an `else` branch in `didStopStreaming` for the case where `normalizedIncoming == normalizedCurrent` but doesn't match `streamingSessionKey` — reset defensively rather than silently doing nothing. This handles a potential edge case where `streamingSessionKey` becomes stale. |

### Recommended change for Fix B `didStopStreaming`:

```swift
if self.normalizedSessionKey(self.streamingSessionKey ?? "") == normalizedIncoming {
    let oldState = self.thinkingState
    BeeChatLogger.log("[ThinkingBee] didStopStreaming(sessionKey=\(sessionKey)) — Transition: \(oldState) → .idle")
    self.resetStreamingState()
} else if normalizedIncoming != normalizedCurrent {
    BeeChatLogger.log("[ThinkingBee] didStopStreaming — background session ended (incoming=\(sessionKey) [\(normalizedIncoming)] current=\(self.currentSelectedSessionKey ?? "nil") [\(normalizedCurrent ?? "nil")])")
} else {
    // Current topic stopped streaming but streamingSessionKey was stale — reset defensively
    BeeChatLogger.log("[ThinkingBee] didStopStreaming — current topic but stale streamingSessionKey, resetting defensively (incoming=\(sessionKey))")
    self.resetStreamingState()
}
```

This ensures that even in edge cases where `streamingSessionKey` gets out of sync, the UI never gets stuck in a streaming state.

---

*Kieran — Independent Review — 2026-05-10*