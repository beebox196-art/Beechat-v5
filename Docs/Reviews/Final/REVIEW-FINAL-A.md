# Final Review: Fix A — Double-Resume Guard in GatewayClient.call()

**Reviewer:** Q  
**Date:** 2026-05-10  
**Spec:** SPEC-FIX-A-double-resume.md v1.0  
**Verdict:** ✅ **APPROVE WITH CHANGES**

---

## 1. "Before" Code Matches Current Source?

**GatewayClient.swift** — The `call()` method in the spec's "Before" block matches the current source **exactly** (lines 127–148). ✅

**PendingRequestMap.swift** — The `remove(id:reason:)` method in the spec's "Before" block matches the current source **exactly** (lines 34–39). ✅

No drift. Good.

---

## 2. Does the "After" Code Compile?

Two issues found:

### Issue 2a: `[weak self]` in `onCancel` — `GatewayClient` is an actor, not a class

The spec uses:
```swift
onCancel: { [weak self] in
    guard let self else { return }
    Task { await self.pendingRequests.remove(id: id, reason: "Request cancelled") }
}
```

`GatewayClient` is declared as `public actor`. Actors **do support** `[weak self]` in closures (SE-0337, Swift 5.9+). However, there's a subtlety: `withTaskCancellationHandler`'s `onCancel` is a `@Sendable () -> Void`, and the `guard let self` unwrap produces an actor reference. The `Task { await self.pendingRequests.remove(...) }` then hops to the actor's executor, which is correct.

**Verdict:** Compiles fine on Swift 5.9+ (package requires macOS 14, which ships Swift 5.9). ✅

### Issue 2b: Missing `self.` references

The current code inside the `Task { ... }` block references `pendingRequests`, `config.requestTimeout`, and `transport` without `self.` — these work today because the closure is inside `withCheckedThrowingContinuation` which is inside the actor method.

The "After" code wraps with `withTaskCancellationHandler`, which introduces a `@Sendable` closure. Inside that outer closure, references to actor-isolated properties **must** use `self.` explicitly. The spec already adds `self.` to `pendingRequests`, `config.requestTimeout`, and `transport.send`. ✅

**One missing reference:** `self.config.requestTimeout` — the spec writes this correctly. Good.

### Issue 2c: `var hasResumed` inside `withCheckedThrowingContinuation` — Sendable concern

`hasResumed` is a `var Bool` captured by both the `resolve` and `reject` closures. These closures are `@Sendable` (they cross actor boundaries). Mutating a captured `var` from `@Sendable` closures is **not safe** and Swift 6 strict concurrency would flag it.

**However:** Swift 5.9 in strict concurrency mode (macOS 14 target) — the compiler emits a **warning** but not an error by default. The package doesn't set `.swiftSettings([.unsafeFlags(["-warnings-as-errors"])]`), so this compiles but is technically a data race.

**Is this a real problem?** The spec acknowledges this: "hasResumed is technically a non-atomic access across concurrency domains." The spec argues the `await pendingRequests.remove()` provides a happens-before ordering. This is partially correct but not watertight — two `reject` calls from different concurrency contexts (e.g., `clearAll` + catch block) could both read `hasResumed` as `false` before either writes `true`.

**In practice:** The `remove()` return value is the primary guard, and `hasResumed` is defense-in-depth. A race on `hasResumed` could cause a double-resume (worst case: crash from the same bug we're fixing), but `remove()` returning `Bool` prevents the most common paths. The race window is extremely narrow.

**Recommendation (see §4 below):** Change `hasResumed` to use `OSAllocatedUnfairLock<Bool>` or wrap in a small `ActorIsolated<Bool>` helper for correctness. This is a minor change that removes the theoretical race entirely.

---

## 3. `withTaskCancellationHandler` — Correctness Analysis

### Is `onCancel` creating a detached Task correct?

Yes. `onCancel` is synchronous (`@Sendable () -> Void`), so it can't `await` actor methods. Creating a `Task { await ... }` is the standard pattern. This is explicitly documented by Swift concurrency designers.

### Could the Task run after the continuation is already resumed?

**Yes, but it's safe.** If cancellation fires *after* the continuation was already resolved (e.g., response arrived first), then:

1. `onCancel` fires → creates `Task { await self.pendingRequests.remove(id:reason:) }`
2. That `Task` runs → `remove()` returns `false` (entry already removed by `resolve()`) → no-op
3. The continuation is already resumed, so nothing bad happens

The `remove()` return value makes this path safe. ✅

### Could cancellation fire *during* `withCheckedThrowingContinuation` setup?

`withTaskCancellationHandler` registers the handler *before* the operation starts, which is correct. If the Task is already cancelled when `call()` is entered, `onCancel` fires immediately, and the `Task` inside it will `remove()` the request (which hasn't been added yet → returns `false`) or will add and then remove it. Either way, the `hasResumed` guard prevents double-resume.

**Edge case:** If `onCancel` fires before `pendingRequests.add()` runs, the `remove()` call finds nothing, returns `false`. Then `add()` runs, creating an orphaned request. The timer will eventually time it out → `remove()` → `reject()` → continuation resumed. But wait — the `Task` inside `onCancel` is `await self.pendingRequests.remove()`, which suspends on the actor. If `add()` hasn't run yet, the `remove()` returns `false` and does nothing. Then `add()` runs and sets up the request. The timeout will eventually fire and `reject()` will resume the continuation.

**But:** The calling Task was cancelled, so `withTaskCancellationHandler` will throw `CancellationError` after the `onCancel` handler returns... actually no, `withTaskCancellationHandler` doesn't auto-throw. It just calls `onCancel`. The continuation will be resumed by the timeout's `remove()` call.

**Better behavior:** The `onCancel` `Task` should also try to resume the continuation directly, not just rely on `remove()`. Currently, if `remove()` returns `false` (entry not yet added), the continuation might never be resumed until the timeout fires.

**Recommendation:** This is a narrow race but not a crash risk — the worst case is the call sits until timeout. Low priority, but worth noting.

---

## 4. `hasResumed` — Capture Semantics & Lifetime

`hasResumed` is a `var Bool` declared inside the `withCheckedThrowingContinuation` closure. Both `resolve` and `reject` closures capture it by reference (closures are reference types).

**Lifetime concern:** The `hasResumed` variable lives on the stack frame of the `withCheckedThrowingContinuation` closure. The continuation's `resolve`/`reject` closures capture a reference to this stack variable. In Swift, closures extend the lifetime of captured variables to the heap (implicit boxing). So `hasResumed` is heap-allocated and lives as long as the closures reference it.

**Data race concern (expanded from §2c):** Both closures and the `onCancel` handler's `Task` can run on different threads. Mutations to `hasResumed` are not atomic. Two concurrent reads of `false` → both write `true` → both resume → crash.

The spec's defense is that `remove()` is the primary guard and `hasResumed` is defense-in-depth. This is reasonable but not bulletproof.

**Required amendment:** Replace `var hasResumed = false` with an atomic guard. Options:

```swift
// Option A: OSAllocatedUnfairLock (macOS 14+, no dependencies)
let hasResumed = OSAllocatedUnfairLock(initialState: false)
// Usage: hasResumed.withLock { flag in
//     guard !flag else { return }
//     flag = true
//     // resume continuation...
// }
```

```swift
// Option B: AsyncSemaphore-style using an actor-isolated wrapper
// (overkill for this case)
```

**Recommendation:** Use `OSAllocatedUnfairLock<Bool>`. It's available on macOS 14+ (the package's minimum), zero-overhead, and eliminates the race entirely. This changes the closure syntax slightly but is straightforward.

---

## 5. `PendingRequestMap.remove()` Returning `Bool` — Caller Impact

### Callers of `remove()`:

| Location | Context | Impact |
|---|---|---|
| `PendingRequestMap.add()` timer callback | `Task { await self.remove(id:reason:) }` | No change — `@discardableResult` |
| `GatewayClient.call()` (current) | `await pendingRequests.remove(id:reason:)` | No change — `@discardableResult` |
| `GatewayClient.call()` (new) | Uses return value | Expected — this is the point |

### Callers of `clearAll()`:

| Location | Context | Impact |
|---|---|---|
| `GatewayClient.disconnect()` | `await pendingRequests.clearAll(reason:)` | No change — `clearAll()` return type unchanged |

**No breakage.** ✅

---

## 6. Non-Resume Trap Analysis

Can the continuation **never** be resumed?

| Path | Resumed? |
|---|---|
| Normal response | `resolve()` → ✅ |
| Timeout | `remove()` → `reject()` → ✅ |
| Transport send error | `remove()` → `reject()` (or `hasResumed` guard) → ✅ |
| Disconnect | `clearAll()` → `reject()` → ✅ |
| Task cancellation | `onCancel` → `Task { remove() }` → `reject()` → ✅ |
| UTF-8 encode failure | `remove()` → `reject()` → ✅ |
| Cancellation before `add()` | `remove()` returns `false` → timeout eventually fires → `reject()` → ✅ (delayed, not hung) |

**One edge case:** If cancellation fires before `add()`, and the `onCancel` Task's `remove()` returns `false`, the continuation waits for timeout. This isn't a non-resume trap, just a delayed resume. Acceptable.

**No non-resume trap found.** ✅

---

## 7. Impact on `connect()` and `disconnect()`

### `connect()`:
- Uses its own `handshakeContinuation` + `handshakeContinuationResumed` guard. **Unaffected.** ✅
- The `withCheckedThrowingContinuation` in `connect()` has the same double-resume risk (separate issue, not in scope).

### `disconnect()`:
- Calls `pendingRequests.clearAll(reason:)`. `clearAll()` is unchanged. ✅
- The `clearAll()` path now interacts correctly with the new `hasResumed` guard in `call()`: `clearAll()` → `reject()` → `hasResumed = true` → if catch block also fires, it checks `hasResumed` and skips. ✅

**No impact on connect/disconnect.** ✅

---

## Required Amendments

### Amendment 1: Use `OSAllocatedUnfairLock<Bool>` instead of `var hasResumed`

Replace:
```swift
var hasResumed = false
```

With:
```swift
let hasResumed = OSAllocatedUnfairLock(initialState: false)
```

And update all guard/resume patterns from:
```swift
guard !hasResumed else { return }
hasResumed = true
continuation.resume(...)
```

To:
```swift
hasResumed.withLock { flag in
    guard !flag else { return }
    flag = true
    continuation.resume(...)
}
```

This eliminates the data race on `hasResumed`. Requires `import os` (already available on macOS 14+).

### Amendment 2: Add `import os` to GatewayClient.swift

`OSAllocatedUnfairLock` is in the `os` module. The file currently only imports `Foundation`. Add `import os`.

---

## Optional Improvements (not blocking)

1. **Cancellation-before-add race:** If `onCancel` fires before `add()` runs, the call sits until timeout. Could be improved by having the `onCancel` handler also set a cancelled flag that `add()` checks immediately, but this adds complexity for a narrow edge case. Low priority.

2. **`connect()` has the same double-resume risk** but uses `handshakeContinuationResumed` as a guard. Consider applying the same `OSAllocatedUnfairLock` pattern there for consistency, but this is out of scope for this fix.

---

## Verdict

**✅ APPROVE WITH CHANGES**

The spec is well-designed and addresses the root cause correctly. Two required amendments:
1. Replace `var hasResumed` with `OSAllocatedUnfairLock<Bool>` to eliminate the data race
2. Add `import os` to `GatewayClient.swift`

Everything else — the `remove()` return value, `withTaskCancellationHandler`, the defense-in-depth approach — is correct and sound.