# Kieran's Final Review: Session Reset Hybrid Spec

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-14  
**Spec:** SPEC-session-reset-hybrid-final.md  
**Verdict:** ✅ **Sign-off with minor notes**

---

## Original Concerns — Status

### 1. Crash between reset and send (data loss)
**RESOLVED.** The hybrid makes this non-catastrophic. If the app crashes after manual reset at 50-80%, the pending context is lost but the session is still below 80% — the next send works, just without the context summary. At 80%+, auto-reset is atomic within `sendMessage()`. This was my strongest objection to Option B, and the hybrid eliminates it as a data-loss risk.

### 2. Rapid tap + send race
**RESOLVED.** Guard in `manualReset()`: `guard pendingResetContext[sessionKey] == nil else { return true }`. And the compose field is disabled during reset via `manualResetting` state. The combination means: (a) a second tap is idempotent, and (b) the user can't send while a reset is in-flight. If someone types very fast and the UI disable is async, the worst case is a message going through without context on a sub-80% session — not data loss.

### 3. Double-tap
**RESOLVED.** Same guard as above. `pendingResetContext[sessionKey]` check means the second tap returns `true` (no-op) instead of fetching empty local history.

### 4. Cooldown override at 80%
**RESOLVED.** The spec explicitly states: "The 80% threshold overrides cooldown. If usage ≥ 80%, auto-reset fires regardless of cooldown state." The code sample confirms this with `if cappedUsage >= autoThreshold && !cooldownActive` — but wait, that's `&& !cooldownActive`, which means it *skips* the reset if cooldown is active. That's the opposite of what the spec text says.

**⚠️ BUG:** The code sample says:
```swift
if cappedUsage >= autoThreshold && !cooldownActive {
```
This means "fire auto-reset if usage ≥ 80% AND cooldown is NOT active." But the spec says the 80% threshold *overrides* cooldown. The code should be:
```swift
if cappedUsage >= autoThreshold {
    // Always fire at 80%, regardless of cooldown
```
Or if you want to keep the cooldown check for the 50-80% range:
```swift
if cappedUsage >= autoThreshold || (cappedUsage >= manualThreshold && !cooldownActive) {
```
**This needs to be fixed before implementation.** The existing code block has the cooldown check; the new spec says 80% overrides it. The code sample contradicts the spec text.

### 5. `contextInjectedKeys` double-injection
**RESOLVED.** `manualReset()` removes `contextInjectedKeys[sessionKey]`, and `sendMessage()` sets `didAutoReset = true` when it injects pending context, which skips topic context injection. Clean design — no double-injection path.

### 6. `fetchLocalHistory()` local-only coupling
**RESOLVED.** Spec says: "Adding a comment to the method documenting that it deliberately reads from local SQLite, not the gateway." Good enough. This is the kind of implicit coupling that kills you six months later when someone "refactors" it.

### 7. Sidebar refresh after manual reset
**RESOLVED.** `manualReset()` sets `sessionUsageCache[sessionKey] = 0` and fires delegate callbacks. The observer updates `manualResetting` state. Usage drops to 0%, amber dot disappears. This works.

---

## New Failure Modes Introduced by This Spec

### A. Toast auto-dismiss (3 seconds) — Edge Case
The toast auto-dismisses after 3 seconds via `DispatchQueue.main.asyncAfter`. If the user backgrounded the app or the main thread is blocked, the timer might fire while the app is hidden, and the toast disappears before the user sees it. This is cosmetic, not a bug — the toast is informational, not actionable. No fix needed.

Edge case: if auto-reset fires twice in quick succession (unlikely given cooldown, but possible if the first reset's summary is large enough to push usage back up), the toast state would be set to `true` twice, but since it's a `Bool`, it just stays `true` and the 3-second timer resets. Fine.

### B. Topic-switch clearing — `onChange(of: sidebarSelection)` reliability
SwiftUI's `onChange(of:)` for `sidebarSelection` should fire reliably for explicit user selection changes. But there are edge cases:

- **Programmatic selection changes** (e.g., creating a new topic, navigating from a notification) — these should trigger `onChange` as long as they update the binding, which they will if they set `sidebarSelection`.
- **Same-value re-selection** — SwiftUI won't fire `onChange` if the value doesn't change. This is fine because the pending context for the current topic should be preserved.
- **App backgrounding/foregrounding** — `sidebarSelection` doesn't change, so `onChange` doesn't fire. Pending context for the active topic persists across background cycles. This is correct behavior.

The `clearPendingResetContext(except:)` method is well-designed — it preserves context for the topic you're switching *to* while clearing stale context for other topics. No concerns here.

### C. `pendingResetContext` Memory Leak Potential
`pendingResetContext` is a `[String: String]` dictionary in `SyncBridge`. Entries are removed when: (a) context is injected on next send, or (b) topic switch clears them. If a user resets a topic and then never sends to it and never switches away, the entry persists indefinitely. Since each entry is bounded by `formatCombinedContext` (max ~100K chars), and the number of topics is bounded by practical use, this is not a real leak. Acceptable.

### D. `didAutoReset` Flag Reuse
The spec reuses the existing `didAutoReset` flag for manual reset context injection. This works because both paths need to skip topic context injection, and they're mutually exclusive (you can't auto-reset and manual-reset in the same `sendMessage` call). Clean reuse.

---

## Remaining Concern: The Cooldown Logic Bug

This is the only issue I'm flagging. Everything else in the spec is solid.

**Spec text says:** "The 80% threshold overrides cooldown. If usage ≥ 80%, auto-reset fires regardless of cooldown state."

**Code sample says:** `if cappedUsage >= autoThreshold && !cooldownActive`

These contradict each other. The `&& !cooldownActive` means cooldown *blocks* the 80% auto-reset, which is the opposite of "overrides cooldown."

**Fix:** Remove the cooldown check for the 80% path:
```swift
if cappedUsage >= autoThreshold {
    // 80% always fires, cooldown doesn't apply
```

Or, if you want to keep cooldown for a potential future lower-threshold auto-reset:
```swift
let cooldownActive = (resetCooldownCount[sessionKey] ?? 0) > 0
if cappedUsage >= autoThreshold || (cappedUsage >= config.redDotThreshold && !cooldownActive) {
```

But since manual reset replaces the lower-threshold auto-reset, the simpler version is correct.

---

## Verdict

**Sign-off, conditional on fixing the cooldown logic bug.** The code sample must match the spec text: 80% auto-reset fires regardless of cooldown. Change `&& !cooldownActive` to remove that condition for the `>= autoThreshold` path.

Everything else is clean. The hybrid design eliminates the catastrophic failure mode, the guard patterns are correct, the accessibility additions are solid, and the context menu UX is well thought out. Good spec.

---

*Kieran — adversarial review complete. Ship it after the cooldown fix.*