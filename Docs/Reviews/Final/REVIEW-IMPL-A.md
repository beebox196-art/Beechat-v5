# Review: Fix A Implementation — Double-Resume Guard

**Reviewer:** Kieran (independent)  
**Date:** 2026-05-10  
**Spec:** `SPEC-FIX-A-double-resume.md` v1.1  
**Implementation:** `IMPL-FIX-A.md` + actual source files

---

## 1. Does the implementation match the spec's "After" code exactly?

**PendingRequestMap.swift `remove()`:** ✅ Matches exactly. Return type `Bool`, `@discardableResult`, doc comment, body logic all identical to spec.

**GatewayClient.swift `call()`:** ⚠️ **Deviation found.**

The spec's `withTaskCancellationHandler` call uses this argument order:

```swift
withTaskCancellationHandler(
    onCancel: { [weak self] in ... }
) {
    // operation
}
```

The implementation reverses it:

```swift
withTaskCancellationHandler {
    // operation
} onCancel: { [weak self] in ... }
```

Both are valid Swift — `withTaskCancellationHandler(_:onCancel:)` takes the operation as the first argument and `onCancel` as the second trailing closure. When both are trailing closures, Swift requires the operation first, then `onCancel:` label. The implementation's order is correct for trailing-closure syntax. The spec's version is also valid (named first parameter + trailing closure for operation). **Functional equivalence confirmed — no bug, just a stylistic difference in how the call is written.**

All other structural elements (hasResumed guard logic, remove() return checks, catch blocks) match the spec exactly.

**Verdict: Acceptable stylistic deviation. No functional difference.**

---

## 2. Does `import os` appear at the top of GatewayClient.swift?

✅ **Yes.** Line 1: `import os`, line 2: `import Foundation`.

---

## 3. Is `OSAllocatedUnfairLock<Bool>` used correctly?

✅ **Yes.** All access goes through `withLock { flag in ... }`. No direct property access to the wrapped value.

Specifically:
- `hasResumed.withLock { flag in guard !flag else { return }; flag = true }` — correct check-and-set pattern inside the lock.
- Used in `resolve`, `reject`, both catch blocks — consistent.

No `hasResumed.withUnsafePointer` or direct `_value` access anywhere.

---

## 4. Is `withTaskCancellationHandler` called with the correct argument order?

✅ **Yes.** As noted in point 1, the implementation uses trailing-closure syntax with operation first, `onCancel:` label second, which matches Swift's API signature. The spec wrote it with `onCancel:` as a named first parameter, but both produce identical call semantics.

---

## 5. Is the `@discardableResult` and doc comment on `remove()` correct?

✅ **Yes.**
- `@discardableResult` attribute present — callers that ignore the return value won't get warnings.
- Doc comment matches the spec text verbatim: explains that `true` means entry was found and reject callback was invoked, and that callers needing to avoid double-resume MUST check this value.

---

## 6. Is the `[weak self]` in onCancel correct?

✅ **Yes.** The `onCancel` closure captures `[weak self]` and uses `guard let self` before accessing `self.pendingRequests`. This prevents a retain cycle between the Task and GatewayClient.

One subtle point: the `Task { await self.pendingRequests.remove(...) }` inside onCancel creates a new task that strongly captures `self` (after the `guard let self` unwrap). This is intentional and correct — we *want* the task to hold `self` alive long enough to complete the remove, and the `[weak self]` on the outer onCancel ensures we don't keep `self` alive just because cancellation was registered.

---

## 7. Any Swift concurrency warnings the build might have missed?

### 7a. `hasResumed` capture in sendable closures

`OSAllocatedUnfairLock<Bool>` is `Sendable`, so capturing it in `@Sendable` closures (resolve/reject) is fine. ✅

### 7b. Actor isolation of `hasResumed`

`hasResumed` is created inside `withCheckedThrowingContinuation`'s closure, which runs on the calling task's executor. The resolve/reject closures run on PendingRequestMap's actor. `OSAllocatedUnfairLock` is designed exactly for this cross-isolation scenario — lock-based, not actor-isolated. ✅

### 7c. `onCancel` is synchronous — `Task` inside is correct

The spec's comment explicitly notes this: "onCancel is synchronous so we can't await actor methods." The `Task { await ... }` wrapper is the correct pattern for hopping onto the actor from a synchronous context. ✅

### 7d. Potential: `id` capture in onCancel

`id` is a `String` (value type, Sendable). It's captured by the onCancel closure, which is fine. The `id` value is determined before the cancellation handler is registered, so no race. ✅

### 7e. Potential: Continuation resume ordering with cancel race

If task cancellation fires *before* `add()` completes, `remove()` in onCancel returns `false` (entry not found). The spec acknowledges this: "This window is extremely narrow (one actor hop) and the fallback is bounded by requestTimeout." The timeout will eventually resume the continuation. This is documented and acceptable. ✅

### 7f. Potential: `withCheckedThrowingContinuation` misuse

The Swift concurrency runtime enforces that a `CheckedContinuation` must be resumed exactly once. The three-layer guard (remove return value + OSAllocatedUnfairLock + cancellation handler) makes this contract satisfied for all identified scenarios. In the cancel-before-add race, the timeout provides the guaranteed resume. ✅

### 7g. One concern: `resolve` and `reject` closures don't check `hasResumed` before calling `continuation.resume(...)`

Looking at the resolve/reject closures more carefully:

```swift
resolve: { payload in
    hasResumed.withLock { flag in
        guard !flag else { return }
        flag = true
    }
    continuation.resume(returning: payload)
},
reject: { error in
    hasResumed.withLock { flag in
        guard !flag else { return }
        flag = true
    }
    continuation.resume(throwing: error)
}
```

There is a subtle gap here: the `withLock` block sets `flag = true` and returns, but if `flag` was already `true` (guard fails), the `return` exits the closure — but only the *closure passed to withLock*, not the outer resolve/reject closure. After `withLock` returns, execution continues to `continuation.resume(...)` **regardless**.

**Wait** — let me re-read. The `guard !flag else { return }` returns from the *entire* trailing closure passed to `withLock`. If the guard fires (flag is already true), the closure returns early, skipping `flag = true`. But then `withLock` returns, and the next line `continuation.resume(returning: payload)` **still executes**.

**This is a bug.** The resolve/reject closures need to check the result of the `withLock` operation and skip the `continuation.resume()` call when the guard fires. Currently the `withLock` block only gates setting the flag — it doesn't gate the actual resume.

The correct pattern would be:

```swift
resolve: { payload in
    let shouldResume = hasResumed.withLock { flag -> Bool in
        if flag { return false }
        flag = true
        return true
    }
    if shouldResume {
        continuation.resume(returning: payload)
    }
},
```

Or alternatively, move the `continuation.resume()` inside the `withLock` closure — but that's not possible because `CheckedContinuation.resume()` is not `Sendable`-safe to call from within a lock.

**This is a real bug.** If `resolve` fires after `reject` has already set the flag, the `withLock` block's `guard !flag else { return }` exits the lock closure, but the `continuation.resume(returning: payload)` on the next line still runs, causing a double-resume crash.

**Severity: HIGH.** This is the exact class of bug the fix was meant to prevent.

However, let me check the catch blocks more carefully:

```swift
let alreadyHandled = await self.pendingRequests.remove(id: id, reason: error.localizedDescription)
if !alreadyHandled {
    hasResumed.withLock { flag in
        guard !flag else { return }
        flag = true
    }
    continuation.resume(throwing: error)
}
```

The catch blocks have the same pattern — `withLock` guard doesn't gate `continuation.resume`. But they're protected by the `if !alreadyHandled` check, which provides *some* protection. However, if `resolve` or `reject` has already set `hasResumed = true`, and then a catch block runs, the `withLock` guard fires but `continuation.resume` still executes.

**The catch blocks are also affected**, though the `alreadyHandled` check provides partial coverage.

**The core issue:** `withLock` is being used as a guard to set a flag, but the code that follows (`continuation.resume`) is not gated by the flag check. The `withLock` closure's early `return` only exits the lock scope, not the enclosing resolve/reject/catch scope.

---

## Verdict

## **REJECT**

The implementation has a critical concurrency bug in the `hasResumed` guard pattern. The `OSAllocatedUnfairLock.withLock` closure's `guard !flag else { return }` only exits the lock closure — it does **not** skip the subsequent `continuation.resume()` call. This means the double-resume protection is ineffective in the resolve/reject callbacks and the catch blocks.

### Required Fix

Replace the current pattern in resolve/reject closures and catch blocks:

```swift
// WRONG (current implementation)
resolve: { payload in
    hasResumed.withLock { flag in
        guard !flag else { return }
        flag = true
    }
    continuation.resume(returning: payload)  // ← always executes, even when guard fired
},

// CORRECT
resolve: { payload in
    let shouldResume = hasResumed.withLock { flag -> Bool in
        if flag { return false }
        flag = true
        return true
    }
    if shouldResume {
        continuation.resume(returning: payload)
    }
},
```

Apply the same fix pattern to:
1. `resolve` closure
2. `reject` closure  
3. UTF-8 encoding failure catch block
4. Transport send failure catch block

### Other Findings

All other verification points pass:
- ✅ `import os` present
- ✅ `OSAllocatedUnfairLock` used with `withLock` (no direct property access)
- ✅ `withTaskCancellationHandler` argument order correct
- ✅ `@discardableResult` and doc comment on `remove()` correct
- ✅ `[weak self]` in onCancel correct
- ✅ No other concurrency warnings
- ⚠️ Minor stylistic deviation from spec (trailing-closure order for `withTaskCancellationHandler`) — functionally equivalent

---

*Review by Kieran — independent code review*