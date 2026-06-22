# BeeChat Session Reset — Final Implementation Spec (Hybrid)

**Date:** 2026-05-14  
**Author:** Bee (Coordinator)  
**Status:** Final Draft — Team Review Required  
**Approach:** Hybrid (Manual at 50% + Auto at 80%)  
**Reviewers:** Q (implementation), Kieran (adversarial), Mel (UI)  

---

## Goal

Keep topic conversations flowing smoothly by managing session context bloat, without data loss and with minimal user friction. The hybrid gives Adam manual control when he wants it, and an automatic safety net for when he doesn't.

---

## Behaviour

### At 50% usage — Amber indicator + manual reset

- An amber dot appears on the topic row (replaces the current red dot).
- Tapping the amber dot or right-clicking → "Reset Session" shows a confirmation alert.
- Confirmation alert text: `"Reset Session?" / "This will clear the conversation context for "[topic name]". The last 30 messages will be carried forward as context." / [Cancel] [Reset]`
- On confirm: app fetches last 30 local messages, calls `sessions.reset` on gateway, formats messages as `[SESSION-CONTEXT]`, stores the payload. On next send, the context is prepended to the user's message.
- Amber dot disappears immediately after successful reset. Usage resets to ~0%.
- No cooldown on manual resets. If Adam taps reset, it always works.

### At 80% usage — Automatic reset on send

- On the next message send, if usage ≥ 80%, the existing auto-reset flow fires automatically.
- The flow is identical to what exists today: abort streaming → fetch local history → reset session → format context → prepend to message → send.
- The 5-message cooldown does NOT apply to the 80% auto-reset (safety ceiling always fires). Manual resets also skip cooldown.
- A brief toast appears: "Session refreshed" (auto-dismiss after 3 seconds).
- The 80% threshold overrides cooldown. If usage ≥ 80%, auto-reset fires regardless of cooldown state. No cooldown check on the 80% path.

### Between 50-80%

- Amber dot visible. User can reset manually or continue as normal.
- No automatic action. Full user control.

### Below 50%

- No indicator. Normal operation.

---

## Visual Design

| Element | Current | New |
|---|---|---|
| Reset dot colour | `Color.red` | `Color.orange` (amber) |
| Reset dot shadow | `Color.red.opacity(0.4)` | `Color.orange.opacity(0.3)` |
| Reset dot size (visual) | 10×10 | 10×10 (unchanged) |
| Reset dot size (hit target) | 10×10 | 24×24 via `.contentShape(Rectangle())` |
| Health colours | Green/honey/rose | Unchanged |
| Unread dot colour | Blue/accent | Unchanged |
| Unread dot accessibility | Missing label | Add `.accessibilityLabel("Unread messages")` |

Colour hierarchy: **green = healthy**, **amber = reset available**, **blue = unread**, **rose = bloated**. No red anywhere.

---

## Context Menu

```
.contextMenu {
    Button("Reset Session") {
        showResetConfirmation(for: topic)
    }
    // Always available — not disabled at any threshold.
    // Rationale: zombie sessions or stalled connections may need a reset
    // even when usage is low. The amber dot still only appears at 50%+
    // as a visual hint, but the menu item is never blocked.

    Divider()

    Button("Delete Topic", role: .destructive) {
        deleteTopic(topic.id)
    }
}
```

- Divider separates recoverable (Reset) from destructive (Delete).
- "Reset Session" is always enabled — zombie sessions and stalled connections can need a reset even below 50% usage.
- The amber dot still only appears at 50%+ as a visual nudge; the menu item is never blocked.
- "Reset Session" is **not** `.destructive` — it's a normal action with a confirmation step.

---

## Confirmation Alert

```swift
.alert("Reset Session?", isPresented: $showResetAlert) {
    Button("Cancel", role: .cancel) { }
    Button("Reset", role: .none) { performReset(for: resetTargetSessionKey) }
} message: {
    Text("The last 30 messages will be carried forward as context for the next reply.")
}
```

- No role `.destructive` on the Reset button — it's recoverable.
- Message explains what's **preserved**, not just what's lost.
- Keyboard: Enter = Reset, Escape = Cancel (SwiftUI handles this).

---

## Accessibility

1. **Combined row label** includes all states: `"Project Q, Getting large, 87 messages, unread, session at 58% — reset available"`
2. **Amber dot** gets `.accessibilityLabel("Session at X% usage — tap to reset")`.
3. **Unread blue dot** gets `.accessibilityLabel("Unread messages")`.
4. **VoiceOver announcement** when amber dot first appears: `"Session approaching capacity"`.
5. **Hit target** enlarged to 24×24 with `contentShape(Rectangle())` for motor accessibility.
6. **WCAG contrast**: verify amber dot on sidebar background meets 3:1 minimum for non-text elements.

---

## Implementation Details

### Config changes (`SessionResetManager.swift`)

```swift
public struct Config {
    public var redDotThreshold: Double = 0.50      // When the amber dot appears
    public var autoResetThreshold: Double = 0.80    // When auto-reset fires on send
    public var summaryTimeout: TimeInterval = 45
    public var showConfirmation: Bool = true         // Confirmation alert for manual reset
    public var cooldownMessages: Int = 5            // Auto-reset cooldown (manual resets skip this)
    public init() {}
}
```

### SyncBridge changes (`SyncBridge.swift`)

**1. Auto-reset block — change threshold, add override:**

The existing auto-reset block in `sendMessage()` (lines ~210-248) stays. Two changes:
- Replace `threshold` comparison with `config.autoResetThreshold` (was `config.redDotThreshold`).
- Add cooldown override: if `cappedUsage >= config.autoResetThreshold`, skip cooldown check.

```swift
// Before (existing):
let threshold = await sessionResetManager.config.redDotThreshold
if cappedUsage >= threshold {

// After:
let autoThreshold = await sessionResetManager.config.autoResetThreshold

if cappedUsage >= autoThreshold {
    // 80% safety ceiling: always fires, cooldown override
    // (cooldown only applies to sub-80% resets, which don't exist in the hybrid model)
```

**2. New `manualReset()` method:**

```swift
/// Manual reset triggered by user (amber dot tap or context menu).
/// Fetches local history, resets session, stores context for next send.
/// Returns true if reset succeeded, false if it failed or is already in progress.
public func manualReset(sessionKey: String) async throws -> Bool {
    guard pendingResetContext[sessionKey] == nil else {
        // Already have a pending reset for this session — skip double-tap
        return true
    }

    // Abort any in-flight generation
    if streamingSessionKeys.contains(sessionKey) {
        try? await abortGeneration(sessionKey: sessionKey)
    }

    delegate?.syncBridge(self, didStartManualReset: sessionKey)

    // Fetch local history BEFORE reset (local SQLite, not gateway)
    let recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)

    // Reset session on gateway
    let ok = try await resetSession(sessionKey: sessionKey)

    if ok {
        // Format context and store for next send
        let contextPayload = formatCombinedContext(recentMessages, userMessage: "")
        pendingResetContext[sessionKey] = contextPayload

        // Re-inject topic context on next send
        contextInjectedKeys.remove(sessionKey)

        // Update usage cache
        sessionUsageCache[sessionKey] = 0
    }

    delegate?.syncBridge(self, didStopManualReset: sessionKey)
    return ok
}
```

**3. Pending context injection in `sendMessage()`:**

At the start of `sendMessage()`, before the existing auto-reset block, add:

```swift
// Inject pending manual reset context if present
if let pendingContext = pendingResetContext.removeValue(forKey: sessionKey) {
    if effectiveText.isEmpty {
        effectiveText = pendingContext
    } else {
        effectiveText = "\(pendingContext)\n\n\(effectiveText)"
    }
    didAutoReset = true  // Reuse the existing flag to skip topic context injection
}
```

**4. Clear pending context on topic switch:**

In `MainWindow.swift`, when `sidebarSelection` changes, add:

```swift
.onChange(of: sidebarSelection) { _, newValue in
    // Clear any stale pending reset context when switching topics
    syncBridge.clearPendingResetContext(except: newValue)
}
```

And in `SyncBridge`:

```swift
func clearPendingResetContext(except sessionKey: String?) {
    if let key = sessionKey {
        for k in pendingResetContext.keys where k != key {
            pendingResetContext.removeValue(forKey: k)
        }
    } else {
        pendingResetContext.removeAll()
    }
}
```

### SyncBridgeDelegate changes

Add two delegate methods for manual reset UI feedback:

```swift
func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String)
func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String)
```

### SyncBridgeObserver changes

```swift
@Published var manualResetting = false

nonisolated func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) {
    Task { @MainActor in
        self.manualResetting = true
    }
}

nonisolated func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) {
    Task { @MainActor in
        self.manualResetting = false
    }
}
```

### MainWindow changes

**1. Wire `onReset` on `SessionRow`:**

```swift
SessionRow(
    topic: topic,
    thinkingState: topicThinkingState,
    sessionUsage: usage,
    unreadCount: unreadCount,
    onReset: {
        resetTargetSessionKey = topic.sessionKey
        showResetAlert = true
    }
)
```

**2. Add state for confirmation alert:**

```swift
@State private var showResetAlert = false
@State private var resetTargetSessionKey: String? = nil
```

**3. Add confirmation alert:**

```swift
.alert("Reset Session?", isPresented: $showResetAlert) {
    Button("Cancel", role: .cancel) { }
    Button("Reset") {
        if let key = resetTargetSessionKey {
            Task {
                try? await syncBridge.manualReset(sessionKey: key)
            }
        }
    }
} message: {
    Text("The last 30 messages will be carried forward as context for the next reply.")
}
```

**4. Add "Reset Session" to context menu:**

```swift
.contextMenu {
    Button("Reset Session") {
        resetTargetSessionKey = topic.sessionKey
        showResetAlert = true
    }
    // Always available — zombie sessions may need reset even at low usage. Amber dot still only appears at ≥50%.

    Divider()

    Button("Delete Topic", role: .destructive) {
        deleteTopic(topic.id)
    }
}
```

**5. Clear pending context on topic switch:**

```swift
.onChange(of: sidebarSelection) { _, newValue in
    syncBridge.clearPendingResetContext(except: newValue)
}
```

### SessionRow changes

**1. Change red dot → amber:**

```swift
// Before:
Circle()
    .fill(Color.red)
    .frame(width: 10, height: 10)
    .shadow(color: Color.red.opacity(0.4), radius: 3, x: 0, y: 0)

// After:
Circle()
    .fill(Color.orange)
    .frame(width: 10, height: 10)
    .shadow(color: Color.orange.opacity(0.3), radius: 3, x: 0, y: 0)
    .contentShape(Rectangle())
    .frame(width: 24, height: 24)  // Larger hit target
```

**2. Update accessibility label:**

```swift
.help("Session at \(Int((sessionUsage ?? 0) * 100))% — tap to reset")
.accessibilityLabel("Session at \(Int((sessionUsage ?? 0) * 100))% — tap to reset")
```

**3. Add unread dot accessibility:**

```swift
// Before:
if unreadCount > 0 {
    Circle()
        .fill(themeManager.color(.accentPrimary))
        .frame(width: 8, height: 8)
}

// After:
if unreadCount > 0 {
    Circle()
        .fill(themeManager.color(.accentPrimary))
        .frame(width: 8, height: 8)
        .accessibilityLabel("Unread messages")
}
```

### Toast for auto-reset (SyncBridgeObserver + MainWindow)

When auto-reset completes, show a brief toast:

```swift
// In SyncBridgeObserver:
nonisolated func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {
    Task { @MainActor in
        self.autoResetting = false
        self.showAutoResetToast = true
    }
}

// In MainWindow, near the existing thinking indicator:
if syncBridgeObserver.showAutoResetToast {
    Text("Session refreshed")
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(themeManager.color(.bgSurface))
        .cornerRadius(8)
        .transition(.opacity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                syncBridgeObserver.showAutoResetToast = false
            }
        }
}
```

---

## What Does NOT Change

- `fetchLocalHistory()` — used as-is, reads from local SQLite (not gateway)
- `formatCombinedContext()` — used as-is, pure function
- `resetSession()` — used as-is, thin RPC wrapper
- Topic context injection — still works, skipped when manual reset context is already prepended
- Delivery ledger — still created per send, with `originalContent` field preserving the raw user message
- Database schema — no migrations
- Data model — no new entities

---

## Files Changed

| File | Changes | Lines |
|---|---|---|
| `SessionResetManager.swift` | Add `autoResetThreshold`, `cooldownMessages`, `showConfirmation` to Config | ~5 |
| `SyncBridge.swift` | Change auto-reset threshold, remove cooldown check at 80%, add `manualReset()`, add `pendingResetContext` dict, inject pending context in `sendMessage()`, add `clearPendingResetContext()`, migrate `resetCooldownMessages` to Config | ~60 |
| `SyncBridge+Delegate.swift` or `SyncBridge.swift` | Add `didStartManualReset`/`didStopManualReset` to delegate protocol + observer conformance | ~8 |
| `SyncBridgeObserver.swift` | Add `manualResetting` state, `showAutoResetToast` state, delegate handlers | ~15 |
| `SessionRow.swift` | Amber dot, larger hit target, updated accessibility labels, unread dot label | ~12 |
| `MainWindow.swift` | Wire `onReset`, add reset alert state, confirmation alert, context menu item, topic-switch clearing, auto-reset toast | ~30 |
| **Total** | | **~129** |

Single PR. No structural changes. No new files. No migrations.

---

## Reviewer Concerns Addressed

### Kieran: Crash between reset and send data loss
**Mitigated by the hybrid.** If the app crashes after a manual reset at 50-80%, the pending context is lost, but the session is still below the 80% ceiling — the user's next send works fine, they just don't get the context summary. The 80% auto-reset is atomic (within a single `sendMessage` call) and guarantees no data loss.

### Kieran: Rapid tap + send race condition
**Mitigated by the guard in `manualReset()`.** If `pendingResetContext[sessionKey]` already exists, the method returns `true` (idempotent). No double-reset. The compose field is disabled during reset via the `manualResetting` state.

### Kieran: Cooldown vs safety net interaction
**Resolved.** The 80% auto-reset overrides cooldown. Manual resets skip cooldown entirely.

### Kieran: `contextInjectedKeys` double-injection
**Handled.** `manualReset()` removes `contextInjectedKeys[sessionKey]`, but `sendMessage()` checks `didAutoReset` (set when pending context is injected) to skip topic context injection. No double-injection.

### Kieran: `fetchLocalHistory()` hidden coupling to local storage
**Acknowledged.** Adding a comment to the method documenting that it deliberately reads from local SQLite, not the gateway, and that changing this would break the reset flow.

### Kieran: Sidebar refresh after manual reset
**Handled.** `manualReset()` sets `sessionUsageCache[sessionKey] = 0` and fires delegate callbacks. The UI refreshes via observed state changes.

### Mel: Confirmation alert required
**Added.** Alert explains what's preserved, includes Cancel + Reset buttons.

### Mel: Context menu needs divider
**Added.** Divider between "Reset Session" and "Delete Topic".

### Mel: "Reset Session" not destructive
**Correct.** Normal button style, no `.destructive` role.

### Mel: Accessibility for unread dot
**Added.** `.accessibilityLabel("Unread messages")`.

### Mel: Hit target enlargement
**Added.** 24×24 `contentShape` on the amber dot.

### Q: Feature-flag instead of deleting auto-reset code
**Adopted.** Auto-reset block stays, threshold changes from 50% to 80%, cooldown check removed from 80% path entirely (safety ceiling always fires). No dead code.

### Q: `pendingResetContext` location
**Confirmed.** In `SyncBridge` (actor-isolated). Cleared on topic switch.

### Q: Line count estimate
**Revised.** ~129 lines, accounting for topic-switch clearing, UI indicator, feature flag, toast, delegate protocol update, and Config migration.

### Q: Delegate protocol update
**Added.** `didStartManualReset`/`didStopManualReset` must be added to `SyncBridgeDelegate` protocol, not just the observer.

### Q: `resetCooldownMessages` migration
**Added.** Currently a `static let` on SyncBridge. Must move to `Config.cooldownMessages` with `await` for actor isolation.

---

## Testing Checklist

- [ ] Amber dot appears at ≥50% usage, disappears after manual reset
- [ ] Auto-reset fires at ≥80% usage on next send, regardless of cooldown
- [ ] Manual reset: confirmation alert appears, Cancel dismisses, Reset performs reset
- [ ] Manual reset: compose field disabled during reset operation
- [ ] Manual reset: context carried forward on next send (check assistant sees `[SESSION-CONTEXT]`)
- [ ] Manual reset: amber dot disappears, usage drops to ~0%
- [ ] Manual reset: double-tap guard (second tap does nothing)
- [ ] Manual reset: topic switch clears pending context for previous topic
- [ ] Auto-reset toast appears and auto-dismisses after 3 seconds
- [ ] Context menu: "Reset Session" appears (always available, never disabled)
- [ ] Context menu: divider between Reset and Delete
- [ ] Accessibility: VoiceOver reads combined label including usage percentage
- [ ] Accessibility: Amber dot hit target is 24×24
- [ ] Crash recovery: force-quit after manual reset, relaunch, send works (no context carry-forward, but no broken state)
- [ ] Long session: manual reset at 60%, verify context summary is bounded and correct
- [ ] Edge case: manual reset then immediate send (compose disabled during reset, so this shouldn't happen, but verify no crash)

---

*Final spec for team review. All three reviewers to confirm agreement before Q begins implementation.*