# HOTFIX-001: GRDB ValueObservation MainActor Crash

**Priority:** P0 — App crashes on launch
**Status:** SPEC — awaiting team review before implementation
**Author:** Bee (coordinator)
**Date:** 2026-04-19

## Problem

The app crashes with `EXC_BREAKPOINT (SIGTRAP)` at `MessageViewModel.updateTopics(from:)` called from `MainWindow.startLocalSessionObservation()`.

**Root cause:** GRDB's `ValueObservation.onChange` callback fires on a **background queue** (not MainActor). Q's implementation wraps the callback in `Task { @MainActor in }`, but this creates a data race — the `@MainActor`-isolated `messageViewModel` is captured by a closure that runs on a GRDB background thread, and the `Task` dispatches asynchronously. Swift's strict concurrency catches this as an assertion failure.

## Crash Stack

```
Thread 0 Crashed:: com.apple.main-thread
0 libswiftCore.dylib _assertionFailure(_:_:file:line:flags:) + 364
1 BeeChatApp MessageViewModel.updateTopics(from:) + 1996 (MessageViewModel.swift:63)
2 BeeChatApp closure #1 in closure #3 in MainWindow.startLocalSessionObservation() + 240 (MainWindow.swift:146)
```

## Proper Fix (researched against GRDB documentation)

GRDB provides a `scheduling` parameter on `ValueObservation.start()` that controls which queue the `onChange` callback fires on. The correct pattern is:

```swift
localSessionCancellable = observation.start(
    in: writer,
    scheduling: .mainQueue,  // ← This is the key fix
    onError: { error in
        print("[MainWindow] Local session observation error: \(error)")
    },
    onChange: { [weak messageViewModel] sessions in
        // Now on MainActor — safe to call updateTopics directly
        messageViewModel?.updateTopics(from: sessions)
    }
)
```

The `.mainQueue` scheduling option ensures `onChange` fires on the main queue, eliminating the need for `Task { @MainActor in }` and the associated data race.

**Reference:** [GRDB ValueObservation documentation](https://swiftpackageindex.com/groue/GRDB.swift/main/documentation/grdb/valueobservation) — "By default, changes are notified in a background dispatch queue." The `scheduling: .mainQueue` option delivers changes on the main queue.

## Constraints

- ONE change only — add `scheduling: .mainQueue` to the ValueObservation start call
- Remove the `Task { @MainActor in }` wrapper since it's no longer needed
- Build must pass clean
- All 49 tests must pass
- No other files touched

## Validation

1. App must launch without crash
2. Topics must persist across app restart
3. Topic creation must work
4. Topic list must update when gateway sessions arrive (if connected)