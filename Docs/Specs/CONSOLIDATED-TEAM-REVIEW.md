# BeeChat v5 — Consolidated Team Review

**Date:** 2026-04-17
**Reviewers:** Kieran (Backend/Systems), Q (Architecture), Bee (Coordinator)
**Documents:** `BECHAT-CHANNEL-PLUGIN-SPEC.md` + `COMPONENT-COMPLIANCE-AUDIT.md`

---

## Critical Issues (Must Fix Before Implementation)

### 🔴 1. `registerHttpRoute` Does NOT Support WebSocket Upgrades

**Raised by:** Kieran (primary), Q (secondary)

The spec proposes `api.registerHttpRoute({ path: "/beechat/ws", upgrade: true, ... })`. This **does not exist** in the SDK. The handler signature is `(req: IncomingMessage, res: ServerResponse)` — no socket, no upgrade field. This is a showstopper for the real-time event design as written.

**Team consensus:** Drop the WebSocket endpoint. Use **SSE (Server-Sent Events)** instead.
- SSE works with `registerHttpRoute` — just hold the response open and stream events
- It's unidirectional (server → client), which is exactly what we need
- The native app already uses HTTP POST for sending
- SSE is the pragmatic choice that actually works with the SDK we have

**Action:** Rewrite spec Section 4.2 to use SSE. Add `/beechat/api/events` as an SSE endpoint.

---

### 🔴 2. `injectInboundMessage` Doesn't Exist — The Inbound Path Is Undefined

**Raised by:** Q (critical finding)

The spec says the HTTP route handler calls `injectInboundMessage(runtime, sessionKey, text)` but this method **does not exist** on `PluginRuntime`. The runtime provides:
- `runtime.agent.runEmbeddedAgent` — runs an agent directly
- `runtime.subagent.run` — spawns a subagent

But neither of these is the standard channel plugin inbound message path. The spec leaves the most important part — how a message actually enters the agent processing pipeline — as a handwave.

**Team consensus:** This must be resolved before Phase 2. We need to trace how existing channel plugins (e.g. Telegram) inject inbound messages. The likely correct path is through the channel plugin framework's built-in inbound handling, not a manual runtime call. The HTTP route triggers the channel's inbound flow, which the framework routes automatically.

**Action:** Research the actual inbound message path in existing channel plugins before writing Phase 2 code. Update spec with the real mechanism.

---

### 🔴 3. The Outbound Adapter vs Event Stream Duplication Problem

**Raised by:** Q (primary), Kieran (secondary)

The spec has TWO paths for agent → native app delivery:
1. **Outbound adapter** (`sendText` / `sendMedia`) — fires on completed messages
2. **Event stream** (SSE) — carries both streaming deltas AND final messages

This creates duplicates. When the agent finishes a response, the native app receives it from BOTH paths. For streaming, only the event stream has the delta phases. For final messages, both fire.

**Team consensus:** The native app should use **ONLY the event stream** for rendering. The outbound adapter exists to satisfy the channel plugin contract (it's how OpenClaw confirms delivery), but it should push to the same internal event bus, not to a separate channel. Dedup at the source, not at the client.

**Action:** Redesign outbound adapter as a thin bridge that publishes to the event bus. The SSE stream is the single source of truth for the native app. Add this to spec.

---

## Significant Issues (Must Address in Spec)

### 🟡 4. Channel Plugin vs Private Transport — Conflated Concerns

**Raised by:** Kieran (primary), Q (agrees)

The spec mixes two different things:
1. **The channel plugin surface** — OpenClaw's integration contract (session routing, security, message tool schema, outbound adapter)
2. **The private HTTP/SSE API** — transport between the plugin and the native app (a plugin-internal implementation detail)

These should be separated in the spec. The channel plugin part defines how OpenClaw sees BeeChat. The HTTP/SSE part is how the native app talks to the plugin. They have different lifecycles, different error modes, and different security models.

**Action:** Split spec Sections 4 and 5 into "Channel Plugin Contract" and "Private Native App Transport."

---

### 🟡 5. Security: `auth: "plugin"` Is Not Enough

**Raised by:** Kieran

`auth: "plugin"` means "accessible to any authenticated plugin," NOT "no auth needed." Any local process that can reach port 18789 with a valid gateway token can call BeeChat's API. On localhost, this means other apps, browser scripts, etc.

**Action:** Add a shared secret (API key) in plugin config. The native app must present it on every request. Default: auto-generated on plugin startup, shared via Keychain or config file. This is defense in depth — not paranoia.

---

### 🟡 6. Missing Routes

**Raised by:** Kieran

- `POST /beechat/api/abort` — Critical for stopping runaway generation. The Swift `RPCClient` has `chatAbort()` but the spec omits it.
- `GET /beechat/api/status` — Plugin health/liveness. The native app needs to know the plugin is alive.
- `GET /beechat/api/sessions/:key/messages` — RESTful path for message history (instead of query params).
- Media upload/download routes — Completely absent from the spec. Phase 4 mentions "media support" with zero design.

**Action:** Add abort and status routes to Phase 2. Add media route design to Phase 4 spec.

---

### 🟡 7. Session Key Grammar Undefined

**Raised by:** Q

Every session key in OpenClaw encodes a channel peer (e.g. `agent:main:telegram:group:12345`). The spec never defines what BeeChat's session keys look like. Is it `agent:main:beechat:direct:default`? `agent:main:beechat:local`? This affects session routing, transcript search, and the `message` tool's ability to target BeeChat.

**Action:** Define BeeChat session key format explicitly. Recommendation: `agent:main:beechat:direct:local` for direct chats.

---

### 🟡 8. Gateway Restart / Reconnection Not Designed

**Raised by:** Kieran (primary), Q (agrees)

When the gateway restarts:
- The plugin reloads (it's in-process)
- The HTTP/SSE endpoints change (new gateway process)
- The native app's SSE connection drops
- Any in-flight requests fail
- The native app doesn't know when the gateway is back

There's no reconnection strategy, no event replay, no way for the native app to know what it missed.

**Action:** Add reconnection + event replay to spec. At minimum: SSE sends last event ID, native app reconnects with `Last-Event-ID` header, plugin replays missed events from buffer. Add `/beechat/api/status` with gateway uptime for native app health checks.

---

## Improvements (Should Add)

### 🟢 9. Component Audit — Component 3 Has Hidden Coupling

**Raised by:** Q (primary), Bee (confirms)

The audit says "swap `RPCClientProtocol` implementation, done." But `SyncBridge.swift` directly references `config.gatewayClient` for:
- `config.gatewayClient.connect()` / `disconnect()`
- `await config.gatewayClient.eventStream()`
- `await config.gatewayClient.updateOnStatusChange { ... }`

These are NOT behind `RPCClientProtocol`. Replacing the RPC implementation alone doesn't fix `SyncBridge` — it still depends on a `GatewayClient` for events and connection state.

**Action:** The refactored `SyncBridgeConfiguration` must abstract the event stream AND connection state, not just the RPC calls. Create a `TransportProvider` protocol that covers events, connection state, and RPC.

---

### 🟢 10. Outbound Delivery Guarantee — Buffer and Replay

**Raised by:** Q

If the native app isn't connected when the agent sends a response, the outbound adapter fires into the void. For external platforms, this means "retry later." For BeeChat, it means "the user never sees the response."

**Action:** The plugin must buffer recent events (last N events, or events since last N minutes). When the native app's SSE connection reconnects, replay buffered events. This is essential for reliability.

---

### 🟢 11. Single-User Security Assumption — Document It

**Raised by:** Q

`resolvePolicy: () => "open"` works because there's one user (Adam). But "open" means no restrictions at all. If we ever add multi-user BeeChat, the security model breaks. This isn't a problem today, but it should be an explicit documented assumption, not an accidental consequence.

**Action:** Add to spec: "Security model assumes single authorized user. Multi-user BeeChat requires re-architecting the security adapter."

---

### 🟢 12. Error Handling Standards

**Raised by:** Kieran

The spec shows routes with zero error handling. No standard error response format, no HTTP status codes, no mention of what happens when things fail.

**Action:** Define standard error response shape:
```json
{ "error": { "code": "SESSION_NOT_FOUND", "message": "..." } }
```
With proper HTTP status codes (400, 404, 500). Add to spec Section 4.

---

### 🟢 13. API Versioning

**Raised by:** Kieran (implied), Q (explicit)

The spec doesn't version the HTTP API. When OpenClaw updates, the plugin API may change. The native app needs to handle this gracefully.

**Action:** Add `/beechat/api/v1/` prefix or include API version in `/beechat/api/status` response. Start with v1 from day one — it's cheap now and expensive later.

---

## Bee's Coordinator Assessment

Both reviews converge on the same three critical issues:
1. **WebSocket upgrade doesn't exist** in the SDK → use SSE
2. **Inbound message injection is undefined** → must research before Phase 2
3. **Outbound/event stream duplication** → single source of truth via event stream

Kieran focuses more on the operational surface (auth, error handling, rate limiting, reconnection, API versioning). Q focuses more on the conceptual surface (is "channel plugin" the right abstraction, data flow completeness, state management, delivery guarantees).

They agree on the big picture: the plugin approach is right, but the spec has gaps that would block implementation. The most dangerous gap is #2 — we literally don't know how to inject a message into the agent pipeline through the plugin framework. Everything else is design refinement; this one is a missing piece of the bridge.

**My recommendation:** Before writing any code, resolve Issue #2 by tracing the Telegram plugin's inbound message path. Once we know how messages flow in, everything else follows.

---

## Summary: What Changes in the Spec

| Section | Change | Priority |
|---------|--------|----------|
| 4.2 WebSocket endpoint | Replace with SSE endpoint `/beechat/api/events` | 🔴 Critical |
| 4.1 Routes | Add `/abort`, `/status`, `/sessions/:key/messages` | 🟡 High |
| 4.1 `injectInboundMessage` | Replace with actual channel plugin inbound mechanism (TBD) | 🔴 Critical |
| 5 Gateway Methods | Keep but note they're supplementary to HTTP API | 🟢 Low |
| 6 Outbound adapter | Redesign as event bus bridge, not separate delivery | 🔴 Critical |
| 4.x Security | Add API key auth, not just `auth: "plugin"` | 🟡 High |
| 4.x Error handling | Add standard error response format | 🟢 Medium |
| 3.x Session key grammar | Define `agent:main:beechat:direct:local` | 🟡 High |
| 3.x Reconnection | Add SSE reconnection + event replay buffer | 🟡 High |
| New section | Separate "Channel Plugin Contract" from "Private Transport" | 🟡 High |
| Compliance audit §3 | Add hidden `SyncBridge` coupling to `GatewayClient` | 🟢 Medium |
| Compliance audit §1 | Note: may need schema changes for plugin API field names | 🟢 Medium |
| API versioning | Add `/v1/` prefix or version in status endpoint | 🟢 Medium |

**3 critical blockers, 5 significant issues, 5 improvements.** Not bad for a first draft — the architecture is sound, the gaps are findable and fixable.