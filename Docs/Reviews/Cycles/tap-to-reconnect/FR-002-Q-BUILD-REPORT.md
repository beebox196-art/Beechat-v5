# FR-002 Tap-to-Reconnect — Q Build Report

**Date:** 2026-06-19
**Builder:** Q
**Branch:** `feature/FR-002-tap-to-reconnect` (from `develop`)
**Commit:** `f8d09c3` — `feat: add tap-to-reconnect on GatewayStatusBar (FR-002)`

## Files Changed

| File | Change | Lines |
|---|---|---|
| `Sources/App/AppRootView.swift` | Added `connectionStateTask` property + `reconnect()` method to `AppState` | +57, -0 |
| `Sources/App/UI/Components/GatewayStatusBar.swift` | Added `isTappable`, arrow icon, `.contentShape(Rectangle())`, `.onTapGesture`, dynamic accessibility hint | +23, -1 |

**Total:** 2 files, 80 insertions, 1 deletion.

## What Was Implemented

### AppState (AppRootView.swift)

1. **`connectionStateTask` property** — `private var connectionStateTask: Task<Void, Never>?` stores the active connection state stream subscription for cancellation on reconnect.

2. **`reconnect()` method** — Follows the spec exactly:
   - Guard 1: `syncBridge != nil` (no bridge → no-op)
   - Guard 2: `connectionState != .connecting && != .handshaking` (already reconnecting → no-op)
   - Sets `connectionState = .connecting` **synchronously** before any `await` (Kieran MAJOR #1)
   - Clears stale error state
   - Stops existing bridge
   - Cancels old `connectionStateTask` before creating new bridge (Kieran MAJOR #2)
   - Rebuilds `GatewayClient` + `SyncBridge` using existing `loadGatewayConfig`
   - Starts new bridge, sets `.connected`, creates new `connectionStateTask`

### GatewayStatusBar.swift

1. **`isTappable` computed property** — `appState.isStartupComplete && (.disconnected || .error)` (Kieran MINOR #1)
2. **Arrow icon** — `Image(systemName: "arrow.clockwise")` at 10pt, shown only when tappable
3. **`.contentShape(Rectangle())`** — full width tappable
4. **`.onTapGesture`** — calls `appState.reconnect()` only when `isTappable`
5. **Dynamic accessibility hint** — "Tap to reconnect" when tappable, "Current gateway connection status" otherwise

## Build Result

```
xcodebuild -scheme BeeChatApp -configuration Debug -destination 'platform=macOS' build
** BUILD SUCCEEDED **
```

Clean build, no warnings, no errors.

## Test Result

```
xcodebuild -scheme BeeChatApp -destination 'platform=macOS' -only-testing:BeeChatAppTests test
** TEST SUCCEEDED **
```

All existing tests pass:
- `FilePathParserTests` — 9 tests, all passed
- `TopicViewModelTests` — 3 tests, all passed

## Verification Checklist

- [x] `reconnect()` doesn't leak the old `SyncBridge` — `await bridge.stop()` is called before reassignment
- [x] Old `connectionStateStream` subscription is cancelled before new bridge starts — `connectionStateTask?.cancel()` + `nil`
- [x] Rapid taps don't fire multiple reconnect attempts — synchronous `.connecting` guard + `isTappable` check
- [x] Arrow icon only shows when `isStartupComplete && (.disconnected || .error)`
- [x] No visual change when connected — no arrow, not tappable, same dot + text
- [x] Build clean, no warnings
- [x] All existing tests pass

## Deviations from Spec

**None.** The implementation follows the spec exactly as written, including both Kieran MAJOR fixes (synchronous state guard, connection state task cancellation) and the MINOR fix (`isStartupComplete` guard in `isTappable`).

The `startup()` method's existing `Task { let stream = await bridge.connectionStateStream() ... }` was not retrofitted with `connectionStateTask` storage — this is consistent with the spec's note that the same pattern "should be retrofitted to `startup()` for consistency" but does not block FR-002. That refactor can be done separately if desired.

## Notes

- `MainWindow.swift` was not modified — call site unchanged, as specified.
- The `connectionStateTask` property is `private` — not exposed beyond `AppState`.
- The `reconnect()` method is on `AppState` (the `@Observable` model), so SwiftUI views access it via `@Environment(AppState.self)`.
- No new tests were written — the spec did not require them, and the changes are UI/plumbing with no new testable logic (reconnect is a side-effecting async method that depends on live gateway/network state).