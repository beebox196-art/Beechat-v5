# Phase 0 Research: Component 3, Sync Bridge

**Project:** BeeChat v5  
**Component:** Sync Bridge  
**Date:** 2026-04-17  
**Researcher:** Gav

## Executive Summary

The Sync Bridge should be built around the **current OpenClaw protocol v3 surface**, not older assumed event names. In the current public protocol and in ClawChat, the important live-update primitives are:

- `chat` events for transcript streaming
- `sessions.changed` for session-list invalidation
- `session.message` and `session.tool` for subscribed per-session transcript/event streams
- `tick` for liveness
- handshake `hello-ok.snapshot` for initial server snapshot
- RPC fetches such as `sessions.list`, `chat.history`, `chat.send`, `chat.abort`

I found **no evidence in the current public docs or ClawChat hooks of `state.snapshot` or `session.update` as active client-facing event names**. The modern equivalents appear to be:

- initial snapshot data inside `hello-ok.payload.snapshot`
- session index invalidation via `sessions.changed`
- transcript updates via `chat`, `session.message`, and `session.tool`

That matters because BeeChat v5 should not hard-code stale event names into the Sync Bridge.

---

## 1. Event Catalog

### 1.1 Frame model

The gateway WebSocket protocol uses three frame kinds:

- **Request:** `{ type: "req", id, method, params }`
- **Response:** `{ type: "res", id, ok, payload | error }`
- **Event:** `{ type: "event", event, payload, seq?, stateVersion? }`

The protocol docs explicitly document optional `seq` and `stateVersion` on event frames. This is the key hook for ordered replay, reconnect reconciliation, and deduplication.

### 1.2 Handshake events

#### `connect.challenge`
Gateway sends this before connect.

Shape:

```json
{
  "type": "event",
  "event": "connect.challenge",
  "payload": {
    "nonce": "…",
    "ts": 1737264000000
  }
}
```

Purpose:
- supplies nonce for signed device identity
- triggers client handshake

ClawChat behavior:
- stores `payload.nonce`
- sends `connect` request
- only includes `device` identity when it already has a `deviceToken`
- treats sending unsolicited device identity to token-only auth as risky, because their comments note the gateway may reject it as `not-paired`

#### `connect.welcome`
Observed in ClawChat for `channel` backend, not standard OpenClaw operator handshake.

Purpose:
- special-case connection success for non-handshake channel backend

### 1.3 Handshake success payload

`connect` returns `hello-ok` in a normal response, not an event.

Shape from docs:

```json
{
  "type": "res",
  "id": "…",
  "ok": true,
  "payload": {
    "type": "hello-ok",
    "protocol": 3,
    "server": { "version": "…", "connId": "…" },
    "features": { "methods": ["…"], "events": ["…"] },
    "snapshot": { "…": "…" },
    "policy": {
      "maxPayload": 26214400,
      "maxBufferedBytes": 52428800,
      "tickIntervalMs": 15000
    },
    "auth": {
      "deviceToken": "…",
      "role": "operator",
      "scopes": ["operator.read", "operator.write"]
    }
  }
}
```

Important fields for Sync Bridge:
- `features.methods`, `features.events` for capability discovery
- `snapshot` for initial state bootstrap
- `policy.tickIntervalMs` for liveness expectation
- `policy.maxPayload` for outbound media size constraints
- `auth.deviceToken` may need persisting

### 1.4 Current common event families from protocol docs

The public docs list these event families as current:

- `chat`
- `session.message`
- `session.tool`
- `sessions.changed`
- `presence`
- `tick`
- `health`
- `heartbeat`
- `cron`
- `shutdown`
- node pairing and invoke events
- device pairing events
- approval lifecycle events
- `voicewake.changed`

For BeeChat v5 Sync Bridge, the ones that matter most are:

#### `chat`
Purpose:
- real-time chat transcript streaming updates
- used by ClawChat for message deltas, finals, and errors

ClawChat payload model:

```ts
interface ChatDeltaPayload {
  runId: string
  sessionKey: string
  seq: number
  state: 'delta'
  message: ChatMessage
}

interface ChatFinalPayload {
  runId: string
  sessionKey: string
  seq: number
  state: 'final'
  message: ChatMessage
}

interface ChatErrorPayload {
  runId: string
  sessionKey: string
  seq: number
  state: 'error'
  errorMessage: string
}
```

Observed ClawChat behavior:
- ignores events for inactive session
- on `delta`, updates or creates one streaming assistant bubble
- on `final`, replaces streaming bubble with final content
- on `error`, marks streaming bubble as failed
- if a final arrives for a non-local run, reloads history from `chat.history`

Implication for BeeChat:
- `chat` is the primary bridge input for real-time transcript changes
- `delta` should generally update a temporary in-memory delivery/stream state, not insert a new DB row on every chunk
- `final` should upsert the durable message row
- `error` should update delivery state, not necessarily persist a permanent message row unless desired for UX

#### `sessions.changed`
Purpose:
- invalidate session index / metadata cache
- tells clients session list needs refresh

ClawChat does **not** subscribe to `sessions.changed` directly in `useSessions.ts`. Instead it listens to **all `chat` events** and debounces a `sessions.list` refresh by 1 second.

That is a simple but blunt approach. BeeChat v5 should do better:
- use `sessions.changed` when available for session list invalidation
- optionally also fall back to `chat`-driven refresh if session metadata lags behind transcript events

#### `session.message`
Purpose from docs:
- transcript updates for a subscribed session

Recommended use in BeeChat:
- prefer this for session-scoped transcript projection if you use `sessions.messages.subscribe`
- exact payload shape was not fully documented on the public protocol page I reviewed, so bridge code should isolate decoding behind versioned parsers

#### `session.tool`
Purpose from docs:
- tool/event-stream updates for a subscribed session

Recommended use:
- useful if BeeChat wants richer transcript rendering than plain chat history, for example tool calls/results, approvals, or execution detail rows
- not required for a minimal messenger-style v1 sync bridge

#### `tick`
Purpose:
- keepalive/liveness event

Use in bridge:
- update connection liveness clock
- detect silent stale connections when ticks stop beyond expected interval
- do not write to DB

### 1.5 About `state.snapshot`, `session.update`, and `agent`

The prompt asked specifically about `state.snapshot`, `session.update`, `agent`, and `tick`.

What I found:

- `tick` is present in the current docs and should be treated as active.
- `state.snapshot` is **not listed as a current common event** in the current public gateway protocol page.
- `session.update` is **not listed** in the current public gateway protocol page.
- `agent` is mentioned in ClawChat comments as a generic event emitter example, but I found **no actual handling in the reviewed hooks** and no clear listing in the current common event families section.

Conclusion:
- build BeeChat v5 around the events that are currently documented and observed in ClawChat, not around these older names
- treat `hello-ok.snapshot` as the modern initial snapshot mechanism
- treat `sessions.changed` as the modern session-index invalidation mechanism

---

## 2. RPC Method Catalog

## 2.1 Current method families from protocol docs

The public protocol docs list many gateway methods. For Sync Bridge, the relevant families are:

- `sessions.list`
- `sessions.subscribe`
- `sessions.unsubscribe`
- `sessions.messages.subscribe`
- `sessions.messages.unsubscribe`
- `sessions.preview`
- `sessions.resolve`
- `sessions.get`
- `chat.history`
- `chat.send`
- `chat.abort`
- `chat.inject`

Also useful for broader app assembly, but not core bridge logic:
- `status`
- `health`
- `system-presence`
- `channels.status`
- `tools.effective`
- `commands.list`

## 2.2 `sessions.list`

Purpose:
- initial session bootstrap
- session list refresh after invalidation

ClawChat request:

```ts
client.call('sessions.list', {})
```

ClawChat inferred response shape:

```ts
interface SessionsListResponse {
  sessions: SessionInfo[]
}

interface SessionInfo {
  key: string
  label?: string
  channel?: string
  model?: string
  totalTokens?: number
  [key: string]: unknown
}
```

ClawChat behavior:
- filters returned sessions to:
  - always include main session key `agent:main:main`
  - include others only when `totalTokens > 0`

BeeChat recommendation:
- persist all sessions returned by gateway unless product explicitly wants UI filtering only
- use `key` as canonical remote identity
- make `totalTokens`, `label`, `channel`, `model`, and last activity nullable, updatable metadata columns

## 2.3 `chat.history`

Purpose:
- bootstrap transcript for selected session
- reconciliation after reconnect
- hard refresh after receiving non-local final events

ClawChat request:

```ts
client.call('chat.history', {
  sessionKey,
  limit: 200,
})
```

ClawChat inferred request/response:

```ts
interface ChatHistoryParams {
  sessionKey: string
  limit?: number
}

interface ChatHistoryResponse {
  sessionKey: string
  sessionId: string
  messages: ChatMessage[]
  thinkingLevel?: string
}
```

Important protocol note from docs:
- `chat.history` is **display-normalized for UI clients**
- directive tags and tool-call XML can be stripped
- exact `NO_REPLY` assistant rows may be omitted
- oversized rows may be replaced with placeholders

That means:
- `chat.history` is a **UI-friendly projection**, not a perfect raw event ledger
- fine for chat UI bootstrap and reconnect reconciliation
- not ideal if BeeChat later wants exact raw audit transcript fidelity

## 2.4 `chat.send`

Purpose:
- send a user message into a session

ClawChat request shape:

```ts
interface ChatSendParams {
  sessionKey: string
  message: string
  idempotencyKey: string
  thinking?: string
  attachments?: ChatAttachment[]
}
```

ClawChat expects ack shape:

```ts
interface ChatSendAck {
  runId: string
  status: string
}
```

Important protocol rule:
- side-effecting methods require **idempotency keys**

Bridge implications:
- local outbound message rows should include an idempotency key
- map returned `runId` to local pending-send ledger entry
- if connection breaks after send but before ack, retry must reuse the same idempotency key if the app is attempting true idempotent resend

## 2.5 `chat.abort`

Purpose:
- stop active generation for a session

ClawChat inferred shape:

```ts
interface ChatAbortParams {
  sessionKey: string
}

interface ChatAbortResponse {
  ok: boolean
  aborted: boolean
  runIds?: string[]
}
```

ClawChat behavior:
- clears UI streaming state immediately without waiting for a confirming final/error event

BeeChat recommendation:
- do the same locally
- treat abort as local state change plus eventual server convergence

## 2.6 `sessions.subscribe` and `sessions.messages.subscribe`

The current public protocol docs list these methods but do not spell out payloads on the page reviewed.

Likely roles:
- `sessions.subscribe`: subscribe current WS client to session index/metadata change events
- `sessions.messages.subscribe`: subscribe current WS client to transcript updates for one session

Recommendation:
- design the bridge with a **subscription adapter** so these can be added cleanly even if Component 3 v1 starts with only `chat` + `sessions.list` + `chat.history`
- if the exact payload shape is uncertain at implementation time, discover via runtime `hello-ok.features.methods` and controlled logging during integration, not guesswork

---

## 3. Reconnect Strategy

## 3.1 What happens to in-flight requests when connection drops

Observed in ClawChat `GatewayClient`:
- on WebSocket close, all pending request promises are rejected
- pending request map is cleared
- reconnect is scheduled unless close is intentional or fatal
- fatal codes include `1008` and custom `4xxx`

Meaning for BeeChat:
- any `call()` may fail due to disconnect even if the server may have processed it
- especially for `chat.send`, you must assume **ambiguous completion** if drop happens after transmit but before ack

## 3.2 Recommended reconnect sequence

On reconnect:

1. complete handshake
2. persist any new `deviceToken`
3. record fresh connection metadata and last tick interval
4. refresh sessions via `sessions.list`
5. for the active session, fetch `chat.history(limit: N)` where `N` is enough to cover the reconnect gap
6. upsert messages idempotently into local DB
7. restore any local pending-send rows by reconciling them against returned history and known `runId` / idempotency keys
8. resume live event processing

## 3.3 Role of `seq` and `stateVersion`

The docs explicitly show event frames may include:

- `seq`
- `stateVersion`

These should be treated as follows:

### `seq`
Use as **event ordering and gap detection metadata**, scoped to the event stream.

Recommended use:
- keep `lastSeenEventSeq` in memory and optionally in DB
- if incoming `seq <= lastSeenEventSeq`, the event is duplicate or stale, so ignore it
- if incoming `seq > lastSeenEventSeq + 1`, assume a gap and trigger reconciliation for affected scope

Do **not** rely on `seq` as the only dedupe key for messages, because the same logical message can be represented by multiple events.

### `stateVersion`
Use as **snapshot/version watermark** for broader state convergence.

Recommended use:
- persist last applied `stateVersion` when present
- if reconnect gives a newer snapshot/version than your local watermark, treat snapshot plus history fetch as source of truth
- this is stronger than purely replaying deltas because it helps bridge past missed events

## 3.4 Should we request a snapshot on reconnect?

Yes, functionally, but with a nuance:

- I did **not** find a separate documented `state.snapshot` RPC/event in the current public docs
- the current protocol already gives a snapshot in `hello-ok.payload.snapshot`

So the reconnect strategy should be:
- treat **hello-ok snapshot as your initial reconnect snapshot**
- then run targeted refresh RPCs (`sessions.list`, `chat.history`) for durable state convergence

## 3.5 Duplicate handling on reconnect

The safe policy is:

- never insert blindly from live events
- always upsert by stable remote identity
- when reconnecting, fetch recent history and upsert again

This makes replay harmless.

Recommended reconciliation window:
- active session: fetch last 200 messages on reconnect, matching the Phase 2 plan already captured in memory
- inactive sessions: refresh only metadata first, lazy-load transcript when user opens session

---

## 4. Swift Reactive Pattern

## 4.1 Best fit: GRDB `ValueObservation` for DB to UI, async task for gateway to DB

Recommended split:

- **GatewayClient actor** owns websocket, RPC, reconnect, event stream
- **SyncBridge actor/service** consumes gateway events and writes to GRDB
- **GRDB `ValueObservation`** publishes DB-derived view state to SwiftUI

That gives the cleanest architecture boundary:

- network events mutate DB
- UI observes DB
- UI never depends on fragile in-memory event sequencing for correctness

That is the right shape for an offline-capable chat client.

## 4.2 Why `ValueObservation`

`ValueObservation` is a strong fit because it:
- tracks SQL-region changes automatically
- re-runs observed fetches when relevant rows change
- lets SwiftUI render from durable state instead of transport state
- naturally supports reconnect and app restart without rebuilding ephemeral caches

Recommended usage:
- session list observation: observe `sessions` table ordered by last activity
- conversation observation: observe `messages` joined to `attachments` for active session
- pending send badge observation: observe delivery ledger / message status table

## 4.3 Combine vs AsyncStream vs `@Observable`

Recommendation:

- **DB to UI:** use GRDB `ValueObservation`
- **Gateway to Sync Bridge:** use `AsyncStream` or an async sequence returned by `GatewayClient.eventStream()`
- **View model state:** use `@Observable` or `ObservableObject` as a thin wrapper around observed data

Best composition:

- `GatewayClient.eventStream()` -> `for await` loop inside SyncBridge actor
- SyncBridge writes to GRDB
- GRDB observations feed SwiftUI-facing query models

Why not just `AsyncStream` all the way to UI:
- because pure event-stream UI becomes fragile on reconnect, background/foreground transitions, and missed events
- DB-backed observations are much more resilient

Why not Combine-first:
- it works, but modern Swift concurrency plus GRDB observations is simpler and easier to reason about for this architecture

## 4.4 Pattern used by good chat clients

The durable pattern is:

1. network stream updates local store
2. UI binds to local store
3. reconnect resyncs the local store
4. pending delivery state is tracked separately from final transcript state

That is the pattern BeeChat should adopt.

---

## 5. Sync Bridge Architecture

## 5.1 Recommended modules

### `SyncBridge`
Main orchestrator.

Responsibilities:
- start/stop sync lifecycle
- subscribe to gateway event stream
- manage reconnect reconciliation
- route events to typed handlers
- expose connection/sync status

### `EventRouter`
Maps gateway event names to handlers.

Responsibilities:
- decode event envelope
- dispatch `chat`, `sessions.changed`, `session.message`, `session.tool`, `tick`
- centralize unknown-event logging

### `Reconciler`
Repairs state after reconnect or detected gaps.

Responsibilities:
- track `lastSeenSeq`, `stateVersion`
- detect gaps or duplicates
- run `sessions.list`
- run `chat.history` for affected session(s)
- mark local pending sends resolved/failed/retryable

### `PersistenceWriter`
Thin adapter from sync domain actions to `BeeChatPersistence` operations.

Responsibilities:
- upsert sessions
- upsert final messages
- update message status and attachments
- transactional application of related changes

### `DeliveryLedger`
Separate table/service for outbound message lifecycle.

Suggested columns:
- `localMessageId`
- `sessionKey`
- `idempotencyKey`
- `runId?`
- `remoteMessageId?`
- `status` (`queued`, `sending`, `streaming`, `sent`, `failed`, `aborted`)
- `lastError?`
- `retryCount`
- timestamps

This is important because `chat` delta/final events are **run-oriented**, not purely message-row-oriented.

## 5.2 Event routing table

Recommended mapping:

| Event / Call | Bridge action |
|---|---|
| `hello-ok.snapshot` | initialize connection metadata, capabilities, policy |
| `sessions.list` | upsert session rows |
| `sessions.changed` | invalidate session cache, refresh `sessions.list` |
| `chat` `state=delta` | update in-memory stream state and optionally delivery ledger, do not insert a new durable message row per chunk |
| `chat` `state=final` | upsert final message row, clear streaming state, resolve delivery ledger |
| `chat` `state=error` | mark delivery ledger failed, update transient UI state |
| `chat.history` | reconcile transcript by idempotent upsert |
| `session.message` | upsert/merge session transcript item if this richer subscription path is enabled |
| `session.tool` | persist tool event rows only if UI wants them |
| `tick` | update liveness clock only |

## 5.3 Suggested DB policies

### Sessions
- unique key: `session.key`
- upsert metadata fields only
- do not destroy local cached transcript on session metadata refresh

### Messages
Use a stable uniqueness strategy:

1. **Preferred:** gateway message `id` if exposed by payload/history
2. **Fallback:** composite natural key such as `(sessionKey, runId, role, timestamp, contentHash)`

Because the reviewed ClawChat types do not expose a formal message `id`, BeeChat should be ready for the case where history rows only provide content/timestamp/role and run context.

### Attachments
- separate `attachments` table keyed to local message row
- upsert by stable attachment identity when available, otherwise by `(messageId, fileName, mimeType, size, contentHash)`

## 5.4 Message deduplication strategy

### Is gateway `id` sufficient?

**Yes, if the gateway actually exposes a stable message ID in both live events and history.** That would be the best dedupe key.

But based on the reviewed ClawChat type definitions, I cannot confirm that current UI payloads always expose such an `id`.

So the bridge should support:

- primary key path: remote message ID when available
- fallback path: content-hash plus run/timestamp/session correlation

### For edits or reactions
Do not model them as new messages.

Recommended approach:
- keep a `messages` table for canonical message row
- keep optional related tables for:
  - message revisions
  - reactions
  - tool events
- apply updates as merges into existing rows keyed by remote message ID

If the gateway later emits dedicated edit/reaction events, route those to update existing rows rather than append transcript duplicates.

---

## 6. Error Handling and Offline Resilience

## 6.1 When `call()` fails

Treat failures by class:

### Transport/disconnect failure
- mark sync state degraded
- preserve pending local rows
- reconnect and reconcile
- do not assume request was never processed remotely

### Timeout
- same as transport ambiguity for side-effecting calls
- especially dangerous for `chat.send`
- retry only with idempotency awareness

### Gateway error response
- if explicit application error, mark local operation failed with surfaced error
- no blind retry unless error is known transient

## 6.2 Should the bridge retry?

Recommendation:

- **Reads** (`sessions.list`, `chat.history`) can be retried automatically with bounded exponential backoff
- **Writes** (`chat.send`) should not be blindly re-sent unless the same idempotency key is reused and the UX makes ambiguity clear

That means the bridge should distinguish:
- safe retriable read sync
- ambiguous write recovery

## 6.3 Partial sync policy

Handle sync by scope, not as one giant all-or-nothing transaction.

Recommended rules:
- session index refresh can succeed even if one session history fetch fails
- active conversation should surface `stale / retrying` state if history reconciliation failed
- inactive session histories should remain lazily loaded
- connection banner should report degraded sync without blocking cached transcript display

## 6.4 Offline-first UX model

Recommended local states:
- cached transcript visible offline
- pending outbound messages visibly marked
- failed sends retryable
- reconnect automatically re-runs reconciliation

This is exactly why the bridge should be DB-first.

---

## 7. ClawChat Sync Patterns

## 7.1 `useGateway.ts`

ClawChat pattern:
- recreates `GatewayClient` when url/token/backend/deviceToken changes
- stores connection status in React state
- auto-connect optional
- persists returned `deviceToken`
- disconnects and tears down cleanly on dependency change/unmount

Takeaways for BeeChat:
- connection object should be replaceable but owned centrally
- device token persistence is part of connection lifecycle, not a side effect buried in UI

## 7.2 `useSessions.ts`

ClawChat pattern:
- on connect, call `sessions.list`
- on disconnect, clear session list
- subscribe to `chat` events
- debounce `sessions.list` refresh by 1 second after chat activity

Takeaways:
- ClawChat uses transcript activity as a session-list invalidation signal
- simple and effective, but chat-driven refresh is broader than necessary
- BeeChat should prefer documented session invalidation events when possible

## 7.3 `useChat.ts`

ClawChat pattern:
- on active-session change, load `chat.history(limit: 200)`
- caches per-session messages in memory for fast tab switching
- optimistic local user message append on send
- tracks `runId` and local-run set to distinguish self-originated vs external updates
- on `chat.delta`, mutate a single streaming assistant bubble
- on `chat.final`, finalize bubble and reload history if event was not locally initiated
- on `chat.error`, mark bubble failed
- detects stalled streams after 90s without delta
- on connection loss while streaming, clears stuck state immediately

Best ideas worth copying:
- per-run local tracking instead of one global pending boolean
- reload history when a remote final arrives that was not locally initiated
- explicit stalled-stream timeout

But for BeeChat v5:
- move this logic out of view hooks and into Sync Bridge + persistence
- keep UI thin and observation-based

---

## 8. Risks and Gotchas

## 8.1 Building to stale event names

Biggest risk.

The prompt names `state.snapshot` and `session.update`, but current docs and ClawChat point to a different surface. If BeeChat implements against stale names, the bridge will be wrong on day one.

## 8.2 Treating deltas as durable messages

A `chat` delta is not a new message row. Persisting every delta chunk will duplicate transcript content badly.

## 8.3 Assuming `call()` failure means no remote effect

Wrong for `chat.send`. Network ambiguity means the server may have accepted the request before disconnect.

## 8.4 Relying only on in-memory state

If the bridge stores truth in memory instead of SQLite, reconnect and restart behavior will be brittle.

## 8.5 Assuming message `id` is always present

The cleanest dedupe path is remote message ID, but the reviewed ClawChat types did not prove that all current UI payloads include one. The bridge must support a fallback dedupe strategy.

## 8.6 Not separating delivery state from transcript state

Streaming runs, retries, aborts, and failures belong in a delivery ledger or message-status model, not only in the transcript table.

## 8.7 Missing gap detection

If `seq` jumps and BeeChat just keeps going, transcript divergence will accumulate silently.

## 8.8 Over-refreshing session list

ClawChat’s `chat`-driven debounce is fine for a small web client, but a native app should use narrower invalidation and avoid unnecessary RPC churn.

---

## 9. Recommended Build Spec for Component 3

1. Build `SyncBridge` as an **actor**.
2. Consume `GatewayClient.eventStream()` with typed event decoding.
3. Persist `hello-ok` connection metadata and capabilities.
4. On connect/reconnect, run:
   - `sessions.list`
   - `chat.history` for active session
5. Use GRDB upserts for sessions/messages/attachments.
6. Track `lastSeenSeq` and `stateVersion` when present.
7. Treat `chat.delta` as transient stream state, `chat.final` as durable transcript state.
8. Introduce `message_delivery_ledger` now or immediately after, not later.
9. Publish to SwiftUI via GRDB `ValueObservation`, not direct websocket callbacks.
10. Treat unknown event names as logged-but-nonfatal so protocol evolution does not crash the bridge.

---

## 10. Attribution

### Primary sources

1. **OpenClaw Gateway Protocol docs**  
   `https://docs.openclaw.ai/gateway/protocol`  
   Used for handshake, frame structure, common RPC families, event families, scopes, and protocol notes.

2. **OpenClaw docs index**  
   `https://docs.openclaw.ai/llms.txt`  
   Used to confirm available gateway documentation surface and page naming.

3. **ClawChat source: `useGateway.ts`**  
   `/tmp/beechat-research/clawchat/src/hooks/useGateway.ts`  
   Used to understand connection lifecycle, client recreation, and device token persistence.

4. **ClawChat source: `useSessions.ts`**  
   `/tmp/beechat-research/clawchat/src/hooks/useSessions.ts`  
   Used to understand session refresh behavior and chat-driven invalidation.

5. **ClawChat source: `useChat.ts`**  
   `/tmp/beechat-research/clawchat/src/hooks/useChat.ts`  
   Used to understand transcript streaming, run tracking, history reload, and stalled stream handling.

6. **ClawChat source: `gateway-client.ts`**  
   `/tmp/beechat-research/clawchat/src/lib/gateway-client.ts`  
   Used to understand handshake behavior, request/response correlation, reconnect logic, and pending request failure semantics.

7. **ClawChat source: `protocol.ts`**  
   `/tmp/beechat-research/clawchat/src/types/protocol.ts`  
   Used for concrete inferred TS payload shapes for `chat.history`, `chat.send`, and `chat` event payloads.

### Research judgment notes

- Where exact payloads were not fully spelled out in the public protocol page, I marked them as inferred from ClawChat types rather than pretending the docs gave exact schemas.
- Where the prompt referenced older event names not present in the current public protocol docs, I called that out directly instead of smoothing over it.
