# Neo Review: Unread Indicator Spec v2

**Reviewer:** Neo (fresh eyes, no prior involvement)
**Date:** 2026-04-29
**Verdict:** ⚠️ NEEDS CHANGES

---

## Overall Assessment

The v2 approach (in-memory tracking) is fundamentally sound and much safer than v1's DB trigger. The spec is well-structured, the scope is tight, and the rollback path is clean. However, there are **two bugs** and **one visual risk** that need fixing before implementation.

---

## Review Focus Responses

### 1. Could anything break the current build?

**Low risk, but one subtle issue.**

The changes are almost entirely additive — new properties, new parameters with defaults, new methods. No existing method signatures are changed. The `unreadCount: Int = 0` default parameter on `SessionRow` means existing callers won't break at compile time.

**However:** The spec says to set `currentSelectedSessionKey` from `MainWindow`, but doesn't specify *what value* to set it to. `MainWindow`'s `sidebarSelection` binding works with `topic.id` (a UUID), but `didStartStreaming` uses `sessionKey` (a gateway key like `agent:main:uuid`). These are different strings. If `currentSelectedSessionKey` is set to `topic.id` instead of `topic.sessionKey`, the comparison `sessionKey != selectedKey` will *always* be true, and every stream will be counted as unread — even for the currently selected topic.

**Fix:** The spec must explicitly state that `currentSelectedSessionKey` should be set to `topic.sessionKey` (the gateway key), not `topic.id`.

---

### 2. Re-render concern with `unreadCounts` on `@Observable`

**Not a real problem.**

`SyncBridgeObserver` is `@Observable final class`. Every mutation to `unreadCounts` will trigger SwiftUI observation. However:

- `didStartStreaming` fires **once per assistant response**, not per token. The polling loop in `startStreamingPoll()` handles the per-token updates separately.
- The maximum rate is bounded by how fast Bee can start new responses — realistically, one per conversation turn.
- Even with 5–10 concurrent topics, the sidebar will see at most ~10 dictionary mutations per response cycle.
- SwiftUI's observation system is designed to coalesce rapid changes within the same runloop.

**Verdict:** No throttling or debouncing needed. This is fine.

---

### 3. `currentSelectedSessionKey` initial value and nil behavior

**This is a real bug.**

The spec adds `var currentSelectedSessionKey: String?` with no initial value (defaults to `nil`). The unread increment logic is:

```swift
if let selectedKey = self.currentSelectedSessionKey, sessionKey != selectedKey {
    self.unreadCounts[sessionKey, default: 0] += 1
}
```

When `currentSelectedSessionKey` is `nil`, the `if let` unwraps to `false`, and **no unread count is ever incremented**. This means:

- **On app launch:** If Bee responds before the user clicks any topic, the unread count stays at 0. The user sees no indicator.
- **After topic deletion:** If the selected topic is deleted and `selectedTopicId` becomes `nil`, incoming streams won't be counted.

This isn't a crash — it's a silent failure where the feature just doesn't work in certain states.

**Fix:** Change the logic to treat `nil` as "no topic selected, count everything as unread":

```swift
if sessionKey != self.currentSelectedSessionKey {
    self.unreadCounts[sessionKey, default: 0] += 1
}
```

When `currentSelectedSessionKey` is `nil`, `sessionKey != nil` is always `true`, so all streams get counted. When it has a value, only non-matching streams get counted. This is the correct behaviour.

---

### 4. Dead code removal — `topic.unreadCount` in SessionRow

**Safe to remove from SessionRow, but the field itself must NOT be removed.**

The spec correctly identifies that the `if topic.unreadCount > 0` block in `SessionRow` (line 64–66) is dead code — `topic.unreadCount` is always 0 because nothing increments it.

However, `unreadCount` is used extensively outside SessionRow:

| File | Usage |
|------|-------|
| `Topic.swift` | DB column, model property |
| `Session.swift` | DB column, model property |
| `TopicViewModel.swift` | Copied from Topic in init |
| `DatabaseManager.swift` | Column definition, migration SQL |
| `SessionRepository.swift` | `setUnreadCount` method |
| `BeeChatPersistenceTests.swift` | Test assertions |

The spec's scope table says "remove dead code" but doesn't clarify that this only means the **UI check in SessionRow**, not the DB field or model property. The DB field and model property must remain — they're part of the schema and used by the persistence layer.

**Fix:** The spec should explicitly state: "Remove only the `if topic.unreadCount > 0` block from SessionRow.swift. The `unreadCount` property on `Topic`, `Session`, and `TopicViewModel` is unchanged."

---

### 5. Font weight change — visual jump risk

**Moderate risk, but manageable.**

Changing from `.regular` to `.semibold` changes the text bounding box. Semibold characters are slightly wider. In a SwiftUI `List` row with `.lineLimit(1)`, this can cause:

- **Text reflow:** The title might shift a few pixels, causing the spacer and trailing elements to shift
- **Row height change:** In some cases, semibold text can be slightly taller, potentially causing the row to grow by 1–2 points
- **Visual "jump":** When a topic transitions from read → unread, the entire row content shifts

**Mitigation:** Use a fixed-width layout or add `.animation(.easeOut(duration: 0.15), value: unreadCount)` to smooth the transition. Or see recommendation #6 below.

---

### 6. Simpler version with less risk

**Yes — drop the bold text, keep only the blue dot.**

The bold text adds visual noise and the reflow risk described above. The blue dot alone is a well-established unread indicator pattern (used by iMessage, Slack, Discord, Telegram). It's unambiguous, doesn't affect layout, and is easier to spot in a list.

**Recommended minimal change:**

```swift
// In SessionRow body — only the dot, no bold
Text(topic.title)
    .font(themeManager.font(.body))
    .lineLimit(1)
    // NO fontWeight change

// ... spacer ...

if unreadCount > 0 {
    Circle()
        .fill(themeManager.color(.accentPrimary))
        .frame(width: 8, height: 8)
}
```

This eliminates the reflow risk entirely. If Adam wants bold text later, it can be added as a follow-up with proper animation. But for the initial implementation, the dot alone is safer and sufficient.

---

### 7. Backgrounded app edge case

**Not a problem, but worth documenting.**

When the app is backgrounded on macOS:
- `didStartStreaming` will **not** fire (the gateway connection may be suspended)
- When the app returns to foreground, unread counts start at 0

This is acceptable and matches the spec's own trade-off table ("Lost on app restart"). Background/foreground is the same category — in-memory state is ephemeral.

**Recommendation:** Add a brief note to the spec: "Background/foreground transitions also reset unread counts to 0 (same as app restart). This is expected behaviour for an in-memory indicator."

---

## Summary of Required Changes

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 1 | `currentSelectedSessionKey` must be set to `topic.sessionKey`, not `topic.id` | **Bug** | Specify gateway key in MainWindow wiring |
| 2 | `nil` currentSelectedSessionKey prevents all counting | **Bug** | Remove `if let` unwrap; use direct comparison |
| 3 | Dead code removal scope unclear | **Clarity** | Explicitly limit removal to SessionRow UI check only |
| 4 | Bold text causes potential row reflow | **Risk** | Drop bold text; use blue dot only |

---

## What's Good

- In-memory approach is correct — no DB risk, no reconciliation issues
- Scope is tight — 4 files, ~34 lines
- Default parameter values prevent compile-time breaks
- Rollback is trivial (single git revert)
- Testing checklist is comprehensive
- Trade-off table is honest and accurate

---

## Verdict: NEEDS CHANGES

The spec is 90% there. Fix the two bugs (#1 and #2 above) and consider dropping the bold text (#4) for a safer initial implementation. The dead code removal scope (#3) just needs clarification, not a code change.

Once these are addressed, this is ready to implement.
