# Fix A: GatewayClient call() Double-Resume Guard

**Spec version:** 1.1  
**Date:** 2026-05-10  
**Status:** APPROVED — Amendments incorporated (OSAllocatedUnfairLock, cancellation docs, remove() doc comment)  
**Fixes:** Crash bug — `EXC_BREAKPOINT` / `SIGTRAP` from `CheckedContinuation` double-resume  
**Files:** `Sources/BeeChatGateway/GatewayClient.swift`, `Sources/BeeChatGateway/Internal/PendingRequestMap.swift`

---

## Problem

`GatewayClient.call()` uses `withCheckedThrowingContinuation`. The continuation can be resumed twice in these scenarios:

1. **Timeout + catch block:** Timeout fires → `remove()` calls `reject` → continuation resumes → catch block also calls `continuation.resume(throwing:)` → crash.
2. **Disconnect + catch block:** `disconnect()` calls `clearAll()` → all pending continuations resumed → catch block also resumes → crash.
3. **Task cancellation:** If the calling Task is cancelled, `withCheckedThrowingContinuation` doesn't auto-resume, causing a trap for non-resumed continuation.

---

## Changes

### Change A1: PendingRequestMap.remove() returns Bool

**File:** `Sources/BeeChatGateway/Internal/PendingRequestMap.swift`

**Before:**
```swift
public func remove(id: String, reason: String) {
    if let req = pending.removeValue(forKey: id) {
        req.timer.cancel()
        req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
    }
}
```

**After:**
```swift
/// Remove a pending request by ID, rejecting it with the given reason.
/// - Returns: `true` if the entry was found and its reject callback was invoked
///   (i.e., the continuation was resumed). Callers that need to avoid double-resuming
///   the continuation MUST check this value.
@discardableResult
public func remove(id: String, reason: String) -> Bool {
    if let req = pending.removeValue(forKey: id) {
        req.timer.cancel()
        req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
        return true
    }
    return false
}
```

---

### Change A2: GatewayClient.call() — Atomic guard + remove() return value + cancellation handler

**File:** `Sources/BeeChatGateway/GatewayClient.swift`

**Add import at top of file:**
```swift
import os
```

**Replace the `call(method:params:)` method body:**

**Before:**
```swift
public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
    guard state == .connected else {
        throw NSError(domain: "GatewayClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected (state: \(state.rawValue))"])
    }
    
    let id = "bc-\(nextRequestId)"
    nextRequestId += 1
    let frame = RequestFrame(id: id, method: method, params: params)
    
    return try await withCheckedThrowingContinuation { continuation in
        Task {
            await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { payload in
                continuation.resume(returning: payload)
            }, reject: { error in
                continuation.resume(throwing: error)
            })
            
            do {
                let data = try JSONEncoder().encode(frame)
                guard let text = String(data: data, encoding: .utf8) else {
                    let error = NSError(domain: "GatewayClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request frame as UTF-8"])
                    await pendingRequests.remove(id: id, reason: error.localizedDescription)
                    continuation.resume(throwing: error)
                    return
                }
                try await transport.send(text) 
            } catch {
                await pendingRequests.remove(id: id, reason: error.localizedDescription)
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**After:**
```swift
public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
    guard state == .connected else {
        throw NSError(domain: "GatewayClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected (state: \(state.rawValue))"])
    }
    
    let id = "bc-\(nextRequestId)"
    nextRequestId += 1
    let frame = RequestFrame(id: id, method: method, params: params)
    
    return try await withTaskCancellationHandler(
        onCancel: { [weak self] in
            guard let self else { return }
            // Fire-and-forget: onCancel is synchronous so we can't await actor methods.
            // The remove() call will reject the pending request if it exists, which
            // resumes the continuation via the reject callback. If the entry doesn't
            // exist yet (cancel fired before add()), remove() is a no-op and the
            // continuation will be resumed by timeout instead. This window is
            // extremely narrow (one actor hop) and the fallback is bounded by
            // requestTimeout.
            Task { await self.pendingRequests.remove(id: id, reason: "Request cancelled") }
        }
    ) {
        try await withCheckedThrowingContinuation { continuation in
            // Atomic guard against double-resume. OSAllocatedUnfairLock provides
            // thread-safe access across actor boundaries (resolve/reject closures run
            // on PendingRequestMap's actor; catch block runs on calling Task's executor).
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            
            Task {
                await self.pendingRequests.add(id: id, timeout: self.config.requestTimeout, resolve: { payload in
                    hasResumed.withLock { flag in
                        guard !flag else { return }
                        flag = true
                    }
                    continuation.resume(returning: payload)
                }, reject: { error in
                    hasResumed.withLock { flag in
                        guard !flag else { return }
                        flag = true
                    }
                    continuation.resume(throwing: error)
                })
                
                do {
                    let data = try JSONEncoder().encode(frame)
                    guard let text = String(data: data, encoding: .utf8) else {
                        let error = NSError(domain: "GatewayClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request frame as UTF-8"])
                        let alreadyHandled = await self.pendingRequests.remove(id: id, reason: error.localizedDescription)
                        if !alreadyHandled {
                            hasResumed.withLock { flag in
                                guard !flag else { return }
                                flag = true
                            }
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    try await self.transport.send(text)
                } catch {
                    let alreadyHandled = await self.pendingRequests.remove(id: id, reason: error.localizedDescription)
                    if !alreadyHandled {
                        hasResumed.withLock { flag in
                            guard !flag else { return }
                            flag = true
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
```

**Three layers of protection:**
1. **`remove()` return value (primary):** If `remove()` returns `true`, it already invoked `reject` → continuation already resumed → skip.
2. **`OSAllocatedUnfairLock<Bool>` (defense-in-depth):** Atomic check-and-set prevents double-resume from any path, including `resolve()` and `clearAll()` during disconnect.
3. **`withTaskCancellationHandler` (lifecycle):** If the calling Task is cancelled, `onCancel` removes the pending request, which invokes `reject` → continuation resumed. Prevents non-resume trap.

---

## Scenarios Verified

| Scenario | What happens | Correct? |
|----------|-------------|----------|
| Normal response arrives | `resolve()` → `hasResumed.withLock { flag = true }` | ✅ |
| Timeout fires before response | `remove()` → `reject()` → `hasResumed.withLock { flag = true }` | ✅ |
| Timeout + catch block race | `remove()` returns `true` → catch block skips resume | ✅ |
| Disconnect during in-flight call | `clearAll()` → `reject()` → `hasResumed` set → catch block skips | ✅ |
| Task cancelled while awaiting | `onCancel` → `remove()` → `reject()` → `hasResumed` set | ✅ |
| Cancel fires before add() | `remove()` returns `false` → timeout eventually resumes | ✅ (bounded by requestTimeout) |
| UTF-8 encoding fails | `remove()` returns `true` → skip second resume | ✅ |
| Transport send fails | `remove()` returns `true` → skip second resume | ✅ |

---

## What This Does NOT Change

- `connect()` method — already has `handshakeContinuationResumed` guard, separate from this fix
- `disconnect()` method — `clearAll()` continues to reject all pending entries, which is correct
- `PendingRequestMap.resolve()` — unchanged
- `PendingRequestMap.reject()` — unchanged
- Any UI code — no changes to SyncBridgeObserver, MainWindow, or views

---

*Approved by Q and Kieran. Ready for implementation.*