# Component 3 Spec Review — SyncBridge

**Reviewer:** Kieran (Continuous Review Gate)
**Date:** 2026-04-17
**Spec:** `Docs/Architecture/COMPONENT-3-SYNC-BRIDGE-SPEC.md`
**Validated Against:**
- Live gateway capture: `GATEWAY-PROBE-CAPTURE.json`
- Component 1 source: `BeeChatPersistence/`
- Component 2 source: `BeeChatGateway/`

---

## SPEC GOOD

### Interface Compatibility — Mostly Correct

1. **`GatewayClient`** in Component 2 exposes exactly the three interfaces the spec assumes:
   - `eventStream() -> AsyncStream<(event: String, payload: [String: AnyCodable]?)>` ✅
   - `call(method:params:) async throws -> [String: AnyCodable]` ✅
   - `connectionState: ConnectionState` ✅ (public computed var)

2. **`GatewayEvent`** enum in Component 2 matches the spec's event type list exactly. The spec's comment about "the GatewayEvent enum has been updated in Component 2" is accurate.

3. **RPC methods** confirmed in live `hello-ok.features.methods`:
   - `sessions.list` ✅
   - `chat.history` ✅
   - `chat.send` ✅
   - `chat.abort` ✅

4. **GRDB ValueObservation pattern** correctly specified for DB → UI observation. The `Session` and `Message` models in Component 1 are both `FetchableRecord` + `MutablePersistableRecord` with upsertColumns defined — compatible with the upsert strategy.

5. **Upsert strategy** correctly targets `Session.upsertColumns` and `Message.upsertColumns` — existing repository `upsert` implementations will apply.

6. **Delivery ledger design** (Migration003) is structurally sound. Indexes on `status` and `sessionKey` are the right choice for the reconciliation queries described.

7. **Streaming delta buffer** correctly identified as in-memory only (not persisted). `phase: "final"` triggers DB write, `phase: "delta"` is ephemeral — this matches the observed behavior.

8. **Seq tracking** correctly specified as memory-only with gap detection triggering reconciliation.

9. **Exit criteria are testable in isolation** — no live gateway required for DB layer, event routing, delivery ledger, and reconciler unit tests.

---

## SPEC CONCERN

### 1. `AgentEventData` Is Missing Fields Captured in Live Events

**Problem:** The spec's `AgentEventData` struct captures: `itemId`, `phase`, `kind`, `title`, `status`, `name`, `text`, `toolCallId`.

Live gateway capture shows `data` objects with **additional fields the spec doesn't model**:

| Field | Observed In | Type |
|-------|-------------|------|
| `meta` | `kind: "tool"` and `kind: "command"` | `String?` — full command description |
| `progressText` | `kind: "command"` | `String?` — streaming progress text |
| `output` | `stream: "command_output"`, `phase: "delta"` | `String?` — streamed command output chunks |
| `status` values beyond "running" | `kind: "command"` | `String?` — also "completed", "error", "cancelled" |

The spec's `text` field covers text stream items but not `output`. The `command_output` stream type is completely absent from the spec's stream types list (which says only `"item"` or `"text"`).

**Impact:** If a command runs and produces output, the bridge won't be able to surface it in the streaming buffer because `AgentEventData` has no `output` field.

**Fix:** Add `meta`, `progressText`, and `output` to `AgentEventData`.

---

### 2. `AgentEventPayload.stream` Has Undocumented Values

The spec documents `stream: "item"` and `stream: "text"`. Live capture shows `stream: "command_output"` (with `phase: "delta"`) carrying streaming command output chunks via the `output` field.

The spec needs `stream: "command_output"` added to the valid stream types and handling rules extended.

---

### 3. `AgentEventData.kind` Has `command` Variant Not in Spec

The spec lists `kind: "tool"` and `kind: "text"`. Live capture shows `kind: "command"` (e.g., itemId prefix `"command:ollama_call_..."`). The `command` kind carries `progressText`.

**Fix:** Add `kind: "command"` to handling rules. Likely a no-op for v1 (skip or store as metadata), but the model needs to represent it without crashing.

---

### 4. Wrong Type Name in `SyncBridge.Configuration`

**Problem:** The spec references:
```swift
public let persistenceStore: BeeChatPersistenceStore
```

But in Component 1 source, the concrete type is `BeeChatPersistenceStore` which **conforms to** `MessageStore` and `GatewayEventConsumer`. However, the spec says `BeeChatPersistenceStore` exposes `handleSessionList`, `handleNewMessage`, etc. directly — these are the `GatewayEventConsumer` protocol methods, not `BeeChatPersistenceStore`'s own methods.

The spec should reference the protocol, not the concrete class. The concrete class is fine to use, but the interface description conflates the protocol with the type.

**Fix:** Change spec to reference `some MessageStore & GatewayEventConsumer` or clarify that the config holds `BeeChatPersistenceStore` (concrete) and the consumed interface is `GatewayEventConsumer`.

---

### 5. Client Mode Conflict — `webchat` vs `operator`

**Problem:** The spec says:
> The WebSocket client must connect with `client.mode: "webchat"` (not `"operator"`). The gateway schema validates `mode` against a strict enum.

But Component 2's `GatewayClient.Configuration.clientInfo` default is:
```swift
mode: "operator"
```
This is hardcoded in the default `ConnectParams.ClientInfo`.

The live gateway capture also shows a `cli` node in `presence.snapshot` with `mode: "webchat"` — confirming `webchat` is a valid mode for non-gateway clients.

**Impact:** If Component 2 isn't updated to allow configurable mode, Component 3 will be specification-correct but implementation-incompatible with the gateway's mode validation.

**Fix:** Component 2's `GatewayClient.Configuration` needs a `clientInfo.mode` that Component 3 can set to `"webchat"`. This is a **Component 2 change required before Component 3 build begins**.

---

### 6. `GatewayEventConsumer` Protocol Is More Granular Than `BeeChatPersistenceStore`

**Problem:** The spec says `BeeChatPersistenceStore` implements `GatewayEventConsumer` with these methods:
- `handleSessionList(_ sessions: [Session])`
- `handleNewMessage(_ message: Message)`
- `handleMessageUpdate(_ message: Message)`
- `handleSessionUpdate(_ session: Session)`

These match the actual protocol. However, the spec then says SyncBridge will call `persistenceStore.saveMessage()` and `persistenceStore.upsertMessages()` directly — not via `GatewayEventConsumer`. The `GatewayEventConsumer` protocol exists but may not be the primary path SyncBridge uses for DB writes.

**Fix:** Clarify in the spec whether SyncBridge writes via `GatewayEventConsumer` protocol methods or directly via `MessageStore`/`SessionRepository` methods. This affects how the integration test doubles are structured.

---

### 7. `health` Event Session Data Not Specified for DB Use

**Problem:** The spec says health events update connection health state in memory and extract session metadata — but doesn't say what to do with `sessions` data from the health payload. Live capture shows `health.payload.sessions` contains per-session metadata (count, recent keys, path, etc.).

The spec should specify: does `health.sessions` feed into session metadata in DB, or is it informational only?

**Fix:** Add a rule: "Do not write `health.sessions` data to the sessions table — use `sessions.list` RPC for authoritative session metadata."

---

## SPEC GAP

### 1. Missing `hello-ok.snapshot` Handling

The spec correctly identifies `hello-ok.payload.snapshot` as the initial state bootstrap. But the spec's reconnect sequence doesn't mention re-reading `hello-ok.snapshot` on reconnect. On reconnect, after handshake, the gateway re-sends `hello-ok` — the spec should clarify this is the reconnect snapshot and the same handling applies.

---

### 2. `sessions.subscribe` Method Not Used

The spec uses `sessions.list` for session fetching but doesn't subscribe to session invalidation events via `sessions.subscribe`. The reconnect strategy calls `sessions.list` for reconciliation, but there's no mention of calling `sessions.subscribe` to receive `sessions.changed` events.

The spec says "subscribe to gateway event stream" in the start() logic, which would include `sessions.changed` — but explicitly calling `sessions.subscribe` RPC may be required for the gateway to start delivering those events. The live capture shows `sessions.subscribe` is in `hello-ok.features.methods`.

**Fix:** Add step in `start()` to call `sessions.subscribe` (empty params) after connect, if the gateway requires explicit subscription for session invalidation events.

---

### 3. Delivery Ledger Reconciliation — Missing Detail on Pending Entry Reuse

**Problem:** The spec says on reconnect: "For each `pending` delivery ledger entry, check if message appears in history. If found: mark as `delivered`. If not found after timeout: mark as `failed`."

But the spec doesn't specify: what happens to `pending` entries that correspond to runs still in flight at disconnect? The reconnect could fetch history that doesn't yet include the response. The spec doesn't handle the case where a `pending` entry needs to be retried (resend with same idempotency key) vs. reconciled as delivered.

**Fix:** Add to reconnect reconciliation:
1. For each `pending` delivery ledger entry, check if `runId` is set
2. If `runId` is set and not in history → mark as `failed` (server lost it)
3. If `runId` is set and IS in history → mark as `delivered`
4. If `runId` is nil and content not in history → keep as `pending` (ambiguous — could be in flight; wait for next event)

---

### 4. Streaming Buffer — No Concurrent Stream Handling

The spec shows `streamingBuffer: [String: String]` (one buffer per runId) which can handle multiple concurrent runs. But it doesn't specify what happens when:
- The user switches sessions mid-stream (clear buffer for old session?)
- Two streams for the same sessionKey arrive simultaneously (shouldn't happen in practice but possible)

**Fix:** Add: "On session key change, clear any in-progress streaming buffer for the previous session. On `agent` event for unknown `runId` where another stream is already in progress, buffer both separately — the UI should display the most recent stream only."

---

### 5. Observation Pattern — ValueObservation to AsyncStream Bridge Not Specified

The spec says SessionObserver and MessageObserver use GRDB ValueObservation and "Map to AsyncStream for SwiftUI consumption." But there's no concrete implementation sketch for the mapping. Specifically:
- How does `ValueObservation.tracking(...).publisher(in:)` (Combine) convert to `AsyncStream`?
- Is there a cancellation/reObservation lifecycle?

**Fix:** Add a brief note: "Implementation uses a continuation-based wrapper. On new observation, the existing observation is cancelled and a new one started. The AsyncStream is structured with an AsyncStream<[Session]>.Continuation that is stored and fed from ValueObservation callbacks."

---

### 6. Error Handling — DB Write Failure Not Defined for Critical vs Non-Critical

**Problem:** The spec says "DB errors should not crash the sync loop" but doesn't distinguish between:
- Session upsert failure (sync can't progress — degraded but observable)
- Message upsert failure (one message lost, rest fine)
- Delivery ledger failure (message send tracking lost — could cause duplicate sends)

**Fix:** Add severity classification:
- `sessions` table write failure → SyncState.degraded (connection OK, session list stale)
- `messages` table write failure → log + continue (message will be refetched on next history reconciliation)
- `delivery_ledger` write failure → `failed` state for that entry, don't lose track

---

### 7. No Mention of `chat` Event in Live Capture

The spec correctly identifies `agent` as the primary event based on live capture. But `hello-ok.features.events` in the live capture includes `chat` (not just `agent`). The spec acknowledges `chat` events exist but dismisses them as not primary. However, the relationship between `agent` and `chat` events (are they aliases? does one subsume the other?) is not specified.

**Fix:** Add note: "The gateway emits both `agent` and `chat` events. For BeeChat v5, `agent` is the primary transcript event. `chat` events, if received, should be logged as unknown and routed to the same handler as `agent` events for the duration of v1."

---

## ACTION ITEMS

### Must Fix Before Build

1. **[Component 2]** Add `mode` as a configurable property on `GatewayClient.Configuration.clientInfo`. Default can stay `operator` but Component 3 needs to set it to `"webchat"`. This is a Component 2 one-line change.

2. **[Spec]** Add `meta: String?`, `progressText: String?`, `output: String?` to `AgentEventData` struct.

3. **[Spec]** Add `stream: "command_output"` to valid stream types. Document that `command_output` events carry `output: String?` for streamed command chunks.

4. **[Spec]** Add `kind: "command"` to `AgentEventData` handling rules (likely skip for v1).

5. **[Spec]** Fix `SyncBridge.Configuration.persistenceStore` type annotation to clarify it's `BeeChatPersistenceStore` (concrete) and the consumed interface is `GatewayEventConsumer`.

6. **[Spec]** Add note about `health.sessions` — do not use for session metadata, use `sessions.list` RPC only.

7. **[Spec]** Add `sessions.subscribe` call after connect in `start()` lifecycle.

8. **[Spec]** Add delivery ledger reconciliation detail for `pending` entries with and without `runId`.

9. **[Spec]** Add session-switch clears streaming buffer rule.

10. **[Spec]** Add severity classification for DB write failures.

### Should Fix Before Build

11. **[Spec]** Clarify whether SyncBridge writes via `GatewayEventConsumer` protocol or directly via `MessageStore`/`SessionRepository` methods.

12. **[Spec]** Add concrete note on ValueObservation → AsyncStream implementation pattern.

13. **[Spec]** Add `hello-ok.snapshot` handling on reconnect.

14. **[Spec]** Add `chat` event handling note (treat as `agent` alias for v1).

### Nice to Have

15. Consider adding a `GatewayEventDecoder` layer in the spec that isolates decoding of polymorphic `data` fields so it can evolve without changing the router.

---

## Verdict

**Build status: ⚠️ BLOCKED on Item #1 (Component 2 mode configuration) and Item #5 (AgentEventData missing fields).**

Items 1 requires a Component 2 change before Component 3 can connect with the correct mode. Items 2–4 are data model gaps that would cause live events to be incompletely decoded. Items 6–10 are spec completeness issues that can be addressed by the coder with clarification, but without them the coder will make assumptions that may not match intent.

The spec is otherwise well-validated against the live gateway and correctly identifies the right architecture (DB-first, upsert, ephemeral deltas, GRDB observation, delivery ledger). The reconnect strategy and seq tracking logic are sound.

**Recommended path:** Fix Component 2 (Item #1) and update the spec with Items #2–#10 before any code is written.