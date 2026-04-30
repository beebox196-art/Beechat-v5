# Neo Review: Sidebar Unread Indicator Spec

**Reviewer:** Neo (fresh eyes)
**Date:** 2026-04-29
**Spec:** `UNREAD-INDICATOR-SPEC.md`

---

## Verdict: **NEEDS CHANGES**

The spec is 80% solid. The UI part is clean and well-scoped. But the data layer has **one critical factual error** and **two significant risks** that would break things if shipped as-is.

---

## 1. CRITICAL: The trigger targets the wrong table

The spec says:

> *"This mirrors the existing `trg_increment_message_count` trigger pattern exactly."*

**It does not.** The original `trg_increment_message_count` trigger was on the `topics` table, but **Migration010 already replaced it** with `trg_session_increment_message_count` which targets the **`sessions`** table, not `topics`:

```sql
-- Current production trigger (Migration010):
CREATE TRIGGER trg_session_increment_message_count
AFTER INSERT ON messages
BEGIN
    UPDATE sessions SET messageCount = messageCount + 1 WHERE id = NEW.sessionId;
END
```

The spec's proposed trigger updates `topics.unreadCount`, which is correct for unread. But the spec incorrectly claims the pattern mirrors the *current* trigger — it mirrors the *old, deleted* one. This is a documentation issue, not a code issue. The trigger SQL itself is fine.

**Action:** Fix the spec's "Discovery" section to reference the current session-based triggers. The proposed unread trigger should target `topics` (correct) since that's where `unreadCount` lives, but the `WHERE` clause needs scrutiny (see §3 below).

---

## 2. HIGH: The trigger's WHERE clause is fragile

The spec proposes:

```sql
WHERE topics.id = (
    SELECT id FROM topics
    WHERE topics.sessionKey = NEW.sessionId OR topics.id = NEW.sessionId
    LIMIT 1
)
```

This `OR` clause has the same ambiguity as the old message count trigger. Problems:

- **`topics.id = NEW.sessionId`** only works if the topic ID happens to match the session key (which it sometimes does after the gateway key migration, but not always).
- **`topics.sessionKey = NEW.sessionId`** is the correct path — but if multiple topics share a session key (shouldn't happen, but no uniqueness constraint enforces it), `LIMIT 1` silently picks one.
- **The outer `WHERE topics.id = (...)`** means the trigger does nothing if the subquery returns NULL (no matching topic). This is actually safe — it's a silent no-op, not a crash. But it means unread count won't increment for assistant messages that arrive before the topic-sessionKey mapping exists.

**Recommendation:** Simplify to just `WHERE topics.sessionKey = NEW.sessionId` and add a comment explaining that `NEW.sessionId` is always a gateway-format key (e.g., `agent:main:uuid`). The `OR topics.id = NEW.sessionId` fallback adds confusion and masks missing mappings.

---

## 3. HIGH: Reconciliation will inflate unread counts

The `Reconciler.reconcile()` method calls `persistenceStore.upsertMessages(messageModels)` with up to 200 messages fetched from history. These are **bulk inserts**. The trigger fires **per-row** — so every assistant message in the history batch increments `unreadCount`.

**Scenario:**
1. User opens the app
2. Reconciler fetches 200 messages for the active session
3. ~100 are `role: "assistant"`
4. Unread count jumps to 100 for that topic
5. User sees a "100" badge on a topic they're actively viewing

This is the biggest risk in the spec. The trigger cannot distinguish between "new message the user hasn't seen" and "old message being re-inserted by reconciliation."

**Options:**

- **A. Exclude reconciliation:** Add a `source` column to messages or use a temporary SQLite `PRAGMA recursive_triggers = OFF` pattern during bulk inserts. Complex and fragile.
- **B. Reset unreadCount after reconciliation:** In `Reconciler.reconcile()`, after `upsertMessages`, reset `unreadCount` to a calculated value based on messages newer than the last-read timestamp. Requires storing a `lastReadAt` timestamp.
- **C. Guard the trigger with a session-level flag:** Set a SQLite `PRAGMA` or app-level flag that disables the trigger during reconciliation. SQLite doesn't support per-session triggers, so this would need to be an app-level pattern (disable trigger → bulk insert → re-enable → recalculate).
- **D. Use the simpler approach (see §5).**

**My recommendation:** Option D — skip the DB trigger entirely.

---

## 4. MEDIUM: markAsRead + ValueObservation interaction

The spec proposes calling `markAsRead(topicId:)` inside `selectTopic(id:)`. Here's the flow:

1. User clicks a topic in the sidebar
2. `selectTopic(id:)` runs → sets `selectedTopicId`
3. `markAsRead` writes to DB → `topics.unreadCount = 0`
4. `ValueObservation` tracking topics fires → calls `updateTopics(from:)`
5. `updateTopics` rebuilds the `topics` array and re-affirms `selectedTopicId`

**Risk:** Step 5 re-sorts topics alphabetically and re-creates all `TopicViewModel` instances. If the timing is unlucky, a brief flash or selection flicker could occur. However, looking at the code:

```swift
if let prev = previousSelection, self.topics.contains(where: { $0.id == prev }) {
    selectedTopicId = prev
} else {
    selectedTopicId = self.topics.first?.id
}
```

This preserves the selection. The `@Observable` macro should diff and only update changed properties. **Low risk, but worth noting:** `updateTopics` does a full rebuild every time any topic changes. If you have 50 topics and one gets an unread count update, all 50 `TopicViewModel`s get recreated. This is an existing pattern, not introduced by this spec, but it's worth being aware that the unread trigger will cause more frequent observation fires.

**Verdict:** Safe, but the full-rebuild-in-updateTopics pattern has a latent performance cost. Not a blocker for this spec.

---

## 5. Is there a simpler approach? YES

The spec asks whether unread could be tracked in-memory only. Here's a concrete proposal:

**In-memory unread tracking (no DB changes, no trigger, no reconciliation problem):**

```swift
// In MessageViewModel or a dedicated UnreadTracker
var unreadCounts: [String: Int] = [:]  // topicId → count

// When a gateway message arrives (via SyncBridgeObserver):
func onNewAssistantMessage(sessionKey: String) {
    if let topicId = resolveTopicId(for: sessionKey),
       topicId != selectedTopicId {
        unreadCounts[topicId, default: 0] += 1
    }
}

// When user selects a topic:
func selectTopic(id: String) {
    unreadCounts[id] = 0
    // ... existing selection logic
}
```

**Advantages:**
- Zero DB migration — no trigger, no `markAsRead` method
- No reconciliation inflation — only live gateway messages increment
- No ValueObservation churn from DB writes
- Simpler to reason about and test
- Survives the current architecture without touching the persistence layer

**Disadvantages:**
- Lost on app restart (unread resets to 0)
- No persistence across launches

**Is that acceptable?** For a visual indicator in a sidebar, losing unread state on restart is almost certainly fine. Users expect badges to clear when they relaunch. Most chat apps (iMessage, WhatsApp web) reset unread indicators on reload anyway.

**If persistence is truly needed**, store a `lastReadAt: Date` per topic in the DB and calculate unread as `COUNT(messages WHERE role = 'assistant' AND timestamp > lastReadAt)`. This avoids the trigger problem entirely and works correctly with reconciliation.

---

## 6. Minor Issues

| # | Issue | Severity |
|---|-------|----------|
| 6a | Spec says "blue dot MUST be blue/accent — NEVER red" but the existing health dot also has colour overlap potential with the unread count text (currently secondary text colour). Confirm the visual hierarchy in dark mode. | Low |
| 6b | The `if !db.tableExists("trg_increment_unread_count")` guard won't work — SQLite triggers aren't tables. Use `SELECT name FROM sqlite_master WHERE type='trigger' AND name='trg_increment_unread_count'` or GRDB's `triggerExists()` pattern. | Medium |
| 6c | The spec doesn't mention a decrement trigger for when messages are deleted. The existing `messageCount` has one (`trg_decrement_message_count`). If unread should decrease on message deletion, a matching trigger is needed. If not (deleting a message doesn't "un-read" it), this should be explicitly stated. | Low |
| 6d | `TopicViewModel` is a struct. Setting `unreadCount` after creation requires it to be `var` (it is — good). But `updateTopics(from:)` recreates all view models from scratch, so any in-mutation of `unreadCount` on the view model would be lost. This means the DB must be the source of truth. With in-memory tracking, you'd need to merge the in-memory counts into the rebuilt view models. | Medium |

---

## Summary

| Concern | Verdict |
|---------|---------|
| Could this break anything? | **Yes** — reconciliation will inflate unread counts to hundreds |
| Hidden dependencies? | `Reconciler.upsertMessages()` is the biggest one. Also: `updateTopics` rebuild pattern, `TopicViewModel` being a struct |
| DB trigger safe? | **No** — fires during bulk reconciliation inserts, inflating counts |
| markAsRead + ValueObservation? | **Safe** — selection is preserved, but adds observation churn |
| Simpler approach? | **Yes** — in-memory tracking with `UnreadTracker`, or `lastReadAt` timestamp with computed count |

## Recommendation

Ship the UI changes (Part 2) exactly as specified — they're clean and well-scoped. 

For Part 1 (data layer), **replace the DB trigger with in-memory unread tracking**. It's simpler, avoids the reconciliation problem, avoids adding a DB migration, and the downside (lost on restart) is acceptable for a visual indicator. If persistence is needed later, add a `lastReadAt` column and compute unread from message timestamps — that approach is reconciliation-safe.

If the team insists on the trigger approach, add a reconciliation guard: reset `unreadCount` to the correct value after reconciliation completes, or use a `lastReadAt` column instead of a counter.