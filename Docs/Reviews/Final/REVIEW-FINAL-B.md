# Review: Fix B — Streaming State Machine (Session Key Mismatch + Topic Switching)

**Reviewer:** Q  
**Date:** 2026-05-10  
**Spec version:** 1.0  
**Verdict:** **APPROVE WITH CHANGES**

---

## 1. Does the "Before" code in the spec exactly match the current source?

**Mostly yes, with minor comment discrepancies.**

### `didStartStreaming`

The spec's "Before" omits two comments present in the actual source:

- `// Agent activity tracking` before `self.agentActivityTracker.didStartStreaming(sessionKey: sessionKey)`
- `// Mark unread if streaming started in a topic that isn't currently selected` before the `if normalizedIncoming != normalizedCurrent` block
- `// Only cancel thinking timeout for the currently selected session / (must happen after the guard so background sessions don't kill the timeout)` before `self.cancelThinkingTimeout()`

**Logic matches exactly.** The comment gaps are cosmetic but should be fixed for spec accuracy. No functional difference.

### `didStopStreaming`

Matches exactly. No discrepancies.

### `sidebarSelection`

Matches exactly. No discrepancies.

**Action:** Update spec "Before" blocks to include the actual source comments, or note that comments are omitted for brevity.

---

## 2. Does the "After" code compile?

**Yes, with one note.**

All method calls (`cancelThinkingTimeout`, `startStreamingPoll`, `startStreamingTimeout`, `resetStreamingState`, `isStreamingSession`) exist on `SyncBridgeObserver`. Types align — `thinkingState` is `ThinkingState`, `.streaming` is a valid case, `isStreaming` is `Bool`, `streamingSessionKey` is `String?`.

The new `catchUpStreaming(for:)` method calls `private` methods (`startStreamingPoll()`, `startStreamingTimeout()`, `cancelThinkingTimeout()`), but since it's defined *within* `SyncBridgeObserver`, this compiles fine — private access is scoped to the type, not the individual method.

**No compilation issues.**

---

## 3. Is `catchUpStreaming(for:)` called on `@MainActor`? Is `SyncBridgeObserver` `@MainActor`?

**Yes. `SyncBridgeObserver` is `@MainActor` class.** The declaration is:

```swift
@MainActor
@Observable
final class SyncBridgeObserver: SyncBridgeDelegate {
```

Since the entire class is `@MainActor`, all its properties and methods are implicitly `@MainActor`. `catchUpStreaming(for:)` will run on the main actor. The call site in `MainWindow.sidebarSelection` is a SwiftUI `Binding` setter, which executes on the main thread as part of the view update cycle.

**No issues. Compiles and runs correctly.**

---

## 4. Two background sessions starting simultaneously — only first tracked?

The spec's "After" for `didStartStreaming` adds:

```swift
if !self.isStreaming {
    self.streamingSessionKey = sessionKey
}
```

If two background sessions start while `isStreaming == false`, the **first** one wins. The second background session won't update `streamingSessionKey` because after the first sets it, `isStreaming` is still `false` (the spec deliberately does NOT set `isStreaming = true` for background sessions).

Wait — actually, re-reading more carefully: `isStreaming` remains `false` for background sessions (the spec explicitly says "Do NOT set `isStreaming = true`"). So if a second background session arrives, `!self.isStreaming` is still `true`, and `streamingSessionKey` gets **overwritten** to the second session's key. This means only the **last** background session is tracked, not the first.

The spec's "Scenarios Verified" table says "Only last one tracked (if `!isStreaming`)" for the "Before" column, but for "After" it says "First one tracked; subsequent ones just increment unread". This is **incorrect** — the `!isStreaming` guard does NOT prevent overwriting because `isStreaming` stays `false` for background sessions. Every background session that starts while no foreground stream is active will overwrite `streamingSessionKey`.

**Is this acceptable?** Partially. If the user switches to the topic for session A (which was overwritten by B), `isStreamingSession(key)` will return `false` because `streamingSessionKey` now points to B. The user won't get catch-up for A. However:

- A was already a background session — the user wasn't looking at it.
- The spec acknowledges this as a known limitation in a future sprint ("Fix B2 — multi-stream tracking with `Set<String>`").
- In practice, simultaneous background streams are rare.

**Verdict:** The behavior is acceptable for this fix, but the "Scenarios Verified" table has an error. It should say "Last one tracked" not "First one tracked" for the After column.

**Action:** Fix the scenario table. Consider adding a brief comment in the code:

```swift
// Note: if multiple background sessions start while nothing is streaming,
// the last one wins for streamingSessionKey. Multi-session tracking
// requires Set<String> — tracked as future Fix B2.
if !self.isStreaming {
    self.streamingSessionKey = sessionKey
}
```

---

## 5. `didStopStreaming` — nil `streamingSessionKey` and empty-string comparison

The "After" code for `didStopStreaming`:

```swift
if self.normalizedSessionKey(self.streamingSessionKey ?? "") == normalizedIncoming {
```

If `streamingSessionKey` is `nil`, this becomes `normalizedSessionKey("") == normalizedIncoming`.

`normalizedSessionKey` strips the `agent:main:` prefix and lowercases. For `""`:
- `SessionKeyNormalizer.stripPrefix("")` → `""` (nothing to strip)
- `.lowercased()` → `""`

So we compare `"" == normalizedIncoming`. For any real session key like `agent:main:abc123` or `abc123`, `normalizedIncoming` will be `"abc123"`. The comparison `"" == "abc123"` is `false`.

**This is correct.** When `streamingSessionKey` is `nil`, the condition is `false`, so we fall through to the `else if` branch (background session that wasn't being tracked), which just logs. No state corruption.

**One edge case:** What if `normalizedIncoming` is also `""` (i.e., someone calls `didStopStreaming(sessionKey: "")`)? Then `"" == ""` is `true`, and `resetStreamingState()` fires. This would only happen with a bug upstream, and resetting state is a safe degradation — the app recovers to idle.

**No issue here. The nil case is handled correctly.**

---

## 6. Order of `selectTopic` / `clearUnread` / `catchUpStreaming` in `sidebarSelection`

The "After" code:

```swift
messageViewModel.selectTopic(id: id)
let newSessionKey = messageViewModel.selectedTopic?.sessionKey
syncBridgeObserver.currentSelectedSessionKey = newSessionKey
syncBridgeObserver.clearUnread(for: newSessionKey)
if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key) {
    syncBridgeObserver.catchUpStreaming(for: key)
}
```

**Could `selectTopic` change `isStreamingSession`'s result?**

`selectTopic` is on `MessageViewModel` — it changes which topic is selected. `isStreamingSession` compares `streamingSessionKey` with the provided key. `selectTopic` doesn't touch `streamingSessionKey` or `isStreaming`.

`clearUnread` modifies `unreadCounts` — no effect on `isStreamingSession`.

So the order doesn't matter for correctness. However, the order is logically clean: select topic → update session key → clear unread → catch up streaming. This is fine.

**Could there be side effects?** `selectTopic` triggers `@Observable` updates which may cause SwiftUI to re-render. The `catchUpStreaming` call happens synchronously in the same `Binding` setter, so it runs before any SwiftUI re-render cycle. No race condition.

**No issues.**

---

## 7. Race: user switches to streaming topic, `catchUpStreaming` starts poll, then `didStopStreaming` arrives before poll fetches content

This is a real scenario:

1. Background stream is running for session X.
2. User switches to topic X.
3. `catchUpStreaming` sets `thinkingState = .streaming`, `isStreaming = true`, starts poll + timeout.
4. `didStopStreaming(sessionKey: X)` fires (gateway finished streaming).
5. In the "After" code, `normalizedSessionKey(self.streamingSessionKey ?? "") == normalizedIncoming` → true (both are X).
6. `resetStreamingState()` fires → state goes to idle, poll cancels.
7. The poll may have fetched 0 or some content.

**What the user sees:** A brief flash of streaming indicator, then it goes idle. The content that was already streamed is in the database (the streaming poll fetches `streamingContent` but messages are persisted by the sync layer). When the topic is selected, `MessageViewModel` loads messages from the database, so the user will see the completed messages.

**Is this acceptable?** Yes. The flash would be very brief (milliseconds between catchUpStreaming and didStopStreaming). The alternative — not calling `catchUpStreaming` — leaves the user stuck with no streaming state at all. A brief flash of "streaming" then "done" is far better than "nothing happening" indefinitely.

**One improvement:** In `catchUpStreaming`, we could check the agent activity tracker to see if the stream is still active before transitioning. But the tracker updates asynchronously, and `didStopStreaming` would still arrive and fix it. No real benefit.

**Verdict: Acceptable behavior. No change needed.**

---

## Summary of Required Changes

| # | Issue | Severity | Action |
|---|-------|----------|--------|
| 1 | Spec "Before" blocks omit source comments | Low | Update spec for accuracy |
| 4 | Scenario table says "First one tracked" but it's actually "Last one tracked" | Medium | Fix table, add code comment |
| 2,3,5,6,7 | No issues | — | — |

---

## Verdict: **APPROVE WITH CHANGES**

The fix is sound. The logic compiles, handles nil cases correctly, has safe ordering, and the race condition in #7 is acceptable. Two items to address before implementation:

1. Fix the "Scenarios Verified" table — background sessions overwrite `streamingSessionKey` (last wins, not first) when `isStreaming == false`.
2. Add a brief comment in the `!self.isStreaming` branch noting the last-wins behavior and the future `Set<String>` fix.

Optional but recommended: update the spec "Before" blocks to include the actual source comments for accurate documentation.