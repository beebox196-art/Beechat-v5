# Kieran — Independent RCA: Sporadic Sidebar Unread Marker (2026-09-08)

**Reviewer:** Kieran (independent, adversarial)
**Scope:** Read-only diagnosis. No code edits, no build, no commit.
**Subject:** BeeChat sidebar thread list — unread dot does not always appear when Bee replies in a topic thread. Sporadic.
**Source of bug report:** Adam (verbal, summarised by Bee). BeeChat is primary comms — must NOT touch working code without a tight hypothesis.

---

## Files Examined

| File | Why |
|---|---|
| `Sources/App/UI/Components/SessionRow.swift` | Renders the unread dot. Single condition: `if unreadCount > 0`. |
| `Sources/App/UI/MainWindow.swift` | Sidebar `ForEach` reads `syncBridgeObserver.unreadCounts[normalizedKey]`. Also owns the sidebar selection `Binding` setter — the **only** place that updates `currentSelectedSessionKey` and clears unread on click. |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | The `@Observable` class. Holds `unreadCounts: [String: Int]`, `currentSelectedSessionKey: String?`. `didStartStreaming` increments the counter **only** for sessions that don't match `currentSelectedSessionKey` after normalisation. `didStopStreaming` does **not** decrement. |
| `Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift` | `stripPrefix(_:)` + lowercase. Centralised normalisation. |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` (lines ~1115–1230) | Where `didStartStreaming` is fired. Both `processChatDelta` and `processAgentEvent` fire it on the first delta per session, via `streamingSessionKeys` Set. |
| `Sources/App/UI/ViewModels/TopicViewModel.swift` | Holds `unreadCount: Int` (from `Topic.unreadCount`, the **DB column**) — separate from the in-memory dictionary read by the sidebar. Currently unused by the sidebar. |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` (lines 64–85, 90–101) | `updateTopics(from:)` auto-selects `topics.first?.id` when prior selection vanishes. Bypasses the sidebar binding setter. |

## Recent History Worth Knowing

- **2026-05-06 — `e4e9f77`** — *"fix: normalise session key before unread-count lookup in sidebar"*. The exact same class of bug was fixed once already. Sidebar used raw `topic.sessionKey`; observer stored normalised keys → looked-up always missed. **The fix is in place and the dedupe is now consistent.** This is a known fault line.
- **2026-06-16 — `94164d3`** — *Mark as Unread* context-menu item added. Touches the same code paths (`setUnread`, the dict).
- **2026-08-07** — Latest web-transcript work. No sidebar/unread code change since the May fix.

---

## Ranked Root-Cause Hypotheses

> Ordering reflects **likelihood × blast-radius**. Lower number = more likely.

### 1. (Highest) `currentSelectedSessionKey` goes stale — multiple selection paths bypass the binding setter

**Where:** `Sources/App/UI/MainWindow.swift:48–62` is the *only* writer of `syncBridgeObserver.currentSelectedSessionKey`. It runs from the sidebar `Binding<String?>` setter.

**Selection paths that DO NOT update it:**

| Path | Where | Effect |
|---|---|---|
| New-topic creation sets `messageViewModel.selectedTopicId = newTopic.id` | `MainWindow.swift:584` | Observer still thinks previous session is current. |
| `updateTopics(from:)` falls back to `topics.first?.id` after the prior selection disappears | `MessageViewModel.swift:82` | Observer still thinks deleted topic is current. |
| Archived-toggle cleanup sets `selectedTopicId = nil` if selection was archived | `MainWindow.swift:560` | Observer still thinks archive target is current. |
| App launch — first `updateTopics(from:)` runs before any user interaction | implicit (initial state) | `currentSelectedSessionKey` is `nil` until the user clicks the sidebar once. |

**Failure mode:** When Bee replies in topic T after one of the paths above has shifted `selectedTopicId`, the observer compares `normalize(incoming)` against a stale `currentSelectedSessionKey`. Depending on direction of staleness:

- If stale key happens to equal incoming key (coincidence), the increment is **skipped** → marker missing for the topic the user is actually on.
- If stale key is for a now-deleted topic, the increment fires against the wrong session but doesn't harm the user-facing topic T.

**Why "sporadic":** it depends on which selection path was last taken, the order of GRDB ValueObservation updates vs. user clicks, and whether the new topic has the same normalised key as the stale one.

**Confidence:** 0.7 (high). The invariant "the sidebar binding setter is the single writer of `currentSelectedSessionKey`" is provable from the code. There are at least 4 bypass sites. This is precisely the shape of a sporadic issue.

---

### 2. (Strong) Race between `nonisolated → @MainActor` Task hop and the user's selection click

**Where:** `SyncBridgeObserver.swift:82–99` — `didStartStreaming` is `nonisolated` and does:

```swift
Task { @MainActor in
    let normalizedIncoming = self.normalizedSessionKey(sessionKey)
    let normalizedCurrent = self.currentSelectedSessionKey.map(self.normalizedSessionKey)
    ...
    if normalizedIncoming != normalizedCurrent {
        self.unreadCounts[normalizedIncoming, default: 0] += 1
    }
}
```

**Failure mode:** Between the streaming event arriving on a background thread and the `@MainActor` task running, the user can click a different topic. The click updates `currentSelectedSessionKey` *before* the task runs → the task sees `normalizedIncoming == normalizedCurrent` and skips the increment, even though the user wasn't watching the reply when it started.

In other words: **the decision to mark unread is deferred by one MainActor hop, during which the user's selection can change.** A click that arrives in the gap suppresses the marker. A click that arrives before the event doesn't.

**Why "sporadic":** race window is ~few ms; happens when the click is fast enough to land in the gap, slow enough to land after the event fires. User's perception is "I clicked on it to look, the marker never appeared" — but the marker was correctly cleared because they were now on the topic.

**Confidence:** 0.55 (medium-high). The race is provable from the code; the timing depends on event volume and click latency. This is exactly the kind of issue that reads as "random".

---

### 3. (Medium) App-restart amnesia hides a real marker that should have been there

**Where:** `SyncBridgeObserver.swift:271` — comment says *"Lost on app restart (acceptable for a visual indicator)"*. The dict is in-memory only.

**Failure mode:** Bee replied in topic T during session A. User closed app. User opened app session B. Topic T shows no marker because the in-memory dict is empty. The Bee reply is in the message history, so the topic may also auto-load and show the reply (no marker needed). But if the user has *not* yet opened T (e.g., they were on a different topic), the message list for T is not fetched → the sidebar dot would be the only signal that there's a new Bee message waiting. That signal is missing.

**Why "sporadic":** only after a restart. So if Adam noticed the issue more often than once-per-restart, this isn't the explanation. But it's worth ruling out before chasing harder bugs.

**Confidence:** 0.3. Likely contributing rather than primary.

---

### 4. (Lower) `unreadCounts` increment is monotonic — no idempotency guard, and `didStartStreaming` can fire twice on a session

**Where:** `SyncBridge.swift:1123–1132` and `processAgentEvent` at line ~1196. `didStartStreaming` fires on the **first delta** of a streaming session, gated by `streamingSessionKeys` membership. If a session's stream is finalised (`processChatFinal` removes from the set) and a new stream later starts on the same key, `didStartStreaming` fires again. The observer increments `unreadCounts` again.

**Failure mode:** This would cause the *opposite* symptom — marker appears that shouldn't, or marker persists longer than expected. Not the reported symptom.

**Confidence:** 0.1. Mentioned for completeness; wrong direction.

---

### 5. (Low) SwiftUI `@Observable` dictionary-mutation invalidation

`@Observable` macro tracks property reads. The `ForEach` body reads `syncBridgeObserver.unreadCounts[normalizedKey]`. All rows that read the dict will re-evaluate on any mutation to the dict (value-type `Dictionary` mutation triggers property-level tracking). This **should** propagate correctly in current Swift/SwiftUI.

**Confidence:** 0.05. Listed only because some `@Observable` + `LazyVStack`/`List` combos have had invalidation quirks. Would require running the app to confirm or rule out. Lower priority than 1, 2, 3.

---

### 6. (Very Low) Session-key normalisation drift between writer and reader

The May 2026 fix (`e4e9f77`) unified the normalisation between writer and reader. Code reads consistent — `SessionKeyNormalizer.stripPrefix(key).lowercased()` is used on both sides. No drift visible.

**Confidence:** 0.02. Ruled out.

---

## Concerns About the Fix Path

BeeChat is primary comms. Whatever the fix is, it must:

1. **Not break the working `didStartStreaming → increment → cleared-on-click` happy path.** This is verified by Adam's observation that the marker *sometimes* appears — i.e., the path works at all.

2. **Not introduce a regression in the streaming UI** (ThinkingBee spinner, catch-up logic in `catchUpStreaming(for:)`). The catch-up path is keyed off the same `isStreamingSession` predicate. Any fix to `currentSelectedSessionKey` must not desynchronise the streaming state machine.

3. **Be observable while it's being verified.** Hypothesis 1 and 2 are both time-sensitive. Adam should be able to:
   - **Trigger the bug deliberately** — e.g., select topic X, mark-as-unread topic Y, send a message in Y while on X, click Y to clear — and then describe whether the marker fired correctly.
   - **Capture log lines** at the moment of the bug. `BeeChatLogger.log("[ThinkingBee] didStartStreaming — mismatch (...) — counting unread")` already prints `currentSelectedSessionKey` at the moment of decision. If we add a second `BeeChatLogger.log` line on the **select** side (`let newSessionKey = messageViewModel.selectedTopic?.sessionKey`) showing the same fields, we can correlate.

4. **Avoid scope creep.** The simplest correct fix for Hypothesis 1 is one-line: also update `currentSelectedSessionKey` inside `MessageViewModel.selectedTopicId`'s setter (e.g., via `didSet` on a computed bridge, or by moving the update to a single observation in `MainWindow` that watches `selectedTopicId`). For Hypothesis 2, capture the *decision-time* `currentSelectedSessionKey` on the background thread before hopping to `@MainActor` (read it in the `nonisolated` method via a `MainActor.assumeIsolated` or by passing it as a snapshot).

5. **Test surface is currently absent.** I saw no tests for `SyncBridgeObserver.unreadCounts`. Any fix should add a unit test that exercises the 4 bypass paths in Hypothesis 1 — otherwise we re-discover this in six months.

6. **Don't touch the existing `selectTopic` or `clearUnread` signatures.** Both are reached from multiple call sites and have been reviewed previously. The Kieran Critical-3 fix (Hashable / Equatable) on `TopicViewModel` is recent and unrelated; do not entangle.

## Recommended Diagnostic Next Step (no code change)

Ask Adam to capture the next ~10 occurrences with the following:

- Open Console.app, filter on `BeeChat` and `ThinkingBee`.
- Reproduce by sending Bee a message in topic T while currently looking at a *different* topic S.
- Note in a one-liner whether the marker appeared.
- If possible, also report whether the same session was already streaming (the `if !self.isStreaming` branch in the observer matters).

If 8+ out of 10 misses correlate with one of: (a) app launch as the first action, (b) topic auto-selected after a delete, or (c) clicking S while Bee's reply for T was just beginning — we have direct evidence for Hypothesis 1 or 2 and can pick a targeted fix.

If misses do **not** correlate with those states, Hypothesis 3 (restart amnesia) or 5 (`@Observable` invalidation) rise in priority and need a different instrumented build.

---

## Summary

- **Primary suspect:** Stale `currentSelectedSessionKey` in `SyncBridgeObserver`, updated only from one Binding setter that several selection paths bypass.
- **Secondary suspect:** `nonisolated → @MainActor` race window in `didStartStreaming` letting a fast user click suppress the unread increment.
- **No code changes proposed in this note.** Review-only as instructed. The hypothesis above is enough to scope a one-line fix on either branch, but Adam's observation data should pin it down before we touch working code.
