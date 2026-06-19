# KIERAN REVIEW: GATE-2F Mac-Side Topic Publishing

**Reviewer:** Kieran (adversarial)
**Date:** 2026-05-28
**Spec:** `GATE-2F-MAC-TOPIC-PUBLISH.md`
**Verdict:** ⚠️ **CONDITIONAL PASS** — 2 blockers, 3 conditions, 5 concerns

---

## Blockers (must-fix — showstoppers)

### B1. Debounce drops the last change in a burst

The spec says: *"Each call cancels the previous debounce timer and schedules a new one (so the last change in a burst always publishes)."* But the implementation sketch does **no such thing**. The code is:

```swift
private var lastPublishAt: Date = .distantPast
private static let publishDebounceInterval: TimeInterval = 30.0

public func publishTopicList() async {
    let now = Date()
    guard now.timeIntervalSince(lastPublishAt) >= Self.publishDebounceInterval else {
        print("[SyncBridge] publishTopicList: debounced")
        return   // ← DROPS THE CALL ENTIRELY
    }
    // ... fetch, build, inject ...
    lastPublishAt = Date()
}
```

This is a **cooldown**, not a debounce. A debounce reschedules a delayed publish so the *last* event in a burst always fires. This code silently discards any call within 30s of the last publish. Concrete scenario:

1. Mac publishes topics at T=0 (startup)
2. User archives a topic at T=5 → `publishTopicList()` called → **DROPPED** (within 30s)
3. No further triggers fire. The iPhone never learns about the archive.

The iPhone still shows the topic as active until the next trigger happens to fall outside the 30s window. If the user archives a topic and walks away, the iPhone is permanently stale until the next `sessions.changed` event, app restart, or manual topic change 30+ seconds later.

**Fix:** Replace the cooldown guard with a `Task`-based debounce that reschedules on each call:

```swift
private var publishTask: Task<Void, Never>?

public func publishTopicList() {
    publishTask?.cancel()
    publishTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s delay
        guard !Task.isCancelled else { return }
        await self.performPublish()
    }
}
```

This guarantees the last call in a burst always publishes. The 30s cooldown is the wrong primitive here; what you want is a short delay that resets on each call, then fires once.

---

### B2. Actor re-entrancy: `publishTopicList()` is `async` on an `actor`, called from multiple `Task` contexts

`SyncBridge` is an `actor`. The spec wires `publishTopicList()` from five call sites, several using `Task { @MainActor in ... await bridge.publishTopicList() }`. Multiple calls can be in-flight simultaneously inside the actor because `await` suspends, allowing interleaving.

The implementation sketch reads `lastPublishAt` and writes it without holding a lock (actors serialize *suspension points*, but the entire method is not atomic — an `await` in step 6 (`chatInject`) yields the actor between the debounce check and the `lastPublishAt` write). Two concurrent calls could both pass the debounce guard, both fetch topics, both inject — producing two payloads in the sync session. Not catastrophic, but wasteful and confusing.

More importantly: if two calls *both* pass the debounce guard (possible during the gap between actor suspensions), both call `chat.inject`, and both succeed. The sync session now has two topic-list messages. The iPhone reads the *latest* message (`limit: 1` in `fetchSyncPayload`), so the data is correct — but the earlier message is orphaned noise. This is acceptable only if the iPhone always reads the most recent message, which it does. So this is a minor inefficiency, not data corruption.

However, the real re-entrancy risk is: **two calls both set `lastPublishAt = Date()` after their respective `chatInject` calls succeed**. The second one overwrites the first. Since they're ~milliseconds apart, this is fine in practice. Not a true blocker, but the debounce logic (B1) is the real problem.

**Combined with B1:** The current code's debounce guard will *sometimes* let both calls through (during actor suspension interleaving) and *sometimes* drop calls that should publish. It's nondeterministic. The fix for B1 (Task-based debounce) also resolves this concern by serialising through a single rescheduled Task.

---

## Conditions (things that must be true for this to work)

### C1. `chat.inject` on `agent:main:beechat-sync` must create the session if it doesn't exist

The spec assumes that `rpcClient.chatInject(sessionKey: "agent:main:beechat-sync", ...)` works even when no session with that key exists. The RPCClient just calls `gateway.call(method: "chat.inject", params: ...)`. If the gateway requires the session to exist before injecting, this fails silently on first launch (before any iPhone has connected and created the session).

**Condition:** Verify that `chat.inject` with a non-existent `sessionKey` creates the session automatically. If it doesn't, `publishTopicList()` needs a pre-check: call `sessionsList()` or `sessionsCreate()` first. The iPhone side works because it *reads* from the session; the Mac *writes* to it, so the Mac must ensure it exists.

### C2. `fetchAllActive()` default limit is 100, not unlimited

The spec's code calls `topicRepo.fetchAllActive()` without a limit argument. The repository default is `limit: 100`. The spec's payload truncation is `.prefix(50)`. So the code fetches up to 100, then truncates to 50. If a user has 75 active topics, topics 51–75 are silently excluded from the iPhone payload. The 50-topic cap is defensible, but the mismatch between 100 and 50 is confusing. Either:

- Change `fetchAllActive()` call to pass `limit: 50` (fetch only what you'll publish), or
- Document the 50-cap explicitly and explain what happens to topics 51+.

### C3. The iPhone must handle receiving multiple `chat.inject` messages in the sync session

Each `publishTopicList()` call injects a new message. Over time, the sync session accumulates many messages. The iPhone reads only the latest one (`limit: 1`). This works, but:

- The sync session grows unboundedly. Is there a gateway-side message limit or TTL? If not, over months of usage, this session could accumulate thousands of stale topic-list payloads.
- The iPhone's `fetchSyncPayload` calls `chatHistory(sessionKey: ..., limit: 1)`. This fetches the *most recent* message, which is correct. But it's relying on the gateway returning messages in reverse chronological order. Confirm this is guaranteed.

### C4. `lastMessagePreview` must not contain PII or excessive content

The spec says `lastMessagePreview` is "first line of last message, or nil." If the last message in a topic contains sensitive information (passwords, tokens, personal details), this gets injected into the sync session payload in cleartext. The payload is stored in the gateway session history.

**Condition:** Either truncate `lastMessagePreview` to a short length (e.g., 80 characters), strip obvious secrets (URLs with tokens, lines matching common secret patterns), or make it optional in the payload so the Mac can send `nil` for privacy. The iPhone already handles `nil` for this field.

### C5. Startup publish must happen *after* `fetchSessions()` completes

The spec places the startup call after `bridge.start()` succeeds. But `start()` calls `fetchSessions()` internally. If `publishTopicList()` is called before the internal `fetchSessions()` populates `knownSessionKeys`, the topics may not have their session keys resolved yet. Verify the timing: topics should be fully hydrated (including `sessionKey`) before publishing.

---

## Concerns (watch during testing)

### W1. Stale data on iPhone after archive within debounce window

Even with the fix for B1 (proper debounce), there's a window where the iPhone has stale data. If the debounce delay is 2s, the longest the iPhone can be stale is 2s. If the delay is longer (e.g., 5s), the window is 5s. This is probably acceptable for a sync mechanism, but it should be documented and tested: archive a topic, then immediately check the iPhone within the debounce window. The iPhone should still show the old topic list, then update within the debounce period.

The current 30s cooldown (not debounce) would make this window *up to 30 seconds or infinite* (if no further trigger fires). The fix for B1 reduces this to the debounce delay, which is much better.

### W2. `sessions.changed` trigger frequency

The spec triggers `publishTopicList()` on every `sessions.changed` event. If the gateway sends frequent session change events (e.g., during agent activity), this could cause many publish calls. The debounce (once fixed) handles this, but be aware that `sessions.changed` events could fire every few seconds during active agent sessions. The debounce delay should be long enough to coalesce bursts (2-5s is reasonable) but short enough that topic changes are reflected promptly.

### W3. `TopicSyncItem.lastActivityAt` is `Date?` but encoded as `String?` in the payload

The `TopicSyncItem` struct has `lastActivityAt: Date?`, but the payload format shows it as an ISO 8601 string. The `Codable` conformance will need a custom encoder/decoder to convert between `Date` and ISO 8601 string. The default `JSONEncoder` encodes `Date` as a Double (seconds since reference date), not as an ISO 8601 string.

**This will produce wrong output.** `JSONEncoder` with default `DateEncodingStrategy` encodes `Date` as `Double` (e.g., `756460800.329`), not as `"2026-05-28T14:40:55Z"`. The iPhone parser expects a string. This will silently produce unparsable payloads.

**Fix:** Either:
- Use `encoder.dateEncodingStrategy = .iso8601` on the encoder, or
- Change `lastActivityAt` to `String?` and format manually, or
- Add a custom `encode(to:)` / `init(from:)` on `TopicSyncItem`.

Same issue for `TopicListPayload.timestamp` — it's declared as `String` in the struct, so it's fine (manually formatted). But `lastActivityAt` is `Date?`, which will encode as a number by default.

### W4. No error classification in `chatInject` failure

The spec says: *"Log error, don't crash — iPhone works fine with stale data."* This is correct for transient failures (network, gateway down). But some errors are structural (malformed session key, auth failure, payload too large). Logging as a generic error and moving on means these failures are invisible. Consider at least classifying errors into retryable vs. permanent, and logging at appropriate levels.

### W5. `publishTopicList()` is called from `SyncBridgeObserver` which runs on `@MainActor`

The observer's `didReceiveSessionChange` wraps the call in `Task { @MainActor in ... await bridge.publishTopicList() }`. Since `SyncBridge` is an actor, `await bridge.publishTopicList()` hops to the actor's executor. This is fine, but it means the MainActor is blocked during the debounce check, topic fetch, and payload build. The actual network call (`chatInject`) suspends the MainActor. In practice this is negligible (SQLite reads and JSON encoding are fast), but be aware that rapid `sessions.changed` events will queue up MainActor work.

---

## Suggestions (defer if needed)

### S1. Consider a `label` prefix for the inject message

The spec uses `label: "beechat-topic-sync"` for the `chatInject` call. This is good — it allows the iPhone to identify topic-sync messages in the session history. Consider also prefixing the message content with a marker (e.g., `[BEECHAT-TOPIC-SYNC]`) for extra safety in parsing, in case other messages end up in the sync session.

### S2. Add a payload hash or sequence number for idempotency detection

If the Mac publishes the same topic list twice (e.g., due to a bug or network retry), the sync session accumulates duplicate messages. Adding a simple hash of the payload (or an incrementing sequence number) lets the iPhone skip duplicate payloads. Not needed for v1, but cheap insurance.

### S3. Consider `JSONEncoder.dateEncodingStrategy = .iso8601` as a global setting

Rather than manually formatting `timestamp` and remembering to handle `lastActivityAt` encoding, set the encoder's date strategy once. This prevents the entire class of Date-to-JSON encoding bugs.

### S4. Document the 50-topic truncation behavior explicitly

Topics 51+ silently disappear from the iPhone. If a power user has 60+ active topics, they'll wonder why some don't appear. At minimum, log when truncation occurs. Consider also making the limit configurable or returning a `truncated: true` flag in the payload so the iPhone can show a "some topics hidden" indicator.

### S5. Test the startup publish timing carefully

The spec places `publishTopicList()` after `bridge.start()` in `AppRootView`. But `start()` calls `fetchSessions()` which populates `knownSessionKeys`. If topics are created before `start()` completes (unlikely but possible in testing), their session keys may not be resolved. Ensure the topic list is fully hydrated before the startup publish.

---

## Approval Decision

**⚠️ CONDITIONAL PASS** — Ship after fixing B1 and W3.

| Item | Action |
|------|--------|
| **B1** (debounce is actually cooldown) | Replace cooldown guard with Task-based debounce that reschedules on each call. This is the central algorithmic bug. |
| **W3** (Date encoding in JSON) | Either set `JSONEncoder.dateEncodingStrategy = .iso8601` or change `lastActivityAt` to `String?` in `TopicSyncItem`. The default encoder will produce `Double` values, which the iPhone parser cannot handle. |
| **C1** (session auto-creation) | Verify that `chat.inject` creates `agent:main:beechat-sync` if it doesn't exist. If not, add a `sessionsCreate` call before the first inject. |
| Everything else | Ship and test. |

The architecture is sound — `chat.inject` into a sync session is the right approach, the payload format matches what the iPhone already parses, and the rollback story is clean (remove call sites, done). The two issues above are real bugs that would surface immediately in testing: B1 makes topic changes invisible to the iPhone for indeterminate periods, and W3 produces unparseable timestamps. Fix those and this is good to go.