# Spec: Sidebar Unread Message Indicator (v2)

**Date:** 2026-04-29
**Status:** DRAFT — Pending team review (v2 updated with Kieran + Neo feedback)
**Previous version:** v1 (DB trigger approach — rejected due to reconciliation inflation risk)
**Scope:** SyncBridgeObserver + MainWindow + SessionRow.swift only
**Risk Level:** LOW (in-memory only, no DB changes, no migrations)

---

## Problem

When Bee replies in a topic the user isn't viewing, there's no visual indicator. The existing `topic.unreadCount` field is always 0 — nothing increments it.

## Why Not a DB Trigger?

Two independent reviewers caught the same critical issue: the `Reconciler` bulk-inserts up to 200 messages from history. A DB trigger would fire per-row, inflating `unreadCount` to 100+ for a topic. A trigger guard would add complexity and fragility. **In-memory tracking is simpler, safer, and sufficient.**

## Solution: In-Memory Unread Tracking

### How it works

1. `SyncBridgeObserver` already receives `didStartStreaming(sessionKey:)` for every assistant response
2. Add a dictionary `unreadCounts: [String: Int]` mapping session keys to unread counts
3. When `didStartStreaming` fires for a session key that IS NOT the currently selected topic → increment the count
4. When the user selects a topic → reset that topic's unread count to 0 (in `MainWindow.sidebarSelection`, not `MessageViewModel` — per Kieran's review)
5. On app launch → all counts start at 0 (acceptable — most chat apps behave this way)

### Part 1: Data layer (SyncBridgeObserver)

**File:** `SyncBridgeObserver.swift`

**Add:**
```swift
/// Tracks unread assistant message counts per session key.
/// Key = session key, Value = number of unread messages.
/// Reset on topic selection. Lost on app restart (acceptable for a visual indicator).
var unreadCounts: [String: Int] = [:]
```

**In `didStartStreaming`:** After existing logic, add:
```swift
// Mark unread if streaming started in a topic that isn't currently selected
// Neo feedback: use direct != comparison so nil = count everything (not silence)
if sessionKey != self.currentSelectedSessionKey {
    self.unreadCounts[sessionKey, default: 0] += 1
}
```

**Why `!=` not `if let`:** If `currentSelectedSessionKey` is nil (app launch before any topic selected), the comparison `"agent:main:xxx" != nil` is `true`, so the unread count increments correctly. The v1 spec's `if let` guard would have silenced ALL counting when nothing is selected.

**Problem:** `SyncBridgeObserver` doesn't currently know which topic is selected.

**Solution (Kieran + Neo feedback incorporated):** Set `currentSelectedSessionKey` in `MainWindow`'s `sidebarSelection` binding. This is where `selectTopic` is already called — add one line right after it:

```swift
private var sidebarSelection: Binding<String?> {
    Binding(
        get: { messageViewModel.selectedTopicId },
        set: { newId in
            if let id = newId, id != messageViewModel.selectedTopicId {
                messageViewModel.selectTopic(id: id)
                // Update observer's knowledge of which session is selected
                syncBridgeObserver.currentSelectedSessionKey = messageViewModel.selectedTopic?.sessionKey
            }
        }
    )
}
```

**Key verification (checked against live DB):** `topic.sessionKey` stores the gateway-format key (e.g., `agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d`) — exactly the same format that `didStartStreaming(sessionKey:)` receives. No transformation needed. `topic.id` is an uppercase UUID and must NOT be used for comparison.

### Part 2: Clear on selection (MainWindow)

**File:** `MainWindow.swift` (Kieran feedback: `MessageViewModel` doesn't have a reference to `SyncBridgeObserver`)

In the `sidebarSelection` binding, after setting `currentSelectedSessionKey`:
```swift
syncBridgeObserver.clearUnread(for: messageViewModel.selectedTopic?.sessionKey)
```

Add to `SyncBridgeObserver`:
```swift
func clearUnread(for sessionKey: String?) {
    guard let key = sessionKey else { return }
    unreadCounts.removeValue(forKey: key)
}
```

### Part 3: Pass unread to SessionRow (MainWindow)

**File:** `MainWindow.swift`

In the sidebar `ForEach`, pass the unread count:
```swift
let unreadCount = syncBridgeObserver.unreadCounts[topic.sessionKey ?? ""] ?? 0

SessionRow(
    topic: topic,
    thinkingState: syncBridgeObserver.thinkingState,
    sessionUsage: usage,
    unreadCount: unreadCount  // NEW parameter
)
```

### Part 4: Visual indicator (SessionRow)

**File:** `SessionRow.swift`

**Changes:**
1. Add `unreadCount: Int = 0` parameter to `SessionRow`
2. When `unreadCount > 0`: show blue accent dot + count (NO bold text — per Neo's review, bold can cause row reflow and is unnecessary; iMessage/Slack/Discord use dots only)
3. Layout: `[health dot] [title] [Spacer] [blue dot if unread + count if >0] [red usage dot] [dormant bee]`
4. Update accessibility label to include unread count

```swift
struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    let topic: TopicViewModel
    var thinkingState: ThinkingState = .idle
    var sessionUsage: Double? = nil
    var unreadCount: Int = 0  // NEW
    var onReset: (() -> Void)? = nil
    var onSelect: (() -> Void)? = nil

    // ... existing computed properties ...

    var body: some View {
        HStack {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)

            Text(topic.title)
                .font(themeManager.font(.body))
                .lineLimit(1)

            Spacer()

            // Unread indicator: blue dot + count (ONLY when unread > 0)
            // No bold text — avoids row reflow (iMessage/Slack/Discord use dots only)
            if unreadCount > 0 {
                Circle()
                    .fill(themeManager.color(.accentPrimary))  // Blue/accent, NEVER red
                    .frame(width: 8, height: 8)

                Text("\(unreadCount)")
                    .font(.caption)
                    .foregroundColor(themeManager.color(.textSecondary))
            }

            // Session reset red dot (unchanged)
            if shouldShowRedDot { ... }

            // Dormant bee (unchanged)
            if thinkingState == .idle, ... { ... }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select conversation")
    }

    private var accessibilityLabel: String {
        var parts = ["\(topic.title), \(healthDescription), \(topic.messageCount) messages"]
        if unreadCount > 0 {
            parts.append("\(unreadCount) unread")
        }
        return parts.joined(separator: ", ")
    }
}
```

**Remove the old dead-code `unreadCount` block** that checked `topic.unreadCount > 0` — it never fired because `topic.unreadCount` is always 0.

---

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `SyncBridgeObserver.swift` | Add `unreadCounts` dict, `currentSelectedSessionKey`, increment on `didStartStreaming`, `clearUnread()` method | ~12 |
| `MainWindow.swift` | Set `currentSelectedSessionKey`, call `clearUnread` in `sidebarSelection` | ~5 |
| `MainWindow.swift` | Pass `currentSelectedSessionKey` to observer, pass `unreadCount` to SessionRow | ~5 |
| `SessionRow.swift` | Add `unreadCount` param, bold title, blue dot, remove dead code | ~15 |

**Total: ~30 lines across 4 files. Zero DB changes. Zero migrations.**

---

## What is NOT changing

- ❌ No database changes (no new triggers, no migrations, no schema changes)
- ❌ No changes to MacTextView, Composer, or ComposerViewModel
- ❌ No changes to SyncBridge, EventRouter, or Reconciler
- ❌ No changes to TopicRepository or DatabaseManager
- ❌ No new Swift packages or dependencies
- ❌ The existing health dot, red usage dot, and dormant bee remain unchanged

---

## Trade-offs

| Aspect | DB trigger approach | In-memory approach (chosen) |
|--------|---------------------|------------------------------|
| Persists across restarts | ✅ Yes | ❌ No — resets to 0 |
| Reconciliation-safe | ❌ No — inflates counts | ✅ Yes — only counts live messages |
| Migration required | ✅ Yes | ❌ No |
| Complexity | High (triggers, backfill, decrement) | Low (one dictionary, two methods) |
| Risk of breaking existing build | Higher | Lower |
| User expectation | Most apps reset unread on restart | Matches this behaviour |

---

## Testing Checklist

1. ✅ App launches without crash
2. ✅ Send a message to Topic A → switch to Topic B → Topic A shows blue dot + count
3. ✅ Click Topic A → blue dot disappears, title returns to regular weight
4. ✅ Blue dot is visually distinct from the red session-usage dot
5. ✅ Topic with no unread messages looks identical to current version
6. ✅ Multiple unread messages show correct count (e.g., "3")
7. ✅ Restart app → all unread counts reset to 0 (expected)
8. ✅ Reconciler fetching history does NOT increment unread counts
9. ✅ VoiceOver announces unread count when present
10. ✅ Existing session health dot, usage dot, and dormant bee are unchanged

---

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Unread lost on restart | Certain | Acceptable — most chat apps behave this way |
| `didStartStreaming` fires for selected topic | Low — we check `sessionKey != currentSelectedSessionKey` | Clear on selection |
| `didStartStreaming` fires twice for same response | Low — `isFirstDelta` guard in SyncBridge | Count would increment once per stream start |
| Observer not wired to SessionRow | Low — existing pattern, same data flow as `thinkingState` | Same wiring pattern that works today |

## Rollback

Single git revert. No DB changes to undo. In-memory state is ephemeral — app returns to previous behaviour instantly.