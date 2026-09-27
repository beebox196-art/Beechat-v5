# RCA — Sporadic Sidebar Unread Marker (Topic Threads)

**Date:** 2026-09-08
**Author:** Q (Senior Developer), sub-agent of Bee
**Symptom Reporter:** Adam (via Bee, Telegram topic thread)
**Severity:** Cosmetic / UX (no data loss, no functional regression)
**Scope:** Sidebar unread badge against topic threads in `SessionRow`
**Status:** Diagnosis only — **no code changes proposed in this RCA** (per Adam's "don't touch working code" rule). Fix spec follows in §6 for team review.

---

## 1. Symptom

> When Bee replies in a topic thread, the blue unread marker does **NOT always** appear against that thread in the sidebar. Sometimes it does, sometimes it doesn't — sporadic.

- The unread marker is the small accent-coloured circle in the topic row (between the topic title and the optional session-reset amber dot).
- It is driven entirely by an **in-memory** `unreadCounts: [String: Int]` dictionary held in `SyncBridgeObserver`. It is **not** persisted to the database (lost on restart, which is the intentional design).
- There is **no persistence fallback** — `Topic.unreadCount` exists in the model and schema, but is **never written** and **never read** by the sidebar. The badge comes from the in-memory dictionary only.

---

## 2. Where the marker is rendered

| Concern | Location |
|---|---|
| View rendering the badge | `Sources/App/UI/Components/SessionRow.swift` — `if unreadCount > 0 { Circle().fill(...) }` (line 67). |
| `unreadCount` is passed in from the parent. | `Sources/App/UI/MainWindow.swift` — `let unreadCount = syncBridgeObserver.unreadCounts[normalizedKey] ?? 0` (line 719), where `normalizedKey = topic.sessionKey.map { SessionKeyNormalizer.stripPrefix($0).lowercased() } ?? ""`. |
| Dictionary is mutated from `SyncBridgeObserver`. | `Sources/App/UI/Observers/SyncBridgeObserver.swift`. |

The display condition is a single integer greater than zero. If `unreadCounts[normalizedKey]` is `nil`, the row shows no badge.

---

## 3. How `unreadCounts` gets populated

There are **only three** write paths to `unreadCounts` in the entire codebase (`grep -rn "unreadCounts"`):

| Path | Where | Mutator |
|---|---|---|
| **Auto-increment** on background-stream start | `SyncBridgeObserver.swift:95` | `self.unreadCounts[normalizedIncoming, default: 0] += 1` — inside `didStartStreaming` when `normalizedIncoming != normalizedCurrent` (the user is on a different topic) |
| **Set** (Mark as Unread context menu) | `SyncBridgeObserver.swift:289` | `unreadCounts[normalized] = count` from `setUnread(for:count:)` |
| **Clear** on topic select | `SyncBridgeObserver.swift:280`, `:291` | `unreadCounts.removeValue(forKey: ...)` |

There is **no** other auto-increment path. There is **no** message-arrival-driven counter. The badge depends entirely on the `didStartStreaming` callback producing a "background session" mismatch.

---

## 4. Where the "selection comparison" comes from

`SyncBridgeObserver.didStartStreaming` decides "is this a background session?" by comparing the incoming stream's session key to a single field: `currentSelectedSessionKey` (`SyncBridgeObserver.swift:88`):

```swift
let normalizedIncoming = self.normalizedSessionKey(sessionKey)
let normalizedCurrent   = self.currentSelectedSessionKey.map(self.normalizedSessionKey)
if normalizedIncoming != normalizedCurrent {
    self.unreadCounts[normalizedIncoming, default: 0] += 1   // ← the only auto-bump
    ...
    return
}
// Active topic — full UI transition (no unread increment)
self.isStreaming = true
self.streamingSessionKey = sessionKey
...
```

`currentSelectedSessionKey` is written in **exactly one place**: the `sidebarSelection` setter in `MainWindow.swift:57`. It is **never cleared** (no `= nil` anywhere in the codebase — `grep -rn "currentSelectedSessionKey\s*=\s*nil"` returns nothing).

This is a fragile invariant — see Hypothesis 2 below.

---

## 5. Ranked hypotheses

### Hypothesis 1 — **HIGH probability** — Missing `didStartStreaming` for non-streaming replies

**Claim:** Some Bee replies reach `SyncBridge` without ever firing `didStartStreaming`, so the unread count is never bumped. The frequency depends on which event the gateway chose to send, which varies.

**Evidence:**

The bridge receives messages through **two distinct gateway event paths**:

1. **`chat` events** (streaming path) — `EventRouter.swift:16`, `handleChatEvent`
   - `state == "delta"` → `processChatDelta` → fires `didStartStreaming` **on the first delta** only (`SyncBridge.swift:1132`).
   - `state == "final"` → `processChatFinal` → fires `didStopStreaming` after a successful `streamingSessionKeys.remove(sessionKey)` (idempotency guard).
   - When both arrive, the badge logic works.

2. **`session.message` events** (settled / non-streaming path) — `EventRouter.swift:19`, `handleSessionMessage` (`EventRouter.swift:86–114`)
   - When the role is `"assistant"`, the router calls `processChatFinal(sessionKey:)` **directly**, with no preceding `processChatDelta`.
   - `processChatFinal` (`SyncBridge.swift:1142–1161`) begins with:
     ```swift
     guard streamingSessionKeys.remove(sessionKey) != nil else {
         print("[SyncBridge] processChatFinal: already finalized, skipping \(sessionKey)")
         return
     }
     ```
   - Because `session.message` for this session was never preceded by a `chat.delta`, `streamingSessionKeys` does **not** contain the key. `remove` returns `nil`. The function **returns early** without firing any delegate event — no `didStartStreaming`, no `didStopStreaming`, **no unread increment**.

**Why this matches the symptom:**
- When Bee streams (long-form answers) → `chat.delta` → `chat.final` → badge appears ✓
- When Bee replies via `session.message` directly (short / non-streaming / replayed / post-final settled record) → `processChatFinal` short-circuits → badge does **not** appear ✗
- The mix of paths explains the **sporadic** behaviour — the badge appears for streamed replies and disappears for settled ones.

**Supporting context:**
- `AgentActivityTracker.minimumActivityDuration = 2.0` (`SyncBridgeObserver.swift` line ~412) — the code itself acknowledges streams shorter than 2 seconds are treated as "heartbeat noise". Heartbeats and other short events likely arrive via the `session.message` path.
- The `// Gateway 4.29 no longer sends chat final.` comment in `EventRouter.swift:104` indicates the gateway has been shifting its event-emission model. As the gateway moves more message delivery onto `session.message`, the bug **will get worse** over time.

**Counter-evidence / boundary:** If every reply were a `session.message` with no prior `chat.delta`, the badge would **never** appear — but Adam says it *sometimes* appears, which is consistent with a path mix rather than a path replacement.

---

### Hypothesis 2 — **MEDIUM probability** — `currentSelectedSessionKey` is stale relative to `messageViewModel.selectedTopicId`

**Claim:** `currentSelectedSessionKey` is only updated by the `sidebarSelection` setter (`MainWindow.swift:57`), but `selectedTopicId` is updated by **several other paths** that bypass the setter:

| Path | File:line | Effect |
|---|---|---|
| Initial topic selection from GRDB observation | `MessageViewModel.swift:82` — `selectedTopicId = self.topics.first?.id` (in `updateTopics(from:)`) | `currentSelectedSessionKey` stays `nil` until first user click |
| New topic auto-select | `MessageViewModel.swift:248` — `selectedTopicId = topic.id` (in `addTopic`) | Same |
| Cascade after delete | `MessageViewModel.swift:255` — `selectedTopicId = topics.first?.id` | Same |
| Archived→Active switch | `MainWindow.swift:560` — `messageViewModel.selectedTopicId = nil` | Same |
| New topic created | `MainWindow.swift:584` — `messageViewModel.selectedTopicId = newTopic.id` | Same |

**Why this matches the symptom:** If the user is "on" Topic A (per `selectedTopicId` and the sidebar UI) but `currentSelectedSessionKey == nil` (because the selection was set programmatically, never by clicking), then a Bee reply to Topic A will see `normalizedIncoming != nil` → it is treated as **background** → `unreadCounts[A] += 1` → badge appears **when it shouldn't** (user is on A).

The mirror case — user clicks a topic, then `selectedTopicId` is reassigned programmatically to that same topic — produces **no bug** because the setter still ran on the original click. But the asymmetry between "selectedTopicId changed by user click" and "selectedTopicId changed programmatically" is the root cause of the state-drift class of bugs.

**Counter-evidence / boundary:** This hypothesis predicts *wrong* badge state (badge when it shouldn't appear), not *missing* badge state. It is plausible as a contributing factor (state gets reset to `nil` somewhere?) but does not on its own explain Adam's symptom of a *missing* badge on an autonomous Bee reply.

---

### Hypothesis 3 — **LOW–MEDIUM probability** — Race between topic click and stream-start Task

**Claim:** SwiftUI's `sidebarSelection` setter (`MainWindow.swift:49–63`) does several things synchronously on the main actor: `selectTopic`, `currentSelectedSessionKey = …`, `clearUnread`, optionally `catchUpStreaming`. The `didStartStreaming` callback, however, is dispatched via `Task { @MainActor in … }` (`SyncBridgeObserver.swift:84`), so it is **async-queued** even though it targets the same actor.

In a tight race — user clicks Topic B while a `didStartStreaming` Task for Topic B is already queued — the setter runs *first* on the current runloop tick, sets `currentSelectedSessionKey = B`, then the queued Task runs and sees `normalizedIncoming == normalizedCurrent` → goes down the "active topic" branch → no unread bump. The user would have expected a badge because Bee is autonomously responding to B (the user just clicked it, but Bee's response was already in flight). This would only fire in the narrow window between "click happens" and "stream begins" — hence sporadic.

**Counter-evidence:** Adam's description is "Bee replies" → badge missing. He did not describe a click-during-reply timing pattern. This hypothesis is plausible but unconfirmed.

---

### Hypothesis 4 — **LOW probability** — Background sessions share `streamingSessionKey`

**Claim:** `didStartStreaming` for background sessions only stores `streamingSessionKey` "if `!isStreaming`" (`SyncBridgeObserver.swift:99`). If two background sessions start while `isStreaming == true`, the *second* one is **not** tracked. This affects later `didStopStreaming` cleanup, not the `unreadCounts` increment itself — the increment still happens unconditionally inside the `if normalizedIncoming != normalizedCurrent` block. So this is not the missing-badge root cause, but it is a known sibling bug (the codebase already labels it "future Fix B2" in `SyncBridgeObserver.swift:101`).

**Counter-evidence:** Does not directly explain missing badge.

---

### Hypothesis 5 — **VERY LOW probability** — `unreadCounts` normalisation mismatch

**Claim:** Badge lookup uses `SessionKeyNormalizer.stripPrefix(...).lowercased()`. `didStartStreaming` uses `normalizedSessionKey(...)` which does the same. `setUnread` and `clearUnread` also normalise the same way. There is a single normalisation contract (`SessionKeyNormalizer.swift`). This appears consistent across all sites.

**Counter-evidence:** Single consistent normalisation; no off-by-one or case-sensitivity divergence found.

---

## 6. Proposed fix (SPEC ONLY — not applied)

The recommended approach is **two layers of fix**: one minimal, one structural. Either alone is acceptable; both together are recommended.

### Fix A (minimal) — Fire the unread bump from a delegate-agnostic message-arrival path

Make the unread counter respond to **any assistant message arriving**, not just streaming-start events. This closes the `session.message` gap (Hypothesis 1) regardless of which gateway path delivered the message.

**Where to add the hook:** `SyncBridgeObserver` should receive a `didReceiveMessage(message: Message)` delegate callback from `SyncBridge`. The callback fires from **both** event paths:

| Path | Hook location |
|---|---|
| `chat.final` (after `processChatFinal` succeeds) | `SyncBridge.swift:1159` (just before the existing `didStopStreaming`) |
| `session.message` (assistant role) | `EventRouter.swift:113` (just before `processChatFinal`), and again after the `processChatFinal` short-circuit (currently silent) — for the case where `streamingSessionKeys` did not contain the key, still fire `didReceiveMessage` so the unread bump happens |

**Increment rule (mirrors the existing one):**
```swift
let normalizedIncoming = normalizedSessionKey(message.sessionId)
let normalizedCurrent   = currentSelectedSessionKey.map(normalizedSessionKey)
guard normalizedIncoming != normalizedCurrent else { return }
unreadCounts[normalizedIncoming, default: 0] += 1
```

**Why not the existing `didStartStreaming`?** Because `didStartStreaming` is not guaranteed to fire (Hypothesis 1). The arrival of an assistant message is the actual semantic event the badge should reflect.

### Fix B (structural) — Make `currentSelectedSessionKey` authoritative

Bind `currentSelectedSessionKey` to `messageViewModel.selectedTopicId` via `onChange` in `MainWindow.swift`, so any change to selection — programmatic or user-driven — is reflected:

```swift
.onChange(of: messageViewModel.selectedTopicId) { _, newId in
    let newSessionKey = messageViewModel.topics.first(where: { $0.id == newId })?.sessionKey
    syncBridgeObserver.currentSelectedSessionKey = newSessionKey
    syncBridgeObserver.clearUnread(for: newSessionKey)
}
```

Remove (or keep-but-redundant) the equivalent lines in the `sidebarSelection` setter. Add a unit test that drives `messageViewModel.selectedTopicId = X` directly and asserts `currentSelectedSessionKey` updates.

### Testing plan (for the eventual fix)

1. **Repro the sporadic case.** Send a message to Topic A, switch to Topic B, force a non-streaming reply to A (e.g. short heartbeat-style message), confirm badge now appears on A reliably. Repeat with `session.message`-only delivery if the gateway exposes a test trigger.
2. **State-drift test.** Programmatically set `messageViewModel.selectedTopicId = X` without invoking the sidebar setter, confirm `currentSelectedSessionKey` updates.
3. **Backward compat.** Verify the existing `Mark as Unread` context menu still works (it calls `setUnread` directly — should be unaffected).
4. **VoiceOver.** Confirm accessibility label still announces "unread" when the badge is on (the `accessibilityLabel` in `SessionRow` is already driven by `unreadCount`).
5. **Restart behaviour.** Document and confirm that unread markers are lost on app restart (the in-memory design is intentional; do not change).

### Rollback plan

Single revert per fix. `unreadCounts` is in-memory only; no DB migration is needed.

### Risks

| Risk | Mitigation |
|---|---|
| Double-counting (Fix A): `chat.final` + `session.message` both fire for the same message | Dedup on `message.id` (already exists in `EventRouter.swift:101` — reuse pattern) |
| `didReceiveMessage` fires for messages the user has already seen because they were watching the stream complete | Don't fire on `chat.final` when the stream was the *active* topic — same comparison rule as today |
| Threading — `didReceiveMessage` must mutate `unreadCounts` on the main actor | Follow the existing `nonisolated func … Task { @MainActor in … }` pattern |

---

## 7. Recommendation

**Fix A is the primary fix.** It directly addresses Adam's symptom (badge missing on non-streamed replies) and is a small, well-contained change. **Fix B is recommended as a follow-up** to close the state-drift class of bugs that will keep producing weird UX regardless of Fix A.

---

## 8. Files examined

| File | Purpose |
|---|---|
| `Sources/App/UI/Components/SessionRow.swift` | Badge rendering rule (`unreadCount > 0`) |
| `Sources/App/UI/MainWindow.swift` | Sidebar wiring; `sidebarSelection` setter; `onChange(of: selectedTopicId)` |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | `unreadCounts` dictionary; `didStartStreaming` / `didStopStreaming`; `setUnread` / `clearUnread`; `currentSelectedSessionKey` |
| `Sources/App/UI/Observers/MessageListObserver.swift` | Confirmed unrelated to unread (out-of-scope confirmation) |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` | `selectTopic`, `updateTopics`, `addTopic`, `removeTopic`, `sendMessage` — all the `selectedTopicId = …` write sites |
| `Sources/App/UI/ViewModels/TopicViewModel.swift` | Confirmed `TopicViewModel.unreadCount` is initialised from `Topic.unreadCount` but never read by the sidebar |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | `processChatDelta`, `processChatFinal`, `processChatError`, `processAgentEvent`, `clearStalledStream`; the `streamingSessionKeys.remove(...)` idempotency guard |
| `Sources/BeeChatSyncBridge/EventRouter.swift` | `handleChatEvent`, `handleSessionMessage`, `handleAgentEvent`, `handleSessionsChanged` — the gateway event dispatch |
| `Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift` | Confirmed `stripPrefix` is the single normalisation contract used everywhere |
| `Docs/Specs/Archive/UNREAD-INDICATOR-SPEC.md` | Historical spec (April 2026, draft) for the same feature — proposed a DB-trigger approach that was **not** the implementation path actually taken |
| `STATUS.md` (lines 61, 111, 164) | "Mark as Unread (sidebar indicator)" shipped commit `94164d3` (Jun 16 2026); Kieran review still pending |

---

## 9. Diagnostic logging suggested (for team to add before re-running)

To turn the next occurrence into a definitive trace rather than a guess, add temporary logging at:

- `SyncBridge.swift:1142` (top of `processChatFinal`) — log `streamingSessionKeys.contains(sessionKey)` before the guard.
- `EventRouter.swift:107` (in `handleSessionMessage`) — log `sessionKey`, `role`, and whether `streamingSessionKeys.contains(sessionKey)` on the bridge.
- `SyncBridgeObserver.swift:88` (top of `didStartStreaming`) — log `currentSelectedSessionKey` and `streamingSessionKey` for every call.

These logs would let the team see in production whether Hypothesis 1 fires (`streamingSessionKeys.contains == false` at the top of `processChatFinal`), Hypothesis 2 fires (`currentSelectedSessionKey` is `nil` while the sidebar shows a selection), or neither.

---

**END OF RCA — diagnosis only, no code edits made.**
