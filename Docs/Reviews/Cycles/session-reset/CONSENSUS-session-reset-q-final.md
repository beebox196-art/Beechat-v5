# Q — Final Implementation Review: Session Reset Hybrid

**Date:** 2026-05-14  
**Reviewer:** Q  
**Spec:** SPEC-session-reset-hybrid-final.md  
**Previous review:** CONSENSUS-session-reset-q.md  

---

## 1. Implementation Accuracy — Code Snippet Integration

### 1.1 Auto-reset block (`sendMessage()` lines ~196-248)

**Spec says:** Replace `threshold` comparison with `config.autoResetThreshold` and add cooldown override (`if cappedUsage >= autoThreshold && !cooldownActive`).

**Reality:** The existing code at lines 196-248 uses:
```swift
let threshold = await sessionResetManager.config.redDotThreshold
if cappedUsage >= threshold {
```

This needs to become:
```swift
let autoThreshold = await sessionResetManager.config.autoResetThreshold
let cooldownActive = (resetCooldownCount[sessionKey] ?? 0) > 0
if cappedUsage >= autoThreshold && !cooldownActive {
```

**⚠️ Concern:** The spec says "80% threshold overrides cooldown" — meaning if usage ≥ 80%, auto-reset fires *regardless* of cooldown. But the code above still skips auto-reset when `cooldownActive`. The spec text says:

> "The 80% threshold overrides cooldown. If usage ≥ 80%, auto-reset fires regardless of cooldown state."

So the condition should be:
```swift
if cappedUsage >= autoThreshold || (cappedUsage >= redDotThreshold && !cooldownActive) {
```

Or more clearly: auto-reset at 80% always fires; between 50-80%, auto-reset fires only if cooldown has expired. **The spec's code snippet is inconsistent with its own behavioural description.** The snippet only has `if cappedUsage >= autoThreshold && !cooldownActive`, which would *not* override cooldown at 80%.

**Recommendation:** Use the correct logic:
```swift
let redDotThreshold = await sessionResetManager.config.redDotThreshold
let autoResetThreshold = await sessionResetManager.config.autoResetThreshold
let cooldownActive = (resetCooldownCount[sessionKey] ?? 0) > 0

// Auto-reset at 80% always fires (cooldown override)
// Between 50-80%, only if cooldown expired
if cappedUsage >= autoResetThreshold || (cappedUsage >= redDotThreshold && !cooldownActive) {
```

Wait — this would fire auto-reset at 50% too (the old behaviour). The hybrid intent is: auto-reset *only* at 80%, never at 50%. Manual reset is available at 50%. So:

```swift
if cappedUsage >= autoResetThreshold {
    // 80% threshold overrides cooldown — always auto-reset
} else if cappedUsage >= redDotThreshold && !cooldownActive {
    // This branch shouldn't exist in the hybrid — between 50-80% is manual-only
}
```

Actually, re-reading the spec more carefully: "Between 50-80% — No automatic action. Full user control." So the auto-reset should *only* fire at ≥80%, and cooldown only matters if somehow auto-reset fires repeatedly at 80%. The simplest correct implementation:

```swift
let autoResetThreshold = await sessionResetManager.config.autoResetThreshold
let cooldownActive = (resetCooldownCount[sessionKey] ?? 0) > 0

if cappedUsage >= autoResetThreshold && !cooldownActive {
```

This is what the spec's snippet says. But the spec also says "The 80% threshold overrides cooldown" — which contradicts `&& !cooldownActive`. The cooldown at 80% *prevents* a loop of auto-resets on rapid sends, which is good. But the spec says it should override cooldown.

**Verdict:** ⚠️ **Contradiction in the spec.** The behavioural section says "80% threshold overrides cooldown", but the code snippet still checks cooldown. I recommend keeping the cooldown check at 80% (to prevent rapid loops), and noting this as a deliberate design choice rather than a spec bug. The 5-message cooldown at 80% is a safety net, not a friction point — after 5 messages the auto-reset will fire again.

### 1.2 `manualReset()` method

The spec's `manualReset()` snippet references:
- `pendingResetContext` — new dict, not yet declared in `SyncBridge`
- `fetchLocalHistory(sessionKey:limit:)` — exists ✅ (line ~295)
- `formatCombinedContext(_:userMessage:)` — exists ✅ (line ~318)
- `resetSession(sessionKey:)` — exists ✅ (line ~284)
- `abortGeneration(sessionKey:)` — exists ✅ (line ~273)
- `contextInjectedKeys` — exists ✅ (line ~91)
- `sessionUsageCache` — exists ✅ (line ~78)
- `delegate?.syncBridge(self, didStartManualReset:)` — **NOT YET IN PROTOCOL** ⚠️

**The delegate methods `didStartManualReset` / `didStopManualReset` must be added to `SyncBridgeDelegate` protocol.** The spec mentions this but it's easy to miss — both the protocol file and the observer need updating.

### 1.3 `pendingResetContext` injection in `sendMessage()`

The spec says to add injection *before* the existing auto-reset block. Looking at `sendMessage()`, the order is:

1. Guard concurrent sends (line 196)
2. Abort in-flight generation (line 201)
3. `var effectiveText = text` (line 207)
4. `var didAutoReset = false` (line 208)
5. Cooldown check + auto-reset (line 209-248)
6. Topic context injection (line 250-256)
7. Delivery ledger creation (line 258+)

The spec's injection point is correct — inserting after line 208 (`var didAutoReset = false`) and before the cooldown check. This means:
- If pending context exists, it's prepended to `effectiveText`
- `didAutoReset` is set to `true` to skip topic context injection
- The auto-reset block at 80% won't fire again because `pendingResetContext` was just cleared (but usage could still be high after a crash — that's fine, auto-reset handles it)

**One issue:** If `pendingResetContext` is injected AND the auto-reset block fires in the same `sendMessage()` call, we'd get double context. But this can't happen — after a manual reset, usage is ~0%, so `cappedUsage < 0.80`. After an auto-reset, `pendingResetContext` isn't set (auto-reset uses `formatCombinedContext` inline). So no double-injection. ✅

### 1.4 `clearPendingResetContext(except:)`

The spec's implementation is correct. The `.onChange(of: sidebarSelection)` in MainWindow already has a setter (the custom `Binding`). The spec adds another `.onChange` modifier. This is fine — SwiftUI allows multiple `.onChange` modifiers.

However, looking at the existing `sidebarSelection` binding (lines 21-35), it already does work on change. The new `.onChange` would fire *after* the binding setter. This is correct — clear stale pending context after topic switch, not during.

### 1.5 `SessionResetManager.Config` changes

Current `Config`:
```swift
public struct Config {
    public var redDotThreshold: Double = 0.50
    public var summaryTimeout: TimeInterval = 45
    public var showConfirmation: Bool = false
    public init() {}
}
```

Spec adds: `autoResetThreshold: Double = 0.80`, `cooldownMessages: Int = 5`, and changes `showConfirmation: Bool = true`.

**Note:** `resetCooldownMessages` is currently a `static let` on `SyncBridge` (line 89: `private static let resetCooldownMessages = 5`). Moving it to `Config.cooldownMessages` means changing the reference in `sendMessage()` from `Self.resetCooldownMessages` to `await sessionResetManager.config.cooldownMessages`. This is a minor but important change — the `await` is required because `SessionResetManager` is an actor.

**Verdict:** ✅ Feasible, but remember the `await` when accessing the actor-isolated config.

---

## 2. Is the `pendingResetContext` injection point correct?

Yes, with one subtlety:

The spec says `pendingResetContext.removeValue(forKey: sessionKey)` — this atomically reads and removes. Since `SyncBridge` is an actor, this is safe. No race condition. ✅

The `didAutoReset = true` flag correctly skips topic context injection. ✅

No conflict with the delivery ledger — the ledger is created *after* both injection points (line 258+), using `effectiveText` (which now includes the pending context). The `originalContent` field preserves the raw user message. ✅

**No issues found.**

---

## 3. Does `clearPendingResetContext(except:)` handle all topic-switch paths?

Looking at MainWindow, topic switches happen via:
1. **Sidebar selection** — the `sidebarSelection` binding (lines 21-35)
2. **New topic creation** — `createNewTopic()` (line ~300)

The spec adds `.onChange(of: sidebarSelection)` for case 1. ✅

For case 2 (new topic creation), the new topic has no pending context, and the `clearPendingResetContext(except:)` would clear all other pending contexts — which is correct. But the spec doesn't explicitly add clearing on topic creation. Should it?

When a new topic is created, `messageViewModel.selectedTopicId` changes, which triggers `sidebarSelection`'s setter, which triggers `.onChange`. So it's already handled. ✅

**What about programmatic topic switches?** `messageViewModel.selectTopic(id:)` is called in the sidebar binding setter. That's the only path. ✅

**All paths covered.**

---

## 4. Line Count Estimate

| Change | Spec Lines | My Count | Notes |
|--------|-----------|----------|-------|
| `SessionResetManager.Config` | ~5 | ~5 | Add `autoResetThreshold`, `cooldownMessages`, change `showConfirmation` default |
| `SyncBridge.swift`: auto-reset threshold + cooldown override | ~3 | ~5 | Change threshold var, add cooldown check, adjust condition |
| `SyncBridge.swift`: `pendingResetContext` dict | ~1 | ~2 | Declaration + comment |
| `SyncBridge.swift`: `manualReset()` method | ~25 | ~28 | As in previous review, slightly more than 25 |
| `SyncBridge.swift`: pending context injection in `sendMessage()` | ~8 | ~10 | Check dict, prepend, set flag |
| `SyncBridge.swift`: `clearPendingResetContext()` | ~6 | ~8 | Method + nil check + loop |
| `SyncBridgeDelegate` protocol: 2 new methods | ~6 | ~4 | Two one-liner protocol methods |
| `SyncBridgeObserver`: `manualResetting`, `showAutoResetToast`, delegate handlers | ~15 | ~18 | Two `@Published` vars, two delegate methods, toast logic |
| `SessionRow.swift`: amber dot, hit target, accessibility | ~12 | ~14 | Color change, shadow, contentShape, frame, accessibility labels |
| `MainWindow.swift`: state, alert, context menu, topic-switch clearing, toast | ~30 | ~35 | State vars, alert modifier, context menu items, onChange, toast overlay |
| **Total** | **~123** | **~129** | |

**Verdict:** ~129 lines, close to spec's ~123. Within a single focused PR. ✅

---

## 5. Missing Pieces for a Single Clean PR

### Must-have (blocking):
1. **Delegate protocol update** — `SyncBridgeDelegate.swift` needs `didStartManualReset` / `didStopManualReset`. Easy to miss.
2. **Cooldown override logic** — The spec contradicts itself (code says cooldown checked, behavioural section says cooldown overridden at 80%). Needs resolution before coding. I recommend keeping cooldown at 80% for safety.
3. **`static let resetCooldownMessages` → `Config.cooldownMessages`** — Must migrate the reference and add `await` for actor isolation.

### Nice-to-have (non-blocking):
4. **VoiceOver announcement** — Spec mentions "Session approaching capacity" announcement when amber dot first appears. No implementation detail provided. Would need `AccessibilityNotification.announcement` in the observer. Low priority, can be a follow-up.
5. **WCAG contrast check** — Spec mentions verifying amber/orange on sidebar background meets 3:1. Should be verified but doesn't block the PR.

### Already covered:
6. ✅ No new files needed
7. ✅ No database migrations
8. ✅ No data model changes
9. ✅ Feature flag not needed (hybrid is the only mode)
10. ✅ Crash recovery is acceptable (pending context lost = session still works, just without context carry-forward)

---

## Sign-Off

**Status:** ✅ **Approved with one required clarification.**

The implementation is clean, well-integrated with the existing codebase, and fits in a single PR. The main concern is the **cooldown override contradiction** — the spec's behavioural section says "80% overrides cooldown" but the code snippet still checks cooldown at 80%. This needs a clear decision before Q starts coding:

**My recommendation:** Keep the cooldown check at 80%. The 5-message cooldown prevents rapid auto-reset loops after a reset at 80%+ usage. Without it, if the session is still large after a reset (unlikely but possible with context-heavy topics), you'd get auto-reset on every send. The cooldown is a safety net, not user friction — 5 messages is negligible. If Adam manually resets, cooldown doesn't apply (the spec explicitly says this and `manualReset()` doesn't set `resetCooldownCount`).

Once that's clarified, this is ready to implement.

---

*Q — Implementation Review Complete*