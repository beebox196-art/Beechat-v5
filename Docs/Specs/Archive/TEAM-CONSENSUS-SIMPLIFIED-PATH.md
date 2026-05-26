# BeeChat v5 — Team Consensus: Simplified Path

**Date:** 2026-04-18
**Reviewers:** Kieran (Backend), Q (Architecture), Bee (Coordinator)
**Reference:** [ngmaloney/clawchat](https://github.com/ngmaloney/clawchat) — working desktop chat client

---

## Consensus: GO ✅

All three reviewers agree: the simplified external WebSocket client path is correct. ClawChat proves it works. No plugin needed.

---

## Three Hard Requirements (Must Fix Before Integration Testing)

These are showstoppers. Without them, nothing works.

### 🔴 R1: Wrong Key Type — P-256 ECDSA → Ed25519

**Found by:** Q (primary), Kieran (confirms)

Our `DeviceCrypto.swift` uses `kSecAttrKeyTypeECSECPrimeRandom` (P-256 ECDSA) with `.ecdsaSignatureMessageX962SHA256`. The gateway expects **Ed25519** signatures. Our signatures will be **rejected 100% of the time**.

**Fix:**
- `kSecAttrKeyTypeECSECPrimeRandom` → `kSecAttrKeyTypeEd25519` (or CryptoKit `Curve25519.Signing`)
- `.ecdsaSignatureMessageX962SHA256` → `.signMessageEd25519`
- Add base64url encoding for public key export (current code uses standard base64)
- Add base64url encoding for signature output

**Kieran verified:** CryptoKit's `Curve25519.Signing` on this Mac produces 32-byte public keys and 64-byte signatures — byte-identical to `@noble/ed25519`.

### 🔴 R2: Wrong Event Format — "agent" → "chat"

**Found by:** Q (critical finding)

Our `EventRouter.swift` listens to `"agent"` events with `data.phase` / `data.text`. ClawChat uses `"chat"` events with `state` / `message`. These are **completely different payloads**:

| Aspect | "chat" event (ClawChat) | "agent" event (current BeeChat) |
|--------|------------------------|-------------------------------|
| State field | `state` (top-level) | `data.phase` (nested) |
| Message | `message` (ChatMessage with ContentBlock[]) | `data.text` (plain string) |
| Error | `errorMessage` (top-level) | Not handled |

**Fix:** Switch EventRouter to listen for `"chat"` events. Rewrite event parsing to match ClawChat's structure.

### 🔴 R3: Wrong Scopes in Handshake

**Found by:** Kieran

`GatewayClient.swift` requests scopes `["user.read", "user.write"]`. Should be `["operator.read", "operator.write"]` at minimum. This is why every RPC call fails with "missing scope: operator.read."

**Fix:** Change scopes to `["operator.read", "operator.write", "operator.approvals", "operator.pairing"]` to match ClawChat.

---

## Two Critical Design Points (Not Bugs, But Must Get Right)

### 🟡 D1: Two-Phase Auth Flow

**Found by:** Both Kieran and Q independently

ClawChat does NOT always send device identity. The flow is:

1. **First connection:** Send `auth: { token }` only. NO device field. Receive `hello-ok` with `deviceToken`.
2. **Subsequent connections:** Send `auth: { token, deviceToken }` AND `device: { id, publicKey, signature, signedAt, nonce }`.

This is because **sending an unsolicited device field to a token-auth gateway causes rejection** ("not-paired"). The simplified spec doesn't document this at all.

**Fix:** Add conditional device identity in `performHandshake()` — only include `device` when we have a stored `deviceToken`.

### 🟡 D2: v3 Signature Payload (Not v2)

**Found by:** Both Kieran and Q independently

- ClawChat uses **v2** (9 fields)
- The gateway's own Control UI uses **v3** (11 fields: adds `platform` + `deviceFamily`)
- The gateway **accepts both** (tries v3 first, falls back to v2)

**Consensus:** Use **v3**. It's the gateway's current preferred format. v2 works today but is the backwards-compatible fallback. Adding two fields is trivial and future-proofs us.

v3 format: `v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily`

---

## Three Should-Fix Improvements

### 🟢 A1: Stream Stall Detection
ClawChat has a 90-second timeout — if no delta arrives, mark the stream as errored. BeeChat has nothing. Without it, the UI can hang forever.

### 🟢 A2: Connection Loss During Streaming
ClawChat watches for `status !== 'connected' && isStreaming` and immediately clears stuck state. BeeChat doesn't handle this.

### 🟢 A3: Ed25519 Private Key Backup
**The single biggest risk (both reviewers flag this):** If the Ed25519 private key is lost (Keychain corruption, OS update), the gateway no longer recognises us. Need to store `rawRepresentation` as a backup Keychain entry so we can reimport.

---

## What Both Reviewers Explicitly Rejected

| Proposal | Reason |
|----------|--------|
| Channel backend support | Only for in-process plugins. BeeChat is external. Hard-code 'openclaw'. |
| Plugin architecture | Rejected. External client is proven by ClawChat. |
| v2 signature format | Works but v3 is current. Use v3. |
| Multiple backend modes | YAGNI. One path, tested, working. |

---

## Implementation Plan (Revised)

### Phase 1: Fix the Auth Layer (1-2 days)
- [ ] Rewrite `DeviceCrypto.swift`: P-256 → Ed25519, v2 → v3, base64 → base64url
- [ ] Add two-phase auth flow to `GatewayClient.swift` performHandshake()
- [ ] Fix scopes: `user.read/write` → `operator.read/write/approvals/pairing`
- [ ] Add base64url encoding utilities

### Phase 2: Fix Event Handling (1 day)
- [ ] Switch `EventRouter.swift` from "agent" to "chat" events
- [ ] Rewrite event parsing: `state`/`message` instead of `data.phase`/`data.text`
- [ ] Change streaming from append-based to replacement-based (gateway sends accumulated text)
- [ ] Add stream stall detection (90s timeout)
- [ ] Add connection-loss-during-streaming handling

### Phase 3: Integration Test (1 day)
- [ ] Update integration test with Ed25519 handshake
- [ ] Verify operator scopes granted
- [ ] Verify `sessions.list` returns data
- [ ] Verify `chat.history`, `chat.send`, `chat.abort` work
- [ ] Verify `"chat"` events stream correctly

### Phase 4: Full App (ongoing)
- [ ] Wire through SyncBridge
- [ ] SwiftUI views
- [ ] Polish

**Total: 3-5 days to working prototype.**

---

## Team Sign-Off

| Reviewer | Verdict | Key Concern |
|----------|---------|-------------|
| Kieran | ✅ GO | Fix key type, two-phase auth, v3 payload. Don't support channel backend. |
| Q | ✅ GO | Fix key type, switch to "chat" events, use v3 payload. Ed25519 key backup is critical. |
| Bee | ✅ GO | Consensus is clear. Three showstoppers, two design points, three improvements. Let's build. |