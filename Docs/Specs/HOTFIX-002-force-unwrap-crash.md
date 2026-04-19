# HOTFIX-002: Force-unwrap crash in updateTopics when offline

**Priority:** P0 — App crashes on relaunch in offline mode
**Status:** SPEC — awaiting team review before implementation
**Author:** Bee (coordinator)
**Date:** 2026-04-19

## Problem

After HOTFIX-001 fixed the GRDB MainActor scheduling, a second crash appears at the same call site. The app now successfully reaches `MessageViewModel.updateTopics(from:)` on the main thread, but crashes at line 63:

```swift
messageListObserver.startObserving(syncBridge: syncBridge!, sessionKey: key)
```

The force-unwrap `syncBridge!` crashes when `syncBridge` is nil (i.e., when there's no gateway connection). This is the offline/local-only path.

**Crash stack confirms:**
- `MessageViewModel.updateTopics(from:)` line 63
- Called from `MainWindow.startLocalSessionObservation()` line 149
- Thread 0, main thread — the `.mainActor` scheduling is working correctly
- `EXC_BREAKPOINT (SIGTRAP)` — Swift force-unwrap of nil

**Reproduction:** Launch app without gateway config → local sessions load from DB → `updateTopics` called → tries to force-unwrap nil `syncBridge` → crash

## Fix

Replace the force-unwrap with a conditional unwrap. In `MessageViewModel.updateTopics(from:)`, change:

```swift
// If selection changed, start observing messages for new session
if let key = selectedTopicId, key != messageListObserver.sessionKey {
    messageListObserver.startObserving(syncBridge: syncBridge!, sessionKey: key)
}
```

To:

```swift
// If selection changed, start observing messages for new session
if let key = selectedTopicId, key != messageListObserver.sessionKey {
    if let syncBridge {
        messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: key)
    }
}
```

This is safe because:
- In offline mode, there are no gateway messages to observe, so skipping `startObserving` is correct
- When gateway connects later, `rewireForGateway()` calls `messageViewModel.start(syncBridge:)` which sets up observation
- The same pattern is already used in `selectTopic(id:)` and `addLocalTopic(_:)` — they guard on `syncBridge`

## Constraints

- ONE line change in ONE file (`MessageViewModel.swift`)
- No other changes
- Build must pass clean
- All 49 tests must pass

## Validation

1. App must launch without crash in offline mode (no gateway config)
2. App must launch without crash with gateway config
3. Topics must persist across restart
4. Messages must display when gateway is connected