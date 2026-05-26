# Final Review: Fix A — Double-Resume Guard in GatewayClient.call()

**Reviewer:** Kieran (Independent Challenger)  
**Date:** 2026-05-10  
**Spec version:** 1.0  
**Verdict:** **APPROVE WITH CHANGES**

---

## Summary

The spec correctly identifies the crash bug and proposes a sound multi-layered defense. The primary mechanism (`remove()` return value) is solid. The defense-in-depth (`hasResumed`) has a real concurrency concern that should be addressed. There's also a cancellation-timing gap that the spec doesn't cover. Both are fixable without redesigning the approach.

---

## Question-by-Question Review

### Q1: Is the `onCancel` handler safe? Race with continuation already resumed?

**Mostly safe, with a documented subtlety.**

The `onCancel` handler creates a `Task { await self.pendingRequests.remove(...) }`. This is necessary because `onCancel` is synchronous and can't call actor-isolated methods directly. The `Task` schedules work on the `PendingRequestMap` actor, which serializes access.

If cancellation fires after the continuation is already resumed (by normal response, timeout, or disconnect), `remove()` finds no entry (`removeValue(forKey:)` returns `nil`), returns `false`, and nothing bad happens. The `@discardableResult` return value isn't checked in `onCancel`, but that's fine — `remove()` is a no-op when the entry is gone.

**One concern:** the `Task` created by `onCancel` is unstructured. If `GatewayClient` is deinitialized while the Task is pending, `self` is `weak` so it'll bail safely. Good. But there's no `Task.cancel()` for this spawned task if the continuation gets resumed by another path before the Task runs. It's just wasted work — low impact, but worth a comment in the code.

**Verdict:** Acceptable. The weak-self capture prevents use-after-free. The no-op `remove()` on a missing entry is harmless. Add a code comment noting the unstructured Task is intentionally fire-and-forget.

---

### Q2: `hasResumed` is non-Sendable, accessed from multiple concurrency domains — is this actually safe?

**No, this is a real data race under Swift concurrency rules. It should be fixed.**

`var hasResumed = false` is captured by closures that execute on different executors:

| Path | Executor |
|------|----------|
| `resolve` closure | PendingRequestMap actor |
| `reject` closure | PendingRequestMap actor |
| Catch block `hasResumed` check | Calling Task's executor |

The `resolve`/`reject` closures are called inside `PendingRequestMap` actor methods (`resolve()`, `reject()`, `remove()`, `clearAll()`). The catch blocks check `hasResumed` on the calling Task's executor. These are different concurrency domains with no synchronization between them.

The spec acknowledges this and argues:

> "In practice, the `await pendingRequests.remove()` provides a happens-before ordering that makes this safe."

**This is incorrect.** The `await` on `remove()` provides a happens-before between the `remove()` call and the code *after* it. But the `reject` closure runs *inside* `remove()` on the actor, *before* the `await` returns. The calling Task's `hasResumed` read after the `await` may still see a stale value because there's no formal memory barrier between the actor write and the calling Task's read.

**In practice on ARM64** (Apple Silicon), the actor hop likely provides sufficient memory ordering. But this is relying on implementation details, not language guarantees. Swift's concurrency model considers this a data race, and future compiler optimizations or ARM memory model edge cases could break it.

**Recommendation:** Replace `var hasResumed = false` with an atomic. Two options:

**Option A (preferred, minimal change):** Use `OSAllocatedUnfairLock<Bool>` (available since macOS 12):
```swift
let hasResumed = OSAllocatedUnfairLock(initialState: false)
// Check: hasResumed.withLock { $0 }
// Set: hasResumed.withLock { $0 = true }
```

**Option B:** Use `swift-atomics` package:
```swift
let hasResumed = ManagedAtomic<Bool>(false)
// Check: hasResumed.load(ordering: .acquiring)
// Set: hasResumed.store(true, ordering: .releasing)
```

Option A is simpler — no external dependency, and the lock overhead is negligible since contention is near-zero (the guard almost never fires).

The spec's claim that `hasResumed` is "defense-in-depth" is correct in intent — it catches paths that `remove()` return value doesn't. But defense-in-depth should also be correct in isolation, and a data race isn't correct even if the primary guard works.

---

### Q3: Could `onCancel`'s `remove()` deadlock if GatewayClient is already on its actor?

**No deadlock risk.**

`onCancel`'s `Task { await self.pendingRequests.remove(...) }` hops to the `PendingRequestMap` actor — a *different* actor from `GatewayClient`. There's no re-entrant actor isolation issue because `remove()` doesn't call back into `GatewayClient`.

Even if `GatewayClient.call()` is running on the `GatewayClient` actor, the `onCancel` Task doesn't need to re-enter it. The `weak self` capture is only used to access `self.pendingRequests` (which is a separate actor), not any `GatewayClient` methods.

**Verdict:** No deadlock. Safe.

---

### Q4: Race window where `onCancel` fires before the continuation exists?

**Yes, this is a real gap. The spec doesn't address it.**

Execution order in the proposed code:

```
withTaskCancellationHandler(onCancel: ...) {
    withCheckedThrowingContinuation { continuation in
        // continuation captured by closures
        Task {  // ← this Task is scheduled, not run immediately
            await self.pendingRequests.add(id:timeout:resolve:reject:)
            // ... send ...
        }
    }
}
```

If the parent Task is cancelled *before* the inner `Task` runs `add()`:

1. `onCancel` fires → creates `Task { await self.pendingRequests.remove(id:reason:) }`
2. The `remove()` Task runs on `PendingRequestMap` — finds no entry → returns `false`
3. Nobody resumes the continuation yet
4. Eventually, the inner `Task` runs → `add()` registers the entry → `send()` may fail or succeed
5. Timeout eventually fires → `remove()` → `reject` → continuation resumed

**Result:** The continuation is eventually resumed by timeout, not by cancellation. No crash, but the cancellation signal is lost — the call takes up to `requestTimeout` seconds to resolve instead of being immediate.

This is a pre-existing issue (the current code has the same inner-`Task` pattern), but the cancellation handler gives a false sense of immediate cancellation that doesn't actually work in this window.

**Recommendation:** Add a code comment documenting this limitation:

```swift
// Note: If cancellation fires before add() registers the pending request,
// remove() will be a no-op. The continuation will be resumed when the
// timeout eventually fires. This is acceptable because the window is
// extremely narrow (one actor hop) and the fallback is bounded by
// requestTimeout, not unbounded.
```

An alternative structural fix would require refactoring away the inner `Task { ... }`, which would need `add()` to be non-actor-isolated or the continuation setup to be restructured. This is a larger change and not justified for this bug fix. Document and defer.

---

### Q5: Does `@discardableResult` risk accidental removal of the return value check?

**Low risk, but worth guarding against.**

`@discardableResult` means callers *can* ignore the return value without warning. The spec correctly notes this preserves backward compatibility. The risk is that a future developer, seeing `@discardableResult`, might not realize the return value is meaningful.

In this codebase, `remove()` has exactly two call sites after the change:
1. Inside `call()` — checks the return value ✅
2. The `onCancel` handler — ignores the return value (intentional, since the entry might not exist yet per Q4)

**Recommendation:** Add a doc comment on `remove()` making the return value's purpose explicit:

```swift
/// - Returns: `true` if the entry was found and its reject callback was invoked
///   (i.e., the continuation was resumed). Callers that need to avoid double-resuming
///   the continuation MUST check this value.
```

This is a documentation fix, not a code change. The `@discardableResult` attribute is appropriate here — removing it would force `onCancel` to `_ =` the result, which is worse.

---

### Q6: Any edge cases where the continuation is resumed TWICE despite both guards?

**No, with one caveat (Q2's data race on `hasResumed`).**

Traced all combinations:

| Scenario | Primary guard | Secondary guard | Double-resume? |
|----------|--------------|-----------------|----------------|
| Normal response, then timeout | `resolve()` removes entry → `remove()` returns `false` | `hasResumed = true` | No |
| Timeout, then catch block | `remove()` returns `true` → catch skips | `hasResumed = true` (redundant) | No |
| Disconnect (clearAll), then catch | `remove()` returns `false` (entry already removed by `clearAll`) | `hasResumed = true` | No |
| `onCancel` + timeout race | Actor serialization — one `remove()` wins, other returns `false` | `hasResumed = true` | No |
| `onCancel` + normal response | `remove()` returns `false` if response arrived first | `hasResumed = true` | No |
| UTF-8 encode failure | `remove()` returns `true` → catch skips | `hasResumed = true` | No |
| Transport send failure | `remove()` returns `true` → catch skips | `hasResumed = true` | No |

The `remove()` return value as primary guard is **fully sound** because `PendingRequestMap` is an actor — all mutations are serialized. Once `removeValue(forKey:)` succeeds and calls `reject`, the entry is gone. Any subsequent `remove()`, `resolve()`, or `reject()` on the same ID is a no-op.

**The only theoretical double-resume path** is if `hasResumed` is the *sole* guard for a path (i.e., `remove()` doesn't protect it) AND the data race on `hasResumed` (Q2) causes a stale read. This would require:
1. `resolve()` or `reject()` sets `hasResumed = true` on the actor executor
2. The catch block reads `hasResumed` on the calling Task's executor *before* the write is visible
3. The catch block's `remove()` already returned `false` (because `resolve()`/`reject()` removed the entry)

This is theoretically possible but extremely unlikely in practice. Fixing Q2 (making `hasResumed` atomic) eliminates this entirely.

---

## Required Changes

1. **Make `hasResumed` thread-safe** — Replace `var hasResumed = false` with `OSAllocatedUnfairLock<Bool>` (or equivalent atomic). This is the only *must-fix* item. The data race is real under Swift concurrency rules, even if it's unlikely to manifest in practice.

2. **Add code comment documenting Q4's cancellation-timing gap** — Explain that if cancellation fires before `add()`, the `onCancel` `remove()` is a no-op and the continuation is eventually resumed by timeout. This sets correct expectations and prevents a future developer from "fixing" something that's intentionally deferred.

## Recommended (Non-Blocking) Changes

3. **Add doc comment on `remove()` return value** — Make the `true`/`false` meaning and the double-resume guard purpose explicit, so future developers understand why checking the return value matters.

4. **Add code comment on the `onCancel` unstructured Task** — Note that it's intentionally fire-and-forget with weak-self capture.

5. **Consider making `resolve()`, `reject()`, and `clearAll()` also return `Bool`** — For consistency with `remove()`. This would allow callers to check whether a continuation was actually resumed, not just whether an entry was removed. Not required for this fix, but would improve the API surface.

---

## Verdict

**APPROVE WITH CHANGES**

The spec's approach is correct. The `remove()` return value as primary guard is sound and well-reasoned. The `hasResumed` defense-in-depth is the right idea, but it needs to be atomic to be correct under Swift concurrency rules. The cancellation-timing gap (Q4) is a pre-existing limitation that should be documented, not fixed in this change. After making `hasResumed` atomic and adding the documented caveats, this is ready to implement.