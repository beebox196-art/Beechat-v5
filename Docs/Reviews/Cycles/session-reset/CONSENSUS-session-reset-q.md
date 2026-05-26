# Q — Implementation Review: Session Reset Options

**Date:** 2026-05-14  
**Reviewer:** Q  
**Spec:** SPEC-session-reset-options.md  

---

## 1. Can `manualReset()` cleanly reuse `fetchLocalHistory()` + `formatCombinedContext()` without refactoring?

**Yes, cleanly.** Both methods are already well-factored for reuse:

- `fetchLocalHistory(sessionKey:limit:)` is a pure synchronous read from local SQLite (no network, no side effects). It takes a session key and limit, returns `[Message]`. Calling it from `manualReset()` is identical to calling it from `sendMessage()`.

- `formatCombinedContext(_:userMessage:)` is a pure function — takes messages + a string, returns a formatted string. No state, no side effects. Trivially reusable.

- `resetSession(sessionKey:)` is a thin wrapper around `rpcClient.sessionsReset()` plus clearing `contextInjectedKeys`. Also directly callable from `manualReset()`.

**One subtlety:** `fetchLocalHistory` is currently `throws` synchronous (reads from GRDB), while `manualReset` will be `async throws` because `resetSession` calls the RPC. The composition works fine — just call the sync `fetchLocalHistory` first, then the async `resetSession`, then store the result. No refactoring needed.

**Verdict:** ✅ Clean reuse. No coupling issues.

---

## 2. Where should `pendingResetContext` live?

The spec suggests `pendingResetContext: [String: String]` in `SyncBridge`. This is correct and the best location. Here's why:

**SyncBridge is the right owner because:**
- It's already the actor that owns the reset flow (`resetSession`, `fetchLocalHistory`, `formatCombinedContext`).
- It's the actor that owns `sendMessage()` — the only place the pending context gets consumed.
- It's already an `actor`, so access to the dict is automatically serialized. No race conditions.
- The lifecycle is simple: `manualReset()` writes it, `sendMessage()` reads and clears it.

**Why not in SessionResetManager:**
- `SessionResetManager` is currently just a config holder (one `Config` struct). Adding mutable state there would be a design change for no benefit — SyncBridge already has all the collaborators it needs.
- `SessionResetManager` is also an actor, so it *could* hold it, but then `sendMessage` would need to call across actor boundaries for no reason. Keep the state where it's consumed.

**Crash-between-reset-and-send concern:** The spec raises this. Since SyncBridge is an actor, the sequence `manualReset() → stores pendingResetContext → user sends → sendMessage reads + clears` is atomic within the actor's isolation. The only crash risk is a full process crash, which would lose the pending context anyway. On app relaunch, the session is already reset (RPC was sent), and the pending context is gone — the user just sends their next message without context carry-forward. This is acceptable; auto-reset has the same problem if the process crashes between RPC calls.

**Topic switch during pending state:** Simple solution — when the user selects a different topic in `sidebarSelection`, if there's a pending reset context for the *previous* topic, clear it. This is a one-line guard in `sidebarSelection`'s setter. The reset RPC already fired; clearing the pending context just means the next send on that topic won't include the context summary. Again, acceptable — the session was already reset.

**Recommendation:** `private var pendingResetContext: [String: String] = [:]` in `SyncBridge`. Clear on topic switch. No other location is warranted.

---

## 3. Is the ~90 line estimate accurate, or are there hidden changes?

The spec's line counts are roughly right but slightly underestimate in a couple of areas. Here's my detailed count:

| # | Change | Spec Estimate | My Estimate | Notes |
|---|--------|--------------|-------------|-------|
| 1 | Disable auto-reset block in `sendMessage()` | ~35 lines removed/conditional | ~35 lines | The block spans lines 210-248 (~38 lines). Wrapping in a feature flag (`isManualResetEnabled` bool) instead of deleting is better for the hybrid option. If we flat-delete, ~38 lines removed. If we feature-flag, ~3 lines added (the conditional). |
| 2 | `manualReset(sessionKey:)` method | ~25 lines added | ~30 lines | Need: abort streaming (~4), fetch history (~2), call resetSession (~2), store pending context (~2), delegate notifications (~4), error handling (~4), signature/braces (~6), cooldown set (~2), return type (~2). Slightly more than 25. |
| 3 | Pending context injection in `sendMessage()` | ~8 lines added | ~10 lines | Check dict, prepend, clear. Plus a guard for topic context interaction with pending reset (skip topic context if pending reset already includes context). |
| 4 | Wire `onReset` in `MainWindow` | ~15 lines added | ~20 lines | Need: handler function (~8), alert confirmation (~6), loading state (~3), error handling (~3). SwiftUI boilerplate adds up. |
| 5 | Context menu "Reset Session" | ~4 lines added | ~6 lines | Button + role + action. Minor. |
| 6 | `SyncBridgeObserver` state | ~3 lines added | ~5 lines | `@Published var manualResetting = false` + start/stop notifications from delegate callbacks. |
| 7 | Topic-switch clearing of pending context | Not counted | ~3 lines | Guard in sidebar selection setter. |
| 8 | UI: "Resetting session…" indicator | Not counted | ~8 lines | Similar to the existing `autoResetting` indicator in MainWindow. |

**Total: ~115-120 lines changed/added.** The spec's ~90 is achievable if you're aggressive about keeping the UI minimal (no confirmation alert, no loading state). But for production quality, ~115 is more realistic.

**Hidden changes the spec misses:**
- **Topic-switch clearing** (~3 lines) — necessary to avoid stale pending context.
- **UI reset indicator** (~8 lines) — the `autoResetting` indicator already exists; a `manualResetting` one parallels it.
- **Feature flag** in `SessionResetManager.Config` — needed for the hybrid option and general toggling.

---

## 4. Does disabling auto-reset in `sendMessage()` leave any dead code paths?

**Yes, but they're minor and self-contained.** Here's what becomes unreachable:

| Code | Dead if auto-reset disabled? | Concern? |
|------|------------------------------|----------|
| `resetCooldownCount` dict + decrement logic | Yes, if fully removed | Low — it's 2 properties and ~10 lines. If feature-flagged instead of deleted, the cooldown logic stays active for manual mode. |
| `sessionUsageCache` + `pollSessionUsage` + `startUsagePolling` | **No** — still needed for the red dot indicator even with manual reset | None. Usage polling must continue regardless. |
| `didStartAutoReset` / `didStopAutoReset` delegate methods | Yes, if auto-reset is disabled | Low — 2 delegate methods. Can be repurposed for `didStartManualReset`/`didStopManualReset` or removed. |
| `contextInjectedKeys` + topic context injection block | **No** — still needed for new topic context injection | None. |

**Recommendation:** Don't delete the auto-reset block. Feature-flag it:

```swift
// In SessionResetManager.Config
var manualResetOnly: Bool = true  // true = Option B, false = Option A

// In sendMessage(), line ~210:
if !await sessionResetManager.config.manualResetOnly {
    // existing auto-reset block
}
```

This avoids dead code entirely and makes the hybrid option trivial. The cooldown logic and delegate methods stay live and are reused by `manualReset()`.

---

## 5. Hybrid option (auto at 80%, manual at 50%) — implementation diff from Option B

The hybrid is **Option B + one config change + one threshold change**. Specifically:

| What changes from Option B → Hybrid | Lines |
|--------------------------------------|-------|
| `SessionResetManager.Config` gets `manualResetOnly: Bool = false` (default auto+manual) | ~1 line |
| `SessionResetManager.Config.redDotThreshold` stays at `0.50` (red dot at 50%) | 0 lines — already correct |
| Add `autoResetThreshold: Double = 0.80` to Config | ~1 line |
| In `sendMessage()`, replace `cappedUsage >= threshold` with `cappedUsage >= config.autoResetThreshold` | ~1 line |
| Wrap the auto-reset block in `if !config.manualResetOnly` (or `if config.autoResetEnabled`) | ~3 lines |
| `manualReset()` method stays exactly the same | 0 lines |

**Total diff from Option B: ~6 lines.** The hybrid is essentially free if you feature-flag the auto-reset block instead of deleting it.

**Behavioural summary of the hybrid:**
- At 50% usage → red dot appears, user can tap to manually reset.
- At 80% usage → auto-reset fires on next send (with cooldown).
- User always has manual control via red dot + context menu.
- If user manually resets at 50%, cooldown resets — they won't get auto-reset again for 5 messages.

**One design question:** Should the cooldown apply to manual resets too? I'd say **no** — the cooldown exists to prevent auto-reset loops. If the user explicitly requests a reset, it should always work. The `manualReset()` method should NOT check or set `resetCooldownCount`.

---

## Summary Verdict

| Question | Answer |
|----------|--------|
| 1. Clean reuse? | ✅ Yes. `fetchLocalHistory` and `formatCombinedContext` are pure/reusable as-is. |
| 2. `pendingResetContext` location? | `SyncBridge` (actor-isolated dict). Clear on topic switch. No other location warranted. |
| 3. Line count estimate? | ~115-120 lines, not ~90. Spec misses topic-switch clearing, UI indicator, and feature flag boilerplate. |
| 4. Dead code paths? | Minor — only `resetCooldownCount` and auto-reset delegate methods. **Feature-flag instead of deleting** to avoid dead code and enable the hybrid. |
| 5. Hybrid diff from Option B? | ~6 lines. Feature-flag the auto-reset block, add `autoResetThreshold = 0.80` to Config. Essentially free. |

**Overall recommendation:** Build Option B with the feature-flag approach (not deletion), and set the config to `manualResetOnly = true` by default. This makes the hybrid a one-line config flip. The ~115-line estimate is still well within a single focused PR.