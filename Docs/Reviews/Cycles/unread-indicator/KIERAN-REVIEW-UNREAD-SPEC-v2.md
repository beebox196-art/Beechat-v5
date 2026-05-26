# Kieran Review: Sidebar Unread Indicator v2

**Reviewer:** Kieran (independent)
**Date:** 2026-04-29
**Spec:** UNREAD-INDICATOR-SPEC-v2.md
**Verdict:** NEEDS CHANGES

---

## Overall Assessment

The v2 approach (in-memory tracking via `didStartStreaming`) is fundamentally sound and correctly avoids the v1 reconciliation inflation problem. The scope is narrow and the risk profile is low. However, there are **two wiring gaps** and **one dead-code risk** that must be resolved before implementation.

---

## Review Point 1: Existing Code Impact

**Finding: SAFE — no existing code paths are modified.**

Adding `unreadCounts: [String: Int]` and `currentSelectedSessionKey: String?` as new properties on `SyncBridgeObserver` is purely additive. The `didStartStreaming` implementation adds an `if` block *after* all existing logic (`isStreaming`, `streamingSessionKey`, `thinkingState`, `startStreamingPoll()`, `startStreamingTimeout()`). No existing lines are changed, reordered, or removed.

`didStopStreaming` is untouched. `resetStreamingState()` is untouched. The streaming poll task and timeout safety net are untouched.

**Verdict: No risk to existing streaming flow.**

---

## Review Point 2: `currentSelectedSessionKey` Wiring

**Finding: GAP — the spec says "set it from MainWindow" but doesn't show how.**

There are two sub-issues:

### 2a. Where to set it

`MessageViewModel.selectTopic(id:)` does **not** have a reference to `SyncBridgeObserver`. The `MessageViewModel` only holds `private weak var syncBridge: SyncBridge?`. So the spec's instruction to "set it from MainWindow when selectTopic is called" needs clarification on *where* the assignment happens.

**Two options:**

- **Option A (preferred):** Set `syncBridgeObserver.currentSelectedSessionKey` in `MainWindow`'s `sidebarSelection` binding, right after `messageViewModel.selectTopic(id:)` is called. This requires resolving the topic's `sessionKey` from the topics array. This keeps `MessageViewModel` decoupled from `SyncBridgeObserver`.

- **Option B:** Inject `SyncBridgeObserver` into `MessageViewModel` (e.g., via `start(syncBridge:)` or a new setter). This adds coupling that doesn't currently exist.

**Recommendation: Option A.** The `sidebarSelection` binding in `MainWindow` already has access to both `messageViewModel` and `syncBridgeObserver`. The wiring looks like:

```swift
Binding(
    get: { messageViewModel.selectedTopicId },
    set: { newId in
        if let id = newId, id != messageViewModel.selectedTopicId {
            messageViewModel.selectTopic(id: id)
            // NEW: tell observer which topic is now selected
            syncBridgeObserver.currentSelectedSessionKey = 
                messageViewModel.topics.first { $0.id == id }?.sessionKey
        }
    }
)
```

### 2b. What happens when nil (app launch)

On app launch, before any topic is selected, `currentSelectedSessionKey` is `nil`. The spec's guard:

```swift
if let selectedKey = self.currentSelectedSessionKey, sessionKey != selectedKey {
    self.unreadCounts[sessionKey, default: 0] += 1
}
```

When `currentSelectedSessionKey` is `nil`, the `if let` fails and **no unread is incremented**. This means if a stream starts during the brief window between app launch and first topic selection, it won't count.

**Assessment: Acceptable.** `MessageViewModel.updateTopics()` auto-selects the first topic immediately, so this window is microseconds. Even if a stream fires during it, the user hasn't "left" any topic — there's nothing to mark as unread.

---

## Review Point 3: `didStartStreaming` Fires for All Topics

**Finding: CORRECT — the guard works, but there's a subtle edge case.**

`didStartStreaming` fires for **every** assistant response, including the one in the currently selected topic. The guard `sessionKey != currentSelectedSessionKey` correctly prevents incrementing for the active topic.

**Edge case to consider:** What if the user switches topics rapidly (Topic A → Topic B → Topic A) while a stream is active? The `currentSelectedSessionKey` is set synchronously on the main actor (same as `didStartStreaming`), so there's no race condition. The serialized main actor execution means the guard always sees the correct current selection.

**Verdict: Safe.**

---

## Review Point 4: SessionRow Parameter Addition

**Finding: SAFE — default parameter value protects existing call sites.**

Adding `var unreadCount: Int = 0` to `SessionRow` means:

- Existing calls in `MainWindow` that don't pass `unreadCount` get `0` by default → no visual change → **identical to current behaviour**.
- The new calls that *do* pass `unreadCount` will show the indicator.

This is standard SwiftUI practice and is safe.

**Verdict: No risk to existing call sites.**

---

## Review Point 5: Removing the Dead `topic.unreadCount > 0` Block

**Finding: RISK — `topic.unreadCount` exists in the data model and is used elsewhere.**

The dead code block in `SessionRow`:

```swift
if topic.unreadCount > 0 {
    Text("\(topic.unreadCount)")
        .font(.caption)
        .foregroundColor(themeManager.color(.textSecondary))
}
```

This block never fires because `Topic.unreadCount` is always 0 (DB default, never written to). However:

- `Topic.unreadCount` is a **database column** (`DatabaseManager.swift:217, 307`)
- `Session.unreadCount` exists and has a write path (`SessionRepository.swift:72`)
- `TopicViewModel.unreadCount` copies from `Topic.unreadCount`

**The risk:** Removing the SessionRow block is fine (it's dead code). But the spec should **not** remove `Topic.unreadCount` from the model or DB — it may be used by other features or future reconciliation logic. The spec only removes the *UI block*, which is safe.

**Verdict: Safe to remove the UI block. Do NOT touch the DB column or model property.**

---

## Review Point 6: Layout/Render Risk

**Finding: LOW RISK — minor width variation possible, no height change.**

`.fontWeight(.semibold)` vs `.regular`:

- **Font weight does not change line height.** The row height stays constant.
- **Font weight can change glyph width.** Semibold glyphs are slightly wider. In a sidebar with `.lineLimit(1)`, this means the title might truncate slightly earlier when unread vs. when read. This is a cosmetic difference, not a bug.
- **Theme compatibility:** `themeManager.font(.body)` returns a `Font`. `.fontWeight()` is a standard SwiftUI view modifier that works on any `Font`. No theme system issues.
- **The blue dot + count** only appear when `unreadCount > 0`, adding elements to the right side of the HStack. This shifts the Spacer's right edge leftward, but the row width is fixed by the sidebar column. The title truncation absorbs this.

**Verdict: No layout breakage risk. Minor cosmetic width variation is acceptable.**

---

## Review Point 7: Clearing Unread — Right Place?

**Finding: GAP — `MessageViewModel` doesn't have access to `SyncBridgeObserver`.**

The spec says to add `syncBridgeObserver?.clearUnread(sessionKey:)` to `MessageViewModel.selectTopic(id:)`. But `MessageViewModel` only has `private weak var syncBridge: SyncBridge?`. It does **not** have a reference to `SyncBridgeObserver`.

**Call chain analysis:**

```
User clicks sidebar row
  → sidebarSelection Binding set(newId)
    → messageViewModel.selectTopic(id: id)
      → selectedTopicId = id
      → startObservationForSelectedTopic()
      → startSessionUsageObservation()
```

The clear call can't go in `MessageViewModel` without adding a dependency. Two options:

- **Option A (preferred):** Put the clear call in `MainWindow`'s `sidebarSelection` binding, alongside the `currentSelectedSessionKey` assignment. Same place, same logic.

- **Option B:** Add `weak var syncBridgeObserver: SyncBridgeObserver?` to `MessageViewModel` and wire it during `start(syncBridge:)`. This adds coupling for a single call.

**Recommendation: Option A.** Keep it in `MainWindow` where both objects are already accessible.

**Additional edge case:** `MessageViewModel.updateTopics()` sets `selectedTopicId` directly (not via `selectTopic`). If the topic list refreshes and the auto-selected topic changes, unread won't be cleared for the newly selected topic. This is a minor edge case — the user hasn't actively "viewed" the topic yet. Acceptable.

---

## Summary of Issues

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | `currentSelectedSessionKey` wiring not specified | Medium | Set in `MainWindow`'s `sidebarSelection` binding |
| 2 | `clearUnread` can't be called from `MessageViewModel` (no reference) | Medium | Move clear call to `MainWindow`'s `sidebarSelection` binding |
| 3 | Spec contains dead/comment code in `didStartStreaming` example | Low | Clean up the spec's code example (remove the first `if` block that's just a comment) |
| 4 | `updateTopics` bypasses `selectTopic` — unread not cleared on auto-select | Low | Acceptable — user hasn't actively viewed the topic |

---

## What Gets Changed in MainWindow

After both fixes, `MainWindow`'s `sidebarSelection` binding becomes:

```swift
private var sidebarSelection: Binding<String?> {
    Binding(
        get: { messageViewModel.selectedTopicId },
        set: { newId in
            if let id = newId, id != messageViewModel.selectedTopicId {
                messageViewModel.selectTopic(id: id)
                // NEW: wire selected key + clear unread
                let sessionKey = messageViewModel.topics.first { $0.id == id }?.sessionKey ?? ""
                syncBridgeObserver.currentSelectedSessionKey = sessionKey
                syncBridgeObserver.clearUnread(sessionKey: sessionKey)
            }
        }
    )
}
```

And the `ForEach` gains the unread count parameter:

```swift
let unreadCount = syncBridgeObserver.unreadCounts[topic.sessionKey ?? ""] ?? 0
SessionRow(
    topic: topic,
    thinkingState: syncBridgeObserver.thinkingState,
    sessionUsage: usage,
    unreadCount: unreadCount
)
```

---

## Final Verdict: NEEDS CHANGES

The spec's architecture is correct. The two wiring gaps (setting `currentSelectedSessionKey` and calling `clearUnread`) both resolve to the same location — `MainWindow`'s `sidebarSelection` binding. Once the spec is updated to show this wiring explicitly, it's safe to implement.

**No changes to the core approach are needed.** This is a narrow, well-scoped feature with minimal risk to the existing build.
