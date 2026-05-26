# Fix A Implementation Summary

**Date:** 2026-05-10  
**Fix:** Double-resume guard in GatewayClient.call()

## Changes Made

### 1. PendingRequestMap.swift
**File:** `Sources/BeeChatGateway/Internal/PendingRequestMap.swift`

**Method `remove(id:reason:)`** — Changed return type from `Void` to `Bool`:
- Added `@discardableResult` attribute
- Added doc comment explaining the return value semantics
- Returns `true` when entry was found and reject callback was invoked (continuation resumed)
- Returns `false` when entry was already gone (no-op, continuation not resumed by this call)

### 2. GatewayClient.swift
**File:** `Sources/BeeChatGateway/GatewayClient.swift`

- **Added `import os`** at top of file (for `OSAllocatedUnfairLock`)

- **Replaced `call(method:params:)` method body** with three-layer protection:

  **a) `withTaskCancellationHandler` wrapper** — Wraps the entire continuation block. `onCancel` uses `[weak self]` to avoid retain cycles and fires a `Task` to remove the pending request, which rejects the continuation. If cancel fires before `add()`, `remove()` is a no-op and timeout provides the fallback resume.

  **b) `OSAllocatedUnfairLock<Bool>` (`hasResumed`)** — Atomic flag inside `withCheckedThrowingContinuation`. Both `resolve` and `reject` closures check-and-set this flag before resuming. The catch blocks also check it. Prevents double-resume from any race (timeout+catch, disconnect+catch, etc.).

  **c) `remove()` return value check** — In the catch blocks (encoding failure, transport send failure), the code checks `alreadyHandled` from `remove()`. If `true`, the continuation was already resumed via reject — skip the second resume. If `false`, check `hasResumed` flag and resume only if not already done.

## Build Status
✅ Build complete — no errors, only pre-existing warnings.

## What Was NOT Changed
- `connect()` method (already has `handshakeContinuationResumed` guard)
- `disconnect()` / `clearAll()` (correct behavior, no changes)
- `PendingRequestMap.resolve()` / `reject()` (unchanged)
- UI code (no changes to SyncBridgeObserver, MainWindow, or views)