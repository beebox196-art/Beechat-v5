# BeeChat v5 — Simplified Architecture: The ClawChat Path

**Date:** 2026-04-18
**Status:** Revised approach based on working reference implementation
**Reference:** [ngmaloney/clawchat](https://github.com/ngmaloney/clawchat) — working desktop chat client for OpenClaw

---

## What We Got Wrong

We overcomplicated this. The team (including me) went down a rabbit hole of inventing a custom channel plugin architecture when **ClawChat already exists as a working reference**. It's a TypeScript/Electron desktop chat client that:

1. Connects to the OpenClaw gateway via WebSocket
2. Performs the Ed25519 device identity handshake
3. Calls `sessions.list`, `chat.history`, `chat.send`, `chat.abort`
4. Listens to `chat` events for streaming (delta/final/error)
5. **Works today.**

The "plugin vs external client" debate was a false choice. The external client path is proven — ClawChat proves it. We don't need to invent anything.

---

## The Simplified Architecture

```
┌──────────────────────────────────────┐
│     OpenClaw Gateway (Node.js)       │
│                                      │
│  WebSocket on ws://127.0.0.1:18789   │
│                                      │
│  Protocol v3:                         │
│  1. connect.challenge (nonce)        │
│  2. connect (with device signature)  │
│  3. hello-ok (scopes, deviceToken)   │
│  4. RPC: sessions.list, chat.*       │
│  5. Events: chat (delta/final/error) │
└────────────┬─────────────────────────┘
             │ WebSocket
             │
┌────────────▼─────────────────────────┐
│  BeeChat macOS app (Swift)            │
│                                      │
│  GatewayClient (Swift)               │
│  - WebSocket connection               │
│  - Ed25519 device identity            │
│  - Handshake with device signature    │
│  - RPC call() method                  │
│  - Event listener for "chat" events   │
│                                      │
│  SyncBridge (Swift)                  │
│  - sessionsList(), chatHistory()     │
│  - chatSend(), chatAbort()           │
│  - Streams delta/final/error events  │
│                                      │
│  Persistence (Swift/GRDB)            │
│  - Local SQLite cache                 │
│  - Message/Session/Attachment models │
│                                      │
│  SwiftUI Views                       │
│  - Chat list, messages, composer     │
└──────────────────────────────────────┘
```

**No plugin. No HTTP routes. No SSE. No gateway methods.** Just a native macOS app that connects to the gateway WebSocket exactly like ClawChat does — but written in Swift instead of TypeScript.

---

## What ClawChat Proves Works

From the source code at `/tmp/clawchat/src/`:

### Connection Flow (gateway-client.ts)
```
1. WebSocket connect with token as query param: ws://host:port?token=XXX
2. Receive connect.challenge event with nonce
3. Build Ed25519 device signature:
   - Payload: v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
   - Sign with device private key
4. Send connect request with device identity + signature
5. Receive hello-ok with scopes, deviceToken
6. Store deviceToken for reconnection
7. Connected — can now call RPC methods and receive events
```

### RPC Calls (useSessions.ts, useChat.ts)
```
sessions.list → { sessions: [...] }
chat.history  → { messages: [...] }
chat.send     → { runId: "..." }
chat.abort    → { ok: true, aborted: true }
```

### Event Streaming (useChat.ts)
```
Subscribe to "chat" event:
  - state: "delta"  → streaming text, update in place
  - state: "final"  → complete message, stop streaming
  - state: "error"  → error message, stop streaming
```

### Device Identity (device-crypto-ed25519.ts)
```
- Generate Ed25519 keypair (@noble/ed25519)
- Device ID = SHA-256(publicKey)
- Store in localStorage (for Electron)
- Sign challenge with private key
- v2 pipe-delimited payload format
```

### Reconnection
```
- Exponential backoff (1s → 30s, max 10 retries)
- On reconnect: reuse deviceToken from previous hello-ok
- Fatal codes (1008, 4xxx): stop retrying
```

---

## What We Already Have That's Correct

Our existing BeeChat v5 Swift code was **already on the right track**. The components we built match the ClawChat approach:

| BeeChat Component | ClawChat Equivalent | Status |
|---|---|---|
| `GatewayClient.swift` | `gateway-client.ts` | ✅ Same design, needs Ed25519 handshake |
| `WebSocketTransport.swift` | WebSocket in `gateway-client.ts` | ✅ Same |
| `ConnectParams.swift` | `ConnectParams` in `protocol.ts` | ✅ Same fields |
| `RPCClient.swift` | `client.call()` in `gateway-client.ts` | ✅ Same methods |
| `SyncBridge.swift` | `useChat.ts` + `useSessions.ts` | ✅ Same orchestration |
| `EventRouter.swift` | Event listeners in `useChat.ts` | ✅ Same routing |
| `BeeChatPersistence` | localStorage in ClawChat | ✅ Same (we use GRDB, better) |
| `DeviceIdentity.swift` | `device-crypto-ed25519.ts` | ⚠️ Need to implement signing |

---

## What We Need To Do

### 1. Implement Ed25519 Device Identity in Swift

ClawChat uses `@noble/ed25519`. We use `CryptoKit` (Apple's built-in).

The signing flow from ClawChat (`device-crypto-ed25519.ts`):
```typescript
const payload = [
  'v2', deviceId, clientId, clientMode, role,
  scopes.join(','), String(signedAtMs), token || '', nonce
].join('|')
const signature = await ed25519.signAsync(payload, privateKey)
```

Swift equivalent:
```swift
import CryptoKit

// Generate keypair
let privateKey = Curve25519.KeyAgreement.PrivateKey()
let publicKey = privateKey.publicKey

// Device ID = SHA-256 of public key raw representation
let deviceId = SHA256.hash(data: publicKey.rawRepresentation).map { ... }.joined()

// Sign challenge
let payload = ["v2", deviceId, clientId, clientMode, role, scopesStr, String(signedAtMs), token ?? "", nonce].joined(separator: "|")
let signature = try Ed25519.sign(payload.data(using: .utf8)!, privateKey: signingKey)
```

**Key detail from ClawChat:** The signature payload format is `v2` (not `v3` as in our earlier research). ClawChat uses `v2`. We should match the working code.

### 2. Update GatewayClient Handshake

Our `GatewayClient.swift` already has the connection flow. We need to add:
- Ed25519 key generation and persistence (Keychain)
- Build device signature during `_doHandshake()`
- Include `device` field in connect params
- Handle `hello-ok.auth.deviceToken` and persist it
- Use deviceToken on reconnection

Direct port from ClawChat's `_doHandshake()`.

### 3. Verify RPC Methods Match

ClawChat uses:
- `sessions.list` — ✅ already in our `RPCClient`
- `chat.history` — ✅ already in our `RPCClient`
- `chat.send` — ✅ already in our `RPCClient`
- `chat.abort` — ✅ already in our `RPCClient`
- Event: `chat` with `state: delta|final|error` — ✅ already in our `EventRouter`

### 4. Test With Integration Test

Our existing integration test at `Sources/BeeChatIntegrationTest/main.swift` already:
- Connects WebSocket
- Performs handshake
- Calls `sessions.list`, `chat.history`

We just need to add the Ed25519 signature to the handshake and verify it gets operator scopes.

---

## What We DON'T Need

| Previously Planned | Why We Don't Need It |
|---|---|
| BeeChat channel plugin (Node.js) | ClawChat proves external WebSocket client works |
| HTTP routes (`/beechat/api/*`) | Gateway WebSocket provides everything |
| SSE endpoint | WebSocket events provide streaming |
| Gateway methods (`beechat.*`) | Standard gateway RPC works |
| `registerHttpRoute` / `registerGatewayMethod` | Not needed for external clients |
| `createChatChannelPlugin` | Not needed — we're an external client, not a channel |
| `PluginRuntime` access | Not needed — we use gateway RPC |
| API key auth for localhost | Gateway token + Ed25519 is the auth |
| Custom session key grammar | BeeChat uses existing sessions, doesn't create its own |

---

## Revised Implementation Plan

### Phase 1: Ed25519 Device Identity (1-2 days)
- [ ] Create `DeviceIdentityManager.swift` using CryptoKit
- [ ] Ed25519 key generation, Keychain persistence
- [ ] Challenge signing with v2 pipe-delimited payload
- [ ] Device ID derivation (SHA-256 of public key)
- [ ] Port directly from ClawChat's `device-crypto-ed25519.ts`

### Phase 2: GatewayClient Handshake (1-2 days)
- [ ] Update `performHandshake()` to include device signature
- [ ] Handle `hello-ok.auth.deviceToken` and persist
- [ ] Use deviceToken on reconnection
- [ ] Port directly from ClawChat's `_doHandshake()`

### Phase 3: Integration Test (1 day)
- [ ] Update integration test with Ed25519 handshake
- [ ] Verify `sessions.list` returns data (operator scopes granted)
- [ ] Verify `chat.history` works
- [ ] Verify `chat.send` works
- [ ] Verify streaming events (delta/final/error)

### Phase 4: Full App (ongoing)
- [ ] Wire GatewayClient through SyncBridge
- [ ] Verify SwiftUI views render correctly
- [ ] Polish, media support, notifications

**Total estimate: 3-5 days to working prototype.**

---

## Why This Is Simpler and Guaranteed

1. **Working reference code** — ClawChat is live and working. We port it, we get the same result.
2. **No invented architecture** — We follow the exact path that already works.
3. **Our existing Swift code is 90% correct** — Components 1-3 just need the Ed25519 handshake added.
4. **No plugin to maintain** — The gateway already supports external WebSocket clients.
5. **All our earlier components survive** — Persistence, SyncBridge, EventRouter, RPCClient — all stay.
6. **The compliance audit becomes trivial** — Component 2 just needs Ed25519 added (which was always the plan from the research doc).

---

## Team Consensus Note

The previous "channel plugin" approach was well-intentioned but overcomplicated. The team correctly identified issues (WebSocket upgrade not in SDK, inbound injection undefined, outbound duplication) — all of which were symptoms of trying to invent a new architecture. The simpler path is: **be an external WebSocket client like ClawChat, just in Swift.**

This is the "stop inventing, start copying" moment. ClawChat did it. We do the same thing in Swift.