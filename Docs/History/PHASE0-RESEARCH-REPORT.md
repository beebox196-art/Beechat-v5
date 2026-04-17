# BeeChat v5 — Phase 0 Research Report

**Date:** 2026-04-17  
**Researcher:** Gav  
**Timebox:** 4 hours max, completed within initial sprint  
**Project:** BeeChat v5  
**Status:** Research complete, ready for coordinator review

---

## Executive Summary

The best path for BeeChat v5 is:

1. **Persistence:** use **GRDB** over raw SQLite.swift or Core Data.
2. **Gateway transport:** adapt **ClawChat's protocol-aware `GatewayClient` pattern**, but port it into a native Swift module.
3. **Auth/pairing:** follow **OpenClaw protocol v3** exactly, especially `connect.challenge` → signed `connect` request → `hello-ok` handling and device-token persistence.
4. **Architecture:** keep v5 modular exactly as planned: **Persistence → Gateway → UI → Assembly**, with one shared gateway connection and gateway-owned session state.

My blunt view: ClawChat is very useful for **transport and auth behavior**, but **not** for persistence. It uses `electron-store`, not SQLite. So we should copy its gateway discipline, not pretend it already solved local message storage for us.

---

## Source Set

### Primary validated sources

1. **ClawChat** (`ngmaloney/clawchat`, MIT)
   - Local clone: `/tmp/beechat-research/clawchat`
   - Key files:
     - `src/lib/gateway-client.ts`
     - `src/hooks/useGateway.ts`
     - `src/hooks/useSessions.ts`
     - `src/types/protocol.ts`
     - `src/lib/device-crypto.ts`
     - `electron/main.ts`

2. **OpenClaw official docs**
   - `https://docs.openclaw.ai/gateway/protocol`
   - `https://docs.openclaw.ai/concepts/session`
   - `https://docs.openclaw.ai/channels/channel-routing`
   - `https://docs.openclaw.ai/cli/devices`
   - `https://docs.openclaw.ai/cli/gateway`

3. **Swift SQLite libraries**
   - **GRDB** (`groue/GRDB.swift`, MIT)
     - `https://raw.githubusercontent.com/groue/GRDB.swift/master/README.md`
   - **SQLite.swift** (`stephencelis/SQLite.swift`, MIT)
     - `https://raw.githubusercontent.com/stephencelis/SQLite.swift/master/README.md`
   - **Core Data**
     - Apple docs: `https://developer.apple.com/documentation/coredata`

---

## 1) ClawChat findings

## What ClawChat gets right

### A. Protocol-aware WebSocket client
`src/lib/gateway-client.ts` is the strongest prior art in the repo.

Useful patterns worth porting to Swift:

- **Single connection owner** for all gateway RPC and events.
- **Explicit connection state machine**: `disconnected`, `connecting`, `handshaking`, `connected`, `error`.
- **Request/response correlation** via `id` and a `pending` map with timeouts.
- **Reconnect with bounded exponential backoff**.
- **Protocol event split** between:
  - `connect.challenge`
  - `connect.welcome` for channel backend mode
  - normal event dispatch after handshake
- **Policy capture** from `hello-ok`, especially `policy.maxPayload`.

This is exactly the kind of thing BeeChat v4 kept muddling. v5 should have this as its own dedicated package: `BeeChatGateway`.

### B. Correct device handshake behavior
ClawChat correctly models the OpenClaw connect flow:

1. Open WebSocket with shared token in query string
2. Wait for `connect.challenge`
3. Build signed device identity
4. Send `connect` request with protocol bounds, client metadata, role/scopes, auth, optional device block
5. Read `hello-ok`
6. Persist returned `deviceToken`

Important subtlety already handled in ClawChat:

- **Only send `device` when a `deviceToken` already exists**. The comment in `gateway-client.ts` is explicit: sending an unsolicited device field to a token-auth gateway can cause rejection (`not-paired`).
- **Persist `deviceToken` from `hello-ok`** and reuse it on later connects.
- **Use current signing timestamp**, not challenge timestamp.

Those details are not optional. They are the difference between “looks right” and “actually pairs”.

### C. Device identity generation is simple and portable
`src/lib/device-crypto.ts` shows a clean device model:

- persistent keypair in local store
- stable `deviceId` derived from public key hash
- public key exported for transport
- challenge signature assembled from a versioned payload

This maps cleanly to Swift Crypto + Keychain.

### D. Session list refresh is gateway-driven
`src/hooks/useSessions.ts` is small but important:

- sessions come from **`sessions.list`**, not local inference
- local UI refreshes on gateway chat events
- UI filters presentation, but **gateway remains source of truth**

That matches OpenClaw docs exactly: gateway owns session state.

## What ClawChat does NOT solve

### A. No SQLite persistence layer
ClawChat does **not** provide a BeeChat-ready local message database.

Evidence:
- `electron/main.ts` uses **`electron-store`** for lightweight config persistence
- stored values are things like `gatewayUrl`, `token`, `deviceToken`
- no SQLite, GRDB, schema migrations, or offline message store found

So ClawChat is a **transport/auth/UI reference**, not a storage reference.

### B. React/Electron UI patterns are portable only conceptually
The hook structure is clean, but the code itself is not directly reusable in SwiftUI.
Adapt the architecture, not the framework code.

---

## 2) OpenClaw protocol and routing findings

## A. WebSocket protocol v3 shape
From `https://docs.openclaw.ai/gateway/protocol`:

- transport is **WebSocket + JSON text frames**
- first meaningful flow is gateway-sent **`connect.challenge`** event
- client must answer with a **`connect` request**
- protocol frames are:
  - request: `{type:"req", id, method, params}`
  - response: `{type:"res", id, ok, payload|error}`
  - event: `{type:"event", event, payload, seq?, stateVersion?}``

Handshake contract includes:
- `minProtocol: 3`
- `maxProtocol: 3`
- `client.id`, `version`, `platform`, `mode`
- `role`
- `scopes`
- `auth`
- optional `device`

Gateway returns `hello-ok` with:
- negotiated protocol
- server metadata
- features/methods/events
- snapshot
- policy, including `maxPayload`
- optional `auth.deviceToken`

## B. Auth and device token model
From docs plus `openclaw devices` docs:

- shared gateway token/password is still the base connection auth
- paired devices then receive **device-scoped tokens**
- device tokens can be rotated/revoked
- pairing actions require `operator.pairing` or admin
- reconnect precedence matters, and token drift recovery is a real operational concern

Practical implication for v5:

- store **gateway token** and **device token** separately
- treat device token as a renewable secret
- build recovery UI for mismatches, not just a generic “connect failed” state

## C. Sessions are gateway-owned
From `https://docs.openclaw.ai/concepts/session`:

- all session state is owned by the **gateway**
- clients query gateway for sessions and transcript data
- session store/transcripts live server-side under `~/.openclaw/agents/<agentId>/sessions/...`

That means BeeChat v5 should not try to become the canonical session system.

Recommended split:
- **Gateway remains source of truth for sessions and live conversation flow**
- **BeeChat local DB caches UI data for speed, search, and resilience**
- local cache must be replayable/rebuildable from gateway state where possible

## D. Session routing rules
From `https://docs.openclaw.ai/channels/channel-routing`:

Session key patterns matter a lot:
- main DM: `agent:<agentId>:<mainKey>`
- group: `agent:<agentId>:<channel>:group:<id>`
- channel/room: `agent:<agentId>:<channel>:channel:<id>`
- threads append `:thread:<threadId>`
- Telegram topics embed `:topic:<topicId>`

Example:
- `agent:main:telegram:group:-1001234567890:topic:42`

This supports the v5 design direction:
- do **not** invent a hidden alternate session-key scheme
- normalize, store, and render official OpenClaw session keys as first-class identifiers
- if BeeChat adds topic/session bridges later, treat them as local mapping helpers, not replacements for gateway keys

---

## 3) Swift SQLite options

## Option comparison

| Option | Strengths | Weaknesses | Fit for BeeChat v5 |
|---|---|---|---|
| **GRDB** | Mature, Swift-native, records, migrations, observation, strong concurrency story, WAL-friendly, raw SQL still available | Bigger abstraction surface, learning curve slightly higher | **Best fit** |
| **SQLite.swift** | Simple, lightweight, type-safe query builder, straightforward SQL wrapper | Thinner migration/observation story, less opinionated app architecture support | Good backup option |
| **Core Data** | Apple-native, tooling, object graph features | More complexity, awkward for explicit SQL/control, harder to keep protocol cache model clean | Poor fit |

## Recommendation: use GRDB

Why:

1. **BeeChat is a sync-heavy local cache app**, not an object graph app. GRDB fits that better than Core Data.
2. We need **explicit schema and migrations** from day one.
3. We need **concurrency discipline** because UI reads and gateway-driven writes will happen in parallel.
4. We will likely want **observation-driven UI updates** as message/session rows change.
5. We may need raw SQL and careful indexing for message search, session ordering, retry ledgers, and reconciliation.

GRDB gives us all of that without hiding SQLite.

## Why not Core Data

Core Data would add a lot of machinery we do not need:

- object graph semantics
- model tooling overhead
- more opaque migration and persistence behavior for a protocol/cache use case

For a chat client with explicit sync and replay rules, I think Core Data would be more nuisance than leverage.

## Why SQLite.swift is second place

SQLite.swift is respectable and simpler than GRDB, but it looks better for small apps than for a modular chat client that needs:

- durable migrations
- observation/reactivity
- robust multi-thread read/write patterns
- room to grow into search/reconciliation ledgers

If we were building a tiny utility app, SQLite.swift would be fine. For BeeChat v5, GRDB is the more serious choice.

---

## 4) Recommended v5 component design

## A. BeeChatPersistence
Use **GRDB**.

Owns:
- database opening and WAL config
- migrations
- tables and indexes
- repository/query layer
- cache reconciliation logic

Suggested initial schema:
- `sessions`
- `messages`
- `message_blocks` or inline JSON content field
- `attachments`
- `delivery_ledger`
- `connection_state`
- `device_credentials_metadata`

Important rule:
- local DB is a **cache + UX accelerator**, not the authoritative source of session truth

## B. BeeChatGateway
Adapt ClawChat’s `GatewayClient` design into Swift.

Owns:
- WebSocket lifecycle
- handshake state machine
- request id correlation
- event streaming
- reconnect/backoff
- device signing + token persistence handoff

Public API should look roughly like:
- `connect()`
- `disconnect()`
- `call(method:params:)`
- event stream / async sequence for gateway events
- connection state publisher

## C. BeeChatUI
SwiftUI only.

Owns:
- session list rendering
- conversation timeline
- composer
- connection/auth/pairing surfaces
- search and local cache presentation

Must not know raw WebSocket details.

## D. BeeChatApp
Thin assembly layer.

Owns:
- dependency wiring
- environment setup
- initial app lifecycle
- route selection between connect flow and main chat UI

This layer should stay boring.

---

## 5) Code adaptation targets

## Directly adaptable patterns

### From ClawChat
1. **`src/lib/gateway-client.ts`**
   - Adapt the state machine, pending-request map, timeout behavior, reconnect logic, and `hello-ok` policy capture.
2. **`src/lib/device-crypto.ts`**
   - Adapt device ID derivation, signature payload shape, and token persistence flow.
3. **`src/types/protocol.ts`**
   - Use as the first draft for Swift protocol DTOs.
4. **`src/hooks/useSessions.ts`**
   - Adapt the idea, not the code: session list comes from `sessions.list`, refreshed from gateway events.

## Do not adapt directly
- Electron store/config code as storage architecture
- React hook code as UI implementation
- SSH tunnel management unless BeeChat explicitly needs remote-over-SSH in phase 1

---

## 6) Risks and gotchas

1. **False assumption risk:** ClawChat does not solve local persistence.
2. **Handshake fragility:** tiny deviations in device signing or field presence can break pairing.
3. **Over-caching risk:** if BeeChat treats local DB as canonical, it will drift from gateway truth.
4. **Premature UI coupling:** if SwiftUI talks directly to WebSocket code, v4-style entanglement comes back.
5. **Session-key improvisation:** inventing our own routing identifiers will cause subtle bugs.

---

## 7) Proposed build plan and estimates

## Phase 1: Persistence package
**Estimate:** 1.5 to 2 days

Deliver:
- GRDB setup
- migrations
- `sessions` + `messages` schema
- repository interfaces
- seed/test fixtures

Exit criteria:
- can create/open DB
- migrate cleanly
- insert/fetch sessions/messages
- unit tests pass

## Phase 2: Gateway package
**Estimate:** 2 to 3 days

Deliver:
- native WebSocket client
- protocol DTOs
- connect challenge handshake
- device token persistence hooks
- request/response correlation
- reconnect/backoff

Exit criteria:
- connects to gateway
- receives `hello-ok`
- lists sessions
- fetches chat history

## Phase 3: Session sync bridge
**Estimate:** 1.5 to 2 days

Deliver:
- `sessions.list` import
- `chat.history` import
- event-to-database upsert path
- replay/reconciliation rules

Exit criteria:
- session list stays in sync
- timeline updates from gateway events
- reconnect does not duplicate messages

## Phase 4: SwiftUI shell
**Estimate:** 2 to 3 days

Deliver:
- session sidebar
- conversation timeline
- composer
- connection status UI
- pair/connect surfaces

Exit criteria:
- can connect, browse sessions, open conversation, send message

## Phase 5: Assembly and hardening
**Estimate:** 1.5 to 2 days

Deliver:
- app assembly
- DI cleanup
- error states
- retry states
- logging and test pass

Exit criteria:
- modular build remains clean
- no cross-layer leakage
- smoke test on clean machine/account

## Total estimate
**About 8.5 to 12 days** of focused implementation, excluding polish.

That is much healthier than another “we’ll just wire everything at once” attempt.

---

## 8) Final recommendation

### Use
- **GRDB** for local persistence
- **OpenClaw protocol v3** as the hard contract
- **ClawChat gateway-client patterns** as the main transport prior art

### Avoid
- Core Data for this project
- inventing custom session identity rules
- mixing UI, storage, and transport in the same module

### First implementation order
1. `BeeChatPersistence`
2. `BeeChatGateway`
3. sync bridge between them
4. `BeeChatUI`
5. app assembly

That order matches the v5 modular vision and keeps failure domains small.

---

## Validation checklist

- [x] ClawChat source inspected directly
- [x] OpenClaw protocol/session/device docs reviewed
- [x] Swift SQLite options compared
- [x] Build plan sequenced component-by-component
- [x] Shoulders index ready for update

---

## Attribution candidates for later implementation

When code adaptation begins, likely attribution targets are:

- `ngmaloney/clawchat` → gateway handshake/state-machine concepts and any directly ported DTO shapes
- `groue/GRDB.swift` → library dependency only, normal package attribution in documentation if needed

No BeeChat app code was written during this sprint.
