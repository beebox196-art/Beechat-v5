# BeeChat Session Reset — Design Spec

**Date:** 2026-05-14  
**Author:** Bee (Coordinator)  
**Status:** Draft — Team Review Required  
**Reviewers:** Q (implementation), Kieran (adversarial), Mel (UI)  

---

## Problem

When a topic session exceeds 50% context usage, BeeChat shows a red dot on the topic row. The current codebase has:

1. **Auto-reset logic** in `SyncBridge.sendMessage()` — triggers automatically on send when usage ≥ 50%, fetches last 30 local messages, wraps them as `[SESSION-CONTEXT]`, resets the session, then sends the combined payload. This works but fires **silently during a user message send**, meaning the user has no visibility that it happened.

2. **A tappable red dot** in `SessionRow` — the `onReset` callback is **defined but not wired up** in `MainWindow.swift`. Tapping it does nothing.

3. **A context menu** on the topic row — currently only offers "Delete Topic". No "Reset Session" option exists.

The red dot currently serves only as an indicator. This spec resolves what happens when a session needs resetting, with two options for Adam to choose between.

---

## Option A: Fully Automatic Reset

**Behaviour:** When usage ≥ 50%, the session resets **automatically on the next message send** — no user action required. The red dot is purely informational (or removed entirely since it signals something that already self-resolves).

### What already exists (no changes needed):
- `SyncBridge.sendMessage()` checks `sessionUsageCache` against `redDotThreshold` (0.50)
- If over threshold, calls `resetSession()` → `sessions.reset` RPC
- Fetches last 30 messages via `fetchLocalHistory()`, filters out `[SESSION-CONTEXT]`, `[SESSION-RESET]`, `[TOPIC-CONTEXT]`, and tool-use lines
- Formats as `[SESSION-CONTEXT]` block + user's message
- Sets 5-message cooldown before next auto-reset check
- Delegates `didStartAutoReset` / `didStopAutoReset` to observer (UI can show spinner)

### Changes required for Option A:

| # | File | Change | Lines |
|---|---|---|---|
| 1 | `SessionRow.swift` | Remove the `onReset` callback and the red-dot `Button` block. Red dot serves no purpose if reset is automatic. | ~8 lines removed |
| 2 | `MainWindow.swift` | Remove `sessionUsage` parameter from `SessionRow` construction (no longer needed for UI). | ~1 line changed |
| 3 | `SyncBridgeObserver.swift` | Optionally: show a brief "Session refreshed" toast when `didStopAutoReset` fires, so the user knows it happened. | ~5 lines added |

**Total: ~14 lines changed. 0 new files. 0 structural changes.**

### Risk assessment:
- **Silent data loss risk:** If the 30-message context window misses something important, the user won't know until they notice it's gone. Mitigated by the 100K char budget and topic context re-injection.
- **Cooldown gap:** 5-message cooldown means the 6th message could trigger another reset. This is intentional — prevents reset loops.
- **No user control:** User cannot choose to delay a reset or keep a long session. The trade-off is simplicity vs control.

---

## Option B: Manual Trigger (Red Dot Tap + Context Menu)

**Behaviour:** The red dot appears at 50% as before, but now it's tappable. Right-clicking the topic row also offers "Reset Session". Both trigger the same reset flow (with context summary). Auto-reset in `sendMessage` is **disabled**.

### Changes required for Option B:

| # | File | Change | Lines |
|---|---|---|---|
| 1 | `SyncBridge.swift` | **Disable auto-reset in `sendMessage()`**: Skip the entire usage-check/auto-reset block (lines ~210-248). Keep the methods `resetSession()`, `fetchLocalHistory()`, `formatCombinedContext()` — they're reused by the manual path. | ~35 lines removed/conditional |
| 2 | `SyncBridge.swift` | **Add public `manualReset(sessionKey:)` method** that: (a) aborts any streaming, (b) fetches local history, (c) calls `resetSession()`, (d) stores the context payload for the next send. Returns success/failure. | ~25 lines added |
| 3 | `SyncBridge.swift` | **Modify `sendMessage()`**: If a pending reset context exists for the session, prepend it to the message text (same format as auto-reset). Clear the pending context after use. | ~8 lines added |
| 4 | `MainWindow.swift` | **Wire up `onReset`** on `SessionRow` — call a new reset handler that invokes `syncBridge.manualReset(sessionKey:)`, shows confirmation, and handles success/failure. | ~15 lines added |
| 5 | `MainWindow.swift` | **Add "Reset Session" to context menu** alongside "Delete Topic". Same handler as red dot tap. | ~4 lines added |
| 6 | `SessionRow.swift` | **Keep red dot as tappable button** (already exists, just needs `onReset` wired). No changes needed to this file. | 0 lines |
| 7 | `SyncBridgeObserver.swift` | Add `manualResetting` state (parallel to `autoResetting`) for UI feedback during manual reset. | ~3 lines added |

**Total: ~90 lines changed/added. 0 new files. Moderate structural change to SyncBridge.**

### Risk assessment:
- **More code = more surface area:** Adding a manual reset path with pending state introduces a new state machine (`pendingResetContext` dict in SyncBridge). This must be cleared correctly on success, failure, app restart, and topic switch.
- **Race condition:** User taps reset → session cleared → user types fast and sends before local history is re-fetched. The `manualReset` method must be `async` and the UI should disable input during reset.
- **State persistence:** If the app crashes after reset but before the next send, the pending context is lost. Auto-reset doesn't have this problem because it's atomic with the send.
- **UX clarity:** The red dot + context menu give the user control, but require them to understand what "reset session" means. A brief explanation tooltip or confirmation alert is recommended.

---

## Team Review Questions

1. **Q:** Can the manual reset path in Option B reuse the existing `fetchLocalHistory()` + `formatCombinedContext()` cleanly, or does the pending-state approach introduce coupling that makes `sendMessage` harder to reason about?

2. **Kieran:** Option B adds a `pendingResetContext: [String: String]` dict to SyncBridge. Is this an acceptable state addition, or does it create failure modes (crash between reset and send, topic switch during pending state) that make Option A strictly safer?

3. **Mel:** For Option A, should the red dot be removed entirely, or kept as a subtle indicator (e.g., a small amber dot instead of red) showing "this session was auto-compacted"? For Option B, is a confirmation alert before reset appropriate, or is a one-tap action fine?

4. **All:** Is there a hybrid worth considering? E.g., auto-reset at 80% (hard ceiling, never fail), but the red dot at 50% allows optional early reset. This would give the user the best of both worlds: automatic safety net + manual control when they want it.

---

## Recommendation

**I recommend Option B (manual trigger) with the following reasoning:**

- The auto-reset path already works. The code is tested. We're not removing it — just disabling the automatic trigger and exposing it as a user action.
- Adam has explicitly asked for manual control. The red dot is already built as a button, it just needs wiring.
- The "pending context" concern in Option B is real but manageable: the manual reset can be done **synchronously** (reset + context prep in one step, not split across two user actions). The context payload gets stored in `pendingResetContext` and injected into the very next `sendMessage` call. If the user switches topics before sending, we clear the pending context — simple.
- This is fewer than 100 lines of change. The existing `fetchLocalHistory()`, `formatCombinedContext()`, and `resetSession()` methods are untouched — we're just calling them from a new entry point instead of from inside `sendMessage`.

**However**, if Kieran identifies fatal failure modes in the pending-state approach, I'd fall back to Option A (which has zero new code risk) and accept the lack of manual control.

---

## Files Affected (Both Options)

| File | Option A | Option B |
|---|---|---|
| `SessionRow.swift` | Remove red dot block | No change |
| `MainWindow.swift` | Remove usage param | Wire `onReset`, add context menu item |
| `SyncBridge.swift` | No change | Disable auto-reset, add `manualReset()`, add pending context injection |
| `SyncBridgeObserver.swift` | Optional toast | Add `manualResetting` state |
| `SessionResetManager.swift` | No change | No change |

---

## Decision Required

Adam to choose: **Option A** (fully automatic, red dot removed) or **Option B** (manual trigger via red dot tap + context menu).

Pending team review feedback on the hybrid question.