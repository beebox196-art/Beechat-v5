# FR-005: Reset Marker Threshold + Visual Confirmation

**Priority:** Standard
**Status:** Spec — ready for implementation Saturday 2026-07-04
**Author:** Bee (synthesised from FR-004-FEEDBACK thread, #14341, #14342)
**Date:** 2026-07-03
**Predecessor:** FR-004 (urgent delete confirm), invisible-failure investigation 2026-07-03
**Related:**
- `Docs/Bugs/session-reset-general-topic.md` — prior reset-bug history
- `.review/diagnostic-session-reset.md` — Jun 11 data-source split analysis
- `Sources/BeeChatSyncBridge/SyncBridge.swift:587-672` — `manualReset` implementation

## Problem

Two related UX failures on the session-reset path:

1. **No confirmation on reset success.** When Adam taps "Reset" in the confirmation alert, the orange dot disappears momentarily, then reappears as the user continues the conversation and `totalTokens` climbs back above the 50% threshold. From his perspective: *"the reset didn't work."* Two investigations this week (Jul 1–3) both blamed a reset bug — but the reset pipeline (commit `20ad14a`, Jun 16) is intact and functioning correctly. The signal of failure was the absence of any "reset complete" feedback.

2. **50% threshold is too sensitive.** A session Adam deliberately continues to use immediately after a reset re-acquires the orange dot within minutes, even though the reset itself was correct. The threshold is meant to flag sessions that have grown unwieldy; 50% fires on sessions that are merely active.

## Solution

Two surgical changes that fit inside the existing reset pipeline. No new packages, no schema changes, no sync work.

### A. Reset confirmation: transient green checkmark

Replace the orange dot with a green checkmark for ~2 seconds after `manualReset` completes successfully, then return to the normal state (dot hidden because `totalTokens == NULL`, or absent because usage is below threshold).

**Visual:**
- Same 10×10 dot geometry in the SessionRow trailing area
- Fill colour: sage green `#6BBF8A` (matches `healthColor` healthy state for visual consistency — already a defined palette colour)
- Optional gentle shadow `color: Color.green.opacity(0.3), radius: 3` (mirror the orange-dot shadow for consistency)
- `Image` variant of `checkmark.circle.fill` was considered — rejected. A plain green circle matches the orange dot's silhouette, so the user's eye reads it as a "state change" not a "different element."
- Transition: instant swap, no animation. The eye needs to catch it; an animated transition risks being missed. The 2-second dwell is the feedback.

**Mechanism:**
- Add a new transient UI state on `SessionRow`: `recentlyReset: Bool` (default `false`)
- On reset completion (post-`bridge.manualReset(...).await` in `ResetSessionAlertModifier.body`, `MainWindow.swift:879-886`), set `recentlyReset = true` for the row that was reset, schedule a 2-second `Task.sleep`, then `recentlyReset = false`
- State must live at the `MessageViewModel` / row-binding layer (not in `manualReset` itself — SyncBridge stays pure) so the existing actor isolation doesn't need to be touched
- Recommended shape: add `recentlyResetKeys: Set<String>` on `MessageViewModel` with `markRecentlyReset(sessionKey:)` and an internal `Task` that removes after 2s. `SessionRow` reads `messageViewModel.recentlyResetKeys.contains(topic.sessionKey)` and overrides `shouldShowResetDot` accordingly
- While `recentlyReset` is true, show green dot instead of orange, regardless of `sessionUsage`. Side-effect: the row's accessibility label changes to "Session reset complete"

**Why not a macOS toast / banner?** Toast would land at the top of the window and require attention to read. The inline dot swap is visible in the sidebar where the user is already looking. Less intrusive, less code, no new modifiers.

### B. Threshold: 50% → 70%

Single constant change.

- `shouldShowResetDot` (`Sources/App/UI/Components/SessionRow.swift:48-51`):
  - Currently: `usage >= 0.50`
  - After: `usage >= 0.70`
- No other consumers. `MessageViewModel` derives usage as `min(totalTokens / 200_000.0, 1.0)` (`Sources/App/UI/Components/MessageViewModel.swift:194-209`); the threshold is a UI-only gate.
- Tooltip text "Session at NN% — tap to reset" continues to work — it reads the live `sessionUsage ?? 0` so no separate update needed.
- Does NOT affect the auto-reset trigger (separate code path at 80%, `resetSession` in SyncBridge). This is purely a marker-display threshold.

## Trigger

User-initiated only. No automatic / scheduled / sync-triggered changes.

## Scope

### In scope

- `Sources/App/UI/Components/SessionRow.swift` — `shouldShowResetDot`, the orange-dot Button block, replace with conditional on `recentlyReset` vs `shouldShowResetDot`
- `Sources/App/UI/MainWindow.swift` — pass reset-success signal into `MessageViewModel`
- `Sources/App/UI/MessageViewModel.swift` — `recentlyResetKeys: Set<String>`, `markRecentlyReset(sessionKey:)`, internal 2-second clear task
- `Tests/` — new unit tests for `recentlyResetKeys` lifecycle
- Spec doc — this file

### Out of scope

- SyncBridge / BeeChatSyncBridge / BeeChatPersistence — no changes; the reset pipeline at commit `20ad14a` is intact and verified
- Auto-reset threshold (still 80% in `resetSession`)
- Mobile (iOS) app — deferred; BeeChat-Mobile is a separate project and this UI feedback is macOS-specific
- Notifications / iMessage-style banner — rejected as over-engineering for one orange dot
- Carry-over context UX verification — separate diagnostic; the pendingResetContext path at `SyncBridge.swift:624-628` is not touched by this spec
- Kieran's `sessions.changed` race hypothesis — separate diagnostic; the race could exist but did not fire in the Jul 1–3 incidents and is not addressed by this spec

## Validation

### Build

- Swift build via project standard (`swift build` or Xcode build script)
- 380 existing tests + 4 new tests for `recentlyResetKeys` must still pass

### New tests (`Tests/BeeChatTests/MessageViewModelTests.swift` or equivalent)

1. `markRecentlyReset_sessionKeyIsTracked`: call `markRecentlyReset(sessionKey: "abc")`, assert `recentlyResetKeys.contains("abc") == true`
2. `markRecentlyReset_expiresAfter2Seconds`: same as above, advance clock by 2.1s, assert `recentlyResetKeys.contains("abc") == false`
3. `markRecentlyReset_multipleKeysConcurrent`: mark three keys, wait 2.1s, assert all three cleared (no leaks)
4. `recentlyResetKeys_doesNotAffectSessionUsageMap`: confirm `markRecentlyReset` does not touch the `sessionUsageMap` (purely UI state)

### Live validation against 3D Model Extraction topic

The topic "3D Model Extraction" is currently showing the orange marker (per Adam's confirmation #14342). After build:
1. Quit BeeChat; relaunch `open /Applications/BeeChatApp.app`
2. Tap orange dot on 3D Model Extraction → confirm alert → tap "Reset"
3. Verify green dot appears within ~100ms, lasts ~2s, then disappears (because `totalTokens = NULL` and usage drops to nil)
4. Continue conversation in topic; observe when orange dot re-appears. At 70% threshold, that's ~140,000 tokens — meaningful headroom from the current 113,674.
5. Verify on a fresh, small session: no false orange dot at <70% usage.

### Code review

Standard tier → structured code review via `scripts/review/code-review.sh` against the diff before commit.

## Risk

**Low.** Changes are isolated to UI feedback and a threshold constant. Both:
- Are reversible in seconds (one-line revert, no schema impact)
- Have no sync / cross-device surface (SyncBridge untouched)
- Don't change any user-initiated behaviour beyond the visual feedback they're now receiving
- Don't depend on the disputed race condition Kieran's review identified

The only live risk is: the green checkmark is missed if the user isn't looking at the sidebar at the exact moment it appears. Mitigation: its 2-second dwell is longer than a typical notification glance-away, and it replaces the orange dot in-place rather than appearing elsewhere.

## Open / deferred

- Carry-over context verification: separate diagnostic. Will park until asked.
- `sessions.changed` race falsification: three diagnostics from Kieran's review, none implemented yet. Park unless resurfaces.
- iOS parity: out of scope. Mobile app topic-reset UX will lag until BeeChat-Mobile Phase 1 (per MEMORY.md "Gate 2F Phase 0 complete, Phase 1 next").
- If the green-dot UX is approved and feels right in the sidebar, consider the same pattern for other "completed action" confirmations (delete topic, archive topic, etc.) in a future FR.
