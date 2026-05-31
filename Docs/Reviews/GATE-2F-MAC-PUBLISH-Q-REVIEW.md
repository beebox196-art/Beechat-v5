# Q Review: GATE-2F Mac-Side Topic Publishing via `chat.inject`

**Reviewer:** Q (code implementation specialist)  
**Date:** 2026-05-28  
**Spec:** `GATE-2F-MAC-TOPIC-PUBLISH.md` (DRAFT)  
**Verdict:** **Approve with warnings** — implementable, but 2 warnings and 3 concerns need attention.

---

## Blockers (must-fix before implementation)

**None.** The spec is implementable as-is. The issues below are real but none will cause compilation failure, data corruption, or messaging breakage.

---

## Warnings (should-fix, but implementation can proceed)

### W1. Debounce logic contradicts its own description

**§2C** says: *"Each call cancels the previous debounce timer and schedules a new one (so the last change in a burst always publishes)."*

**§4.2** implements a simple time-since-last-publish guard:

```swift
guard now.timeIntervalSince(lastPublishAt) >= Self.publishDebounceInterval else {
    return  // ← silently dropped, no reschedule
}
```

These are **not the same thing**. The description describes trailing-edge debounce (last call wins, publishes after 30s of silence). The code implements a throttle (skip if within 30s, last call is lost).

**Why it matters:** If a user creates a topic, then renames it within 30s, the rename publish is silently dropped. The iPhone won't see the updated name until the next trigger fires (which could be minutes later on a session change, or never if no other CRUD happens).

**Fix:** Replace with a trailing-edge debounce pattern:

```swift
private var publishTask: Task<Void, Never>?

public func publishTopicList() async {
    publishTask?.cancel()
    publishTask = Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
        guard !Task.isCancelled else { return }
        await performPublish()
    }
}

private func performPublish() async {
    // ... actual publish logic (fetch, serialize, inject) ...
}
```

This way, a burst of calls within 30s results in exactly one publish at the *end* of the burst, not zero publishes.

### W2. `Date?` encoding will produce `nil` as `null`, not ISO 8601 string

The `TopicSyncItem` struct declares `lastActivityAt: Date?`. The iPhone's `TopicPayloadItem` expects `lastActivityAt: String?` (ISO 8601). When `JSONEncoder` encounters a `Date?` with `nil` value, it correctly encodes as `null`. But when the value is present, Swift's default `JSONEncoder` encodes `Date` as a **double** (seconds since 2001-01-01), not as an ISO 8601 string.

**Why it matters:** The iPhone decoder calls `parseISO8601(from: lastActivityAt)` on a `String?`. If the Mac sends `640105200.0` instead of `"2026-05-28T14:00:00Z"`, the iPhone will fail to parse the date and `lastActivityDate` will be nil — dates silently lost.

**Fix:** Either:
- (a) Change `lastActivityAt` in `TopicSyncItem` to `String?` and format it manually with `ISO8601DateFormatter`, or
- (b) Set `encoder.dateEncodingStrategy = .iso8601` on the `JSONEncoder` used for serialisation.

Option (b) is simpler and matches the spec's JSON example. However, option (b) also affects any other `Date` fields in the struct (there are none in this case, so it's safe).

```swift
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let jsonData = try encoder.encode(payload)
```

---

## Concerns (things to watch during testing)

### C1. Startup publish may race with `fetchSessions()`

The spec wires `publishTopicList()` after `bridge.start()` in `AppRootView.swift`. Inside `start()`, the bridge calls `fetchSessions()` which does `try config.persistenceStore.upsertSessions(sessions)` — writing sessions to the DB. But `publishTopicList()` reads topics from a separate `TopicRepository` that queries the `topics` table, not the `sessions` table.

If the app launches cold with no local topics (fresh install), the startup publish is correctly guarded by the "no active topics — don't publish" check. But if there *are* local topics, they'll publish fine regardless of session state.

**Verdict:** Not a bug, but worth confirming in testing that a cold launch with existing topics publishes successfully. The `start()` flow is sequential and `publishTopicList()` is `await`-ed, so there's no data race.

### C2. `sessions.changed` trigger is very broad

The spec (§3F) triggers `publishTopicList()` on *every* `sessions.changed` event, not just those involving the user's topics. The `SyncBridgeObserver.didReceiveSessionChange` callback fires for all session key changes — including sub-agent sessions, cron sessions, and any other session the gateway reports.

**Impact:** Every gateway session change (including sub-agent activity visible in the sidebar) will trigger a 30s-debounced publish. This is mostly harmless (debounce absorbs it) but means the publish fires more often than necessary.

**Mitigation:** The iPhone's `didReceiveSessionChange` already filters to only process changes involving `beechat-sync`:

```swift
guard sessionKeys.contains(where: { $0.contains("beechat-sync") }) else { return }
```

So the iPhone won't reconcile unless the sync session itself changes. But the Mac will still serialize and inject the full topic list into the sync session for every unrelated session change, which creates a new message in that session each time. Each publish is a `chat.inject` call that appends a new message. Over time, the sync session accumulates stale payloads.

**Recommendation:** Consider filtering the trigger to only fire when a session key in the Mac's known topic list changes, not on every `sessions.changed`. Or, at minimum, add a comment explaining why broad triggering is intentional.

### C3. Sync session accumulates payloads — no cleanup

Each `chat.inject` call appends a new message to `agent:main:beechat-sync`. The iPhone reads the *latest* message via `fetchSyncPayload` → `chatHistory(limit: 1)`. This means old payloads accumulate as history in the sync session.

**Impact:** Low in practice — the iPhone only reads the latest message. But the sync session grows over time. After months of use, this session could have thousands of stale payloads.

**Recommendation for future:** Consider using `sessions.reset` on the sync session before injecting, or accept the accumulation as a non-blocking cosmetic issue. This is a concern, not a blocker.

---

## Suggestions (nice-to-have, defer if needed)

### S1. Use a `label` value that the iPhone can filter on

The spec passes `label: "beechat-topic-sync"` to `chatInject`. The iPhone currently reads the latest message from the sync session via `chatHistory(limit: 1)`. It doesn't filter by label. If other messages ever appear in that session, the label would help distinguish them. Currently, the iPhone validates the payload structure (starts with `{`, has `v: 1`, has `topics` array), so mis-identification is unlikely. But the label is good defensive design — keep it.

### S2. Struct naming collision with iPhone

The Mac spec defines `TopicSyncItem` and `TopicListPayload`. The iPhone defines `TopicSyncPayload` and `TopicPayloadItem`. Different names, different fields, different types — no collision at compile time since they're in separate targets. But the naming inconsistency could confuse future developers. Consider matching the iPhone's names exactly (or at least documenting the mapping) for clarity.

### S3. Consider adding `origin` field to payload

The iPhone's reconciliation logic marks topics as `origin: "mac"`. The payload doesn't include an explicit `origin` field — the iPhone hardcodes it. This works, but if a future Mac-to-Mac sync scenario arises, the implicit `origin = "mac"` would be wrong. Low risk, defer.

### S4. `lastPublishAt` should be persisted or at least documented as ephemeral

`lastPublishAt` is an in-memory `Date` on the `SyncBridge` actor. If the Mac app crashes and relaunches within 30s, the debounce guard resets and a new publish goes out immediately. This is actually *better* behavior than persisting the timestamp (a crash likely means state changed), but worth a code comment explaining the intent.

---

## Code Correctness Assessment

| Aspect | Verdict | Detail |
|--------|---------|--------|
| Compiles? | ✅ Yes | `publishTopicList()` uses existing types (`TopicRepository`, `DatabaseManager`, `rpcClient.chatInject`) correctly |
| Types match? | ⚠️ Partial | `Date?` encoding mismatch (W2), otherwise struct fields match iPhone's `TopicPayloadItem` |
| Call sites safe? | ✅ Yes | All 5 call sites are `await`-ed after local DB writes complete. No fire-and-forget without `await` |
| Race conditions? | ⚠️ One | `SyncBridge` is an actor, so `publishTopicList()` is isolated. But `lastPublishAt` is actor-isolated state, so the throttle guard is safe. The debounce *logic* is wrong (W1), but it's not a race |
| Gateway API? | ✅ Yes | `chatInject(sessionKey:message:label:)` exists in `RPCClient` and returns `String` (runId). Already used elsewhere for session resets |
| Session key correct? | ✅ Yes | `"agent:main:beechat-sync"` matches the iPhone's `syncSessionKey` constant exactly |
| Error handling? | ✅ Good | `try?` on DB fetch, `catch` on `chatInject` — failures are logged, not fatal |

---

## Impact on Mac App

| Concern | Risk | Mitigation |
|---------|------|-----------|
| Messaging breakage | **None** | `publishTopicList()` is fully additive. No existing methods are modified. The 5 call sites are `await`-ed after their respective operations complete. |
| Performance | **Negligible** | DB read + JSON encode + one RPC call, throttled to max once per 30s. `chat.inject` is fast (~10ms). |
| UI blocking | **None** | All call sites use `Task { await ... }` or are already in async contexts. No synchronous waits. |
| Data corruption | **None** | The sync session (`agent:main:beechat-sync`) is separate from all topic sessions. Injecting there cannot affect user-facing messages. |
| Rollback | **Clean** | Remove 5 call sites + `publishTopicList()` method. No schema changes, no migration, no persistent state. |

---

## Approval Decision

**APPROVE WITH WARNINGS**

The spec is implementable. The two warnings (W1: debounce logic mismatch, W2: Date encoding) should be fixed during implementation — they're straightforward code changes, not design changes. The concerns (C1–C3) are testing observations, not blockers.

**Implementation priority:**
1. Fix W2 (Date encoding) — 2-line change, prevents silent data loss
2. Fix W1 (debounce pattern) — small refactor, ensures topic mutations always publish
3. Proceed with the 5 call sites and payload format as specified
4. Test C1 (cold launch), C2 (session change frequency), C3 (sync session growth) in QA