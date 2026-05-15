Updated: 2026-05-14T11:05:00Z
From/To: Q → Bee
Task: Session Reset Hybrid (manual at 50%, auto at 80%) — Implementation complete, build passing
State: All code changes implemented. Build compiles. Ready for QA testing.
Next: Adam to launch BeeChat and test manual reset (amber dot + context menu) and verify auto-reset at 80%
Blockers: None

## Changes Made

### SessionResetManager.swift
- Added `autoResetThreshold: Double = 0.80` (safety ceiling, overrides cooldown)
- Added `cooldownMessages: Int = 5` (migrated from static let on SyncBridge)
- Changed `showConfirmation` default to `true`

### SyncBridge.swift
- Removed `static let resetCooldownMessages = 5` (moved to Config)
- Added `pendingResetContext: [String: String]` dict for manual reset context carry-forward
- Changed auto-reset threshold from `redDotThreshold` (50%) to `autoResetThreshold` (80%)
- Removed cooldown check for 80% path (safety ceiling always fires)
- Added `manualReset(sessionKey:)` — user-triggered reset with context carry-forward, no cooldown
- Added `clearPendingResetContext(except:)` — clears stale context on topic switch
- Added pending context injection in `sendMessage()` — consumed once, skips topic context if already present
- Added `didStartManualReset`/`didStopManualReset` delegate calls
- Added documentation comment to `fetchLocalHistory()` about local-only coupling

### SyncBridgeDelegate.swift
- Added `didStartManualReset` and `didStopManualReset` protocol methods

### SyncBridgeObserver.swift
- Added `manualResetting: Bool` state for UI
- Added `showAutoResetToast: Bool` state (auto-dismisses after 3 seconds)
- Added delegate handlers for manual reset start/stop
- Updated `didStopAutoReset` to set toast flag

### SessionRow.swift
- Changed `shouldShowRedDot` → `shouldShowResetDot` (clarity)
- Changed red dot → amber/orange dot (`Color.orange` + amber shadow)
- Added `.contentShape(Rectangle()).frame(width: 24, height: 24)` for 24pt hit target
- Added `.accessibilityLabel("Unread messages")` on unread dot
- Updated accessibility label for reset dot to "Session at X% — tap to reset"
- Added reset state to combined accessibility label

### MainWindow.swift
- Extracted `sidebarList` and `resetIndicator` into `@ViewBuilder` properties (reduces body complexity)
- Wired `onReset` on SessionRow (triggers confirmation alert)
- Added "Reset Session" context menu item with Divider before "Delete Topic"
- Context menu "Reset Session" disabled when usage < 50%
- Added `showResetAlert` and `resetTargetSessionKey` state
- Added `ResetSessionAlertModifier` (ViewModifier) for confirmation alert
- Added `.onChange(of: selectedTopicId)` for clearing stale pending reset context
- Added "Resetting session..." indicator for manual reset
- Added "Session refreshed" toast for auto-reset completion

## Testing Checklist
- [ ] Amber dot appears at ≥50% usage
- [ ] Amber dot tap → confirmation alert → Reset performs manual reset
- [ ] Amber dot tap → Cancel dismisses
- [ ] Context menu: "Reset Session" appears, disabled when under 50%
- [ ] Context menu: Divider between Reset and Delete
- [ ] Manual reset: "Resetting session..." indicator shows during reset
- [ ] Manual reset: context carried forward on next send ([SESSION-CONTEXT] visible)
- [ ] Manual reset: amber dot disappears, usage drops to ~0%
- [ ] Manual reset: double-tap guard (second tap does nothing)
- [ ] Auto-reset at 80%: fires on next send, shows "Refreshing context..." then "Session refreshed" toast
- [ ] Auto-reset: cooldown doesn't block the 80% threshold
- [ ] Topic switch clears pending context for previous topic
- [ ] Accessibility: combined label includes usage percentage and "reset available"

Files: Sources/BeeChatSyncBridge/SessionResetManager.swift, Sources/BeeChatSyncBridge/SyncBridge.swift, Sources/BeeChatSyncBridge/Protocols/SyncBridgeDelegate.swift, Sources/App/UI/Observers/SyncBridgeObserver.swift, Sources/App/UI/Components/SessionRow.swift, Sources/App/UI/MainWindow.swift