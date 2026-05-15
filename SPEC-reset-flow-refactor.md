# SPEC: Reset Flow Refactor — Clean Foundation

**Date:** 2026-05-14
**Status:** Pending Adam's go/no-go (v3 — final team review)
**Origin:** Forensic audit by Q and Kieran identified structural issues in the session reset flow. This spec addresses root causes, not symptoms.

---

## Problem Statement

The session reset flow has two bugs and structural issues that undermine confidence:

1. **"Session refreshed" toast appears on every message** when usage ≥ 80%. Root cause: `didStopAutoReset` fires unconditionally — even when the reset fails. The cooldown code that should suppress it is dead code.
2. **`sendMessage` is a god function** — 100+ lines handling concurrency guards, streaming aborts, manual context injection, cooldown decrement, usage checks, auto-reset, topic context, delivery ledger, and RPC send. All in one method.
3. **`didAutoReset` flag reuse** — one boolean means both "auto-reset fired" and "manual reset context wasjected." Works by convention, not by design.
4. **Toast and spinner not scoped to session** — `showAutoResetToast` is a global boolean that leaks across topic switches. Same for `autoResetting`.
5. **No transaction boundary** — usage→reset→context injection can fail partway, leaving partial state.

---

## Root Cause Analysis

The auto-reset system was originally a pure auto-reset (50% threshold, meaningful cooldown). Today's hybrid model split this into manual (50%, no cooldown) and auto (80%, "always fires"). The cooldown was left as dead code because at 80%, the session resets immediately — there's never a "next message" where cooldown would suppress a check.

The unconditional `didStopAutoReset` was a deliberate fix for a previous bug (UI hanging on "Refreshing context..." forever). But it created a new bug: toast on failure.

These are not today's patches causing problems. These are pre-existing structural issues exposed by adding the toast UI.

---

## What We're Shipping Now

### Fix 1: Move `didStopAutoReset` inside success path, add `didAutoResetFail`

**Current:** `didStopAutoReset` fires after `do-catch`, regardless of success or failure.
**Proposed:** Only fire `didStopAutoReset` when `ok == true`. Add `didAutoResetFail` for failure paths — one-shot informational toast on first failure, then 30s suppression.

**Delegate timing:** `didStartAutoReset` fires BEFORE the async reset begins (spinner visible during reset). `didStopAutoReset` fires after success. `didAutoResetFail` fires after any failure.

```swift
// BEFORE (SyncBridge.swift):
if cappedUsage >= autoThreshold {
    delegate?.syncBridge(self, didStartAutoReset: sessionKey)
    do {
        // ... attempt reset ...
        if ok {
            // ... success ...
        }
    } catch {
        print("[SyncBridge] Auto-reset failed for \(sessionKey): \(error)")
    }
    delegate?.syncBridge(self, didStopAutoReset: sessionKey)  // ← BUG: always fires
}

// AFTER:
if cappedUsage >= autoThreshold {
    delegate?.syncBridge(self, didStartAutoReset: sessionKey)
    do {
        let recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
        let ok = try await resetSession(sessionKey: sessionKey)
        if ok {
            effectiveText = formatCombinedContext(recentMessages, userMessage: text)
            contextPrepended = true
            delegate?.syncBridge(self, didStopAutoReset: sessionKey)
        } else {
            print("[SyncBridge] Auto-reset returned false for \(sessionKey)")
            delegate?.syncBridge(self, didAutoResetFail: sessionKey)
        }
    } catch {
        print("[SyncBridge] Auto-reset failed for \(sessionKey): \(error)")
        delegate?.syncBridge(self, didAutoResetFail: sessionKey)
    }
}
```

**Failure UX (Kieran + Mel):** First failure shows a one-shot "Context refresh unavailable" toast for 3 seconds. Subsequent failures within 30 seconds suppress both spinner and toast for that session. After 30s, the next attempt may show them again. The message still sends normally in all cases — auto-reset is internal housekeeping, not a send blocker. This is a transient informational toast, not a persistent error indicator.

```swift
// In SyncBridgeObserver:
private var lastAutoResetFailTime: [String: Date] = [:]

nonisolated func syncBridge(_ bridge: SyncBridge, didStartAutoReset sessionKey: String) {
    Task { @MainActor in
        // Suppress spinner if this session's reset failed recently
        if let failTime = lastAutoResetFailTime[sessionKey],
           Date().timeIntervalSince(failTime) < 30 {
            return  // Don't show spinner again for same session
        }
        self.autoResettingSession = sessionKey
    }
}

nonisolated func syncBridge(_ bridge: SyncBridge, didAutoResetFail sessionKey: String) {
    Task { @MainActor in
        self.autoResettingSession = nil
        self.lastAutoResetFailTime[sessionKey] = Date()
        // One-shot informational toast
        self.toastSessionKey = sessionKey
        self.showAutoResetFailToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.showAutoResetFailToast = false
            // Don't clear toastSessionKey here — let topic switch or success clear it
        }
    }
}
```

**Files changed:** `SyncBridge.swift`, `SyncBridgeDelegate.swift`, `SyncBridgeObserver.swift`

### Fix 2: Remove dead cooldown code

**Current:** `resetCooldownCount` is decremented on every message but never checked before the usage check. The comment says "always fires, no cooldown check." Q's audit confirmed this is dead code.

**Proposed:** Remove `resetCooldownCount` entirely. In the hybrid model:
- Manual reset has no cooldown by design (user-initiated, always executes)
- Auto-reset at 80% always fires when threshold is met (safety ceiling)

```swift
// REMOVE from SyncBridge:
var resetCooldownCount: [String: Int] = [:]

// REMOVE from sendMessage:
let cooldownLeft = resetCooldownCount[sessionKey] ?? 0
if cooldownLeft > 0 {
    resetCooldownCount[sessionKey] = cooldownLeft - 1
    if cooldownLeft - 1 == 0 {
        resetCooldownCount.removeValue(forKey: sessionKey)
    }
}

// REMOVE from the auto-reset success path:
resetCooldownCount[sessionKey] = cooldown
```

**Also remove from SessionResetManager:**
```swift
// REMOVE:
public var cooldownMessages: Int = 5
```

**Files changed:** `SyncBridge.swift`, `SessionResetManager.swift`

### Fix 3: Add post-reset usage suppression

**New fix (Kieran's review):** After a successful auto-reset, the next message's `sessionsUsage` RPC may still return ≥80% (stale gateway data). This would trigger a second reset + toast.

**Proposed:** Skip the usage check for 1 message after a successful auto-reset.

```swift
// In SyncBridge:
private var skipUsageCheck: Set<String> = []

// After successful auto-reset:
skipUsageCheck.insert(sessionKey)

// Before usage check in sendMessage:
if skipUsageCheck.contains(sessionKey) {
    skipUsageCheck.remove(sessionKey)
    // Skip usage check this message — we just reset, usage must be low
} else if !contextPrepended {
    let usage = try await rpcClient.sessionsUsage(sessionKey: sessionKey)
    // ... existing usage check logic ...
}
```

**Files changed:** `SyncBridge.swift`

### Fix 4: Scope toast and spinner to session key

**Current:** `showAutoResetToast` and `autoResetting` are global booleans that leak across topic switches.

**Proposed:** Replace both with session-key-scoped properties. Kieran's review suggested naming `autoResetSessionKey` → `toastSessionKey` for clarity.

```swift
// SyncBridgeObserver.swift — BEFORE:
@Published var autoResetting: Bool = false
@Published var showAutoResetToast: Bool = false

// AFTER:
@Published var autoResettingSession: String? = nil
@Published var toastSessionKey: String? = nil
@Published var showAutoResetToast: Bool = false
@Published var showAutoResetFailToast: Bool = false

nonisolated func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {
    Task { @MainActor in
        self.autoResettingSession = nil
        self.toastSessionKey = sessionKey
        self.showAutoResetToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.showAutoResetToast = false
            self.toastSessionKey = nil
        }
    }
}
```

**In MainWindow.swift, the `resetIndicator` view:**
```swift
// Spinner — only for the currently selected topic:
} else if syncBridgeObserver.autoResettingSession == messageViewModel.selectedTopic?.sessionKey {
    HStack(spacing: 6) {
        ProgressView()
            .controlSize(.small)
        Text("Refreshing context...")
        // ...
    }

// Success toast — only for the currently selected topic:
} else if syncBridgeObserver.showAutoResetToast,
          syncBridgeObserver.toastSessionKey == messageViewModel.selectedTopic?.sessionKey {
    Text("Session refreshed")
        // ...

// Failure toast — one-shot informational, only for the currently selected topic:
} else if syncBridgeObserver.showAutoResetFailToast,
          syncBridgeObserver.toastSessionKey == messageViewModel.selectedTopic?.sessionKey {
    Text("Context refresh unavailable")
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .transition(.opacity)
}
```

**Clear on topic switch:**
```swift
// In the topic selection handler:
syncBridgeObserver.toastSessionKey = nil
syncBridgeObserver.showAutoResetToast = false
syncBridgeObserver.showAutoResetFailToast = false
```

**Files changed:** `SyncBridgeObserver.swift`, `MainWindow.swift`

### Fix 5: Rename `didAutoReset` → `contextPrepended`

**Current:** `didAutoReset` means "auto-reset fired" OR "manual reset context was injected."

**Proposed:** Rename to `contextPrepended` — it means "context has been prepended to the message text, skip topic context header." Not "an auto-reset happened." (Mel's review: avoids confusion with `contextInjectedKeys`.)

```swift
// BEFORE:
var didAutoReset = false

// AFTER:
var contextPrepended = false
```

**Files changed:** `SyncBridge.swift`

---

## What We're Deferring

### Fix 6 (deferred): Extract auto-reset logic into `SessionResetManager`

**Why defer:** Mel's review identified that the current pseudocode has `didStartAutoReset` firing *after* `attemptAutoReset()` returns, contradicting the spec's requirement that the spinner starts before the async reset. Fixing this requires `attemptAutoReset()` to return a typed enum (`.notNeeded`, `.success(context)`, `.failed`, `.alreadyRunning`) and careful delegate timing. This is valuable structural work but adds complexity to an already substantial change.

**Current plan:** Ship Fixes 1-5 first, then do Fix 6 as a separate cleanup PR once the foundation is solid.

---

## What NOT to do

- **Don't re-add cooldown logic** — it served the old pure-auto model, not the hybrid model
- **Don't add any further state flags beyond `skipUsageCheck`** — this temporary suppression set is the last addition; further complexity should go into the Fix 6 extraction
- **Don't make `SessionResetManager` a god object** — it should only own reset decisions and state, not UI notifications
- **Don't change the toast duration** — 3 seconds is fine, just scope it correctly
- **Don't touch the manual reset flow** — it's working correctly (double-tap guard, pending context, no cooldown)
- **Don't show persistent error UI for `didAutoResetFail`** — the message still sends, it's internal housekeeping; one-shot informational toast only

---

## Implementation Checklist

- [ ] Fix 1: Move `didStopAutoReset` inside success path, add `didAutoResetFail` delegate
- [ ] Fix 1: Add `lastAutoResetFailTime` suppression in `SyncBridgeObserver` (30s per session)
- [ ] Fix 1: Add `showAutoResetFailToast` for one-shot "Context refresh unavailable" toast
- [ ] Fix 2: Remove `resetCooldownCount` and `cooldownMessages` config
- [ ] Fix 3: Add `skipUsageCheck` set for 1-message post-reset suppression
- [ ] Fix 4: Scope `autoResetting` → `autoResettingSession: String?`, toast → `toastSessionKey: String?`, add `showAutoResetFailToast`
- [ ] Fix 4: Update `resetIndicator` to check session key for spinner, success toast, and failure toast
- [ ] Fix 4: Clear scoped toast state on topic switch
- [ ] Fix 5: Rename `didAutoReset` → `contextPrepended`
- [ ] Build passes
- [ ] Manual QA: send message on topic with < 80% usage → no toast
- [ ] Manual QA: send message on topic with ≥ 80% usage → spinner then "Session refreshed" toast
- [ ] Manual QA: reset fails → one-shot "Context refresh unavailable" toast, then 30s spinner/toast suppression
- [ ] Manual QA: switch topics during toast → toast disappears (scoped to session)
- [ ] Manual QA: switch topics during spinner → spinner only on the resetting session's topic
- [ ] Manual QA: manual reset at any usage → works, no cooldown, no toast
- [ ] Manual QA: successful auto-reset followed by immediate next send → no double-reset/toast
- [ ] Manual QA: rapid topic switching → no CPU spin
- [ ] Manual QA: verify `didStartAutoReset` fires BEFORE reset begins (spinner visible)
- [ ] Manual QA: verify `didStopAutoReset` only fires on success
- [ ] Manual QA: verify `didAutoResetFail` shows one-shot failure toast, then 30s suppression

---

## Review Sign-offs

- [x] Q: Implementation feasibility + side effects (earlier audit confirmed architecture, identified root causes)
- [x] Kieran: Failure mode analysis + side effects — **Approved, no blockers**. Minor naming suggestion: `toastSessionKey` for clarity. Documented low-severity edge cases.
- [x] Mel: UX impact + side effects — **Approved**. Failure UX clarified. Fix 6 deferred. `skipUsageCheck` safe for 1 message.
- [ ] Adam: Go/No-go