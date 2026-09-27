# FIX-002: Content-Hash Dedup Guard for Assistant Messages

**Priority:** High
**Status:** Spec — approved by Adam (BeeChat, 2026-09-01)
**Author:** Bee (Coordinator), diagnosis from live BeeChat.sqlite evidence
**Builder:** Q
**Reviewer:** Kieran (Standard tier — structured code review required before merge)
**Date:** 2026-09-01

## Problem

Duplicate assistant messages appear in the BeeChat UI. Confirmed live in `BeeChat.sqlite`
on 2026-08-31: the same assistant reply persisted twice — identical 12,528-character
content, **identical timestamp**, but **two different UUIDs**:

```sql
2C70DF28-... | 2026-08-31 18:26:11 | assistant
AA5D1F94-... | 2026-08-31 18:26:11 | assistant
```

Wider scan of the session showed ~51 of ~120 recent assistant messages were
content-duplicates (same 120-char prefix as another row).

## Root Cause (traced, evidence-backed)

**The existing dedup guard (FIX-001, commit `b2c328a`) keys on message *id* — it cannot
catch same-content, different-id duplicates.**

`EventRouter.handleSessionMessage()` (Sources/BeeChatSyncBridge/EventRouter.swift:69-105):

```swift
let messageId = sessionMsg.data.id ?? UUID().uuidString()
let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
if !exists {
    let message = Message(id: messageId, ...)
    try await syncBridge.saveGatewayMessage(message)
}
```

When the gateway delivers the same assistant content with **no `id`** (or two different
ids for the same logical message), each delivery generates a fresh `UUID()` — so
`messageExists(id:)` returns false for both, and `MessageRepository.save()` →
`upsertPreservingCreatedAt(db)` (keyed on id) persists both copies.

The two ingestion paths that collide:
1. Streaming-delta events / `session.message` events persisting intermediate state.
2. `processChatFinal()` → `fetchHistory()` re-fetching the same messages and upserting.

The streamed copy gets one UUID, the history-reconcile copy gets another — same content,
same timestamp, both saved. **FIX-001 was correct for same-id re-delivery (reconnect/
reconciliation) but does not cover this case.**

## Scope

**In scope (minimal):**
- Add a content-hash dedup guard for assistant messages persisted from sync paths.
- Guard: before persisting a new assistant message (in `handleSessionMessage` and the
  `fetchHistory` upsert path), skip if a row exists for the same `sessionId` + `role =
  "assistant"` + same `content` within the same turn window (e.g. same timestamp bucket,
  or a recent threshold).

**Out of scope (as per FIX-001):**
- No changes to `MessageListObserver`, `MessageCanvas` scroll behavior, or retry logic
  in `processChatFinal`.
- No changes to the live-streaming display path (streaming is a separate concern, already
  grouped at render time per commit `249c04b`).
- No schema changes.

## Specification

### 1. `SyncBridge.contentExists(sessionKey:content:)` (new)

Add a method to check for an existing assistant message with identical content:

```swift
/// Returns true if an assistant message with the same content already exists
/// for this session within the dedup window. Fail-open on DB error (return false).
internal func contentExists(sessionKey: String, content: String, windowSeconds: TimeInterval = 180) throws -> Bool {
    let writer = try DatabaseManager.shared.writer
    let threshold = Date().addingTimeInterval(-windowSeconds)
    return try writer.read { db in
        try Message
            .filter(Column("sessionId") == sessionKey)
            .filter(Column("role") == "assistant")
            .filter(Column("content") == content)
            .filter(Column("timestamp") >= threshold)
            .fetchCount(db) > 0
    }
}
```

**Constraints:**
- `throws`, not force-unwrap.
- Synchronous GRDB read (fast), but callable from non-isolated context — mirror the
  `messageExists` pattern (`try? await syncBridge.contentExists(...) ?? false`).
- **Fail-open:** any DB error → treat as "does not exist" so we never lose a message on a
  transient error. Duplication is a cosmetic bug; losing messages is not acceptable.

### 2. Dedup guard in `EventRouter.handleSessionMessage()`

Precede the id-guard with the content-guard for assistant messages:

```swift
let contentDup = sessionMsg.data.role == "assistant"
    ? ((try? await syncBridge.contentExists(sessionKey: sessionKey, content: sessionMsg.data.content)) ?? false)
    : false
if contentDup { return }          // same content already persisted — skip
// ... existing id-based dedup guard fallback ...
```

Keep the existing id-guard too (it is cheaper and covers same-id re-delivery).

### 3. The `windowSeconds` parameter

- Default **180s** (3 min) — matches the observed duplicate delivery cadence (copies
  landed 3.5 minutes apart in the DB evidence; 180s captures the twin while not
  incorrectly suppressing legitimate rapid-fire distinct-but-short replies like "🐝" or
  "NO_REPLY").
- If a follow-up message genuinely repeats identical content within 3 minutes it *should*
  be suppressed; that is the intended behaviour.

## Files Changed

| File | Change |
|------|--------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `contentExists(sessionKey:content:windowSeconds:)` |
| `Sources/BeeChatSyncBridge/EventRouter.swift` | Add content-dedup guard in `handleSessionMessage()` before/alongside id-guard |

## Validation Criteria

1. **Build:** `xcodebuild -scheme BeeChatApp -destination 'platform=macOS' build` passes.
2. **Repro then fix:** Re-run the scenario that produced the 2026-08-31 twin (assistant
   reply arriving via both stream + history-reconcile with no message id) — assert only
   ONE row persists.
3. **No regressions:** App connects, shows topics, streams AI responses, sends messages —
   same as baseline.
4. **No false suppression:** Sending two genuinely different assistant messages within 180s
   (distinct content) still shows both.
5. **Fail-open tested:** Simulate a DB read error → message is still persisted (no loss).

## Kieran Review Notes (expected)

- **TOCTOU race (Low):** between `contentExists` and the write, a reconcile could still
  insert the twin. Mitigate by also checking inside the same write transaction if cheap;
  otherwise accept (cosmetic, same-class as FIX-001's accepted TOCTOU).
- **Query cost (Low):** content-equality scan over recent assistant rows per message is
  bounded by the 180s window + session — acceptable. Index on `(sessionId, role,
  timestamp)` if it shows up in profiling.
- **`windowSeconds` tuning:** validated default 180s is a heuristic; keep it a named
  constant for one-line tuning.

## Relationship to FIX-001

- **FIX-001** (`b2c328a`, archived): message-**id** dedup guard — handles same-id
  re-delivery (reconnect/reconciliation). **Already merged, keep it.**
- **FIX-002** (this): content-**hash** dedup guard — handles same-content/different-id
  duplicates. **New work.** Both guards together cover the full duplication space.

## Rollback

If this fix causes regression, revert both files to the pre-change state. No other files
touched.
