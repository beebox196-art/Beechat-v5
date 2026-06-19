# Fix C Implementation: Streaming Poll Safety Guard

**Date:** 2026-05-10
**Status:** COMPLETE — Builds successfully

## Changes Made

**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift` — `startStreamingPoll()` method

### C1: Added `[weak self]` and `isStreaming` guard

Two changes in the `Task` closure:

1. **`[weak self]`** on the Task closure — prevents a retain cycle if the poll task outlives the `SyncBridgeObserver`. Since the class is `@MainActor @Observable`, the Task inherits the correct actor context. If `self` is deallocated, `guard let self` exits the poll cleanly.

2. **`guard let self, self.isStreaming else { return }`** as the first line inside the `while` loop — if `isStreaming` becomes `false` (via `resetStreamingState()`), the poll exits on the next iteration, even if `stopStreamingPoll()` wasn't called or its cancellation hasn't propagated yet due to cooperative cancellation.

## Build Verification

```
Build complete! (3.91s)
```

No other files modified. No changes to state machine logic, timeout handlers, or gateway client.