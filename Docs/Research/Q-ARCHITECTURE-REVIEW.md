# Q's Architecture Review: Simplified ClawChat Path

**Reviewer:** Q (Senior Architect)  
**Date:** 2026-04-18  
**Purpose:** Critical go/no-go decision on adopting the "just be an external WebSocket client like ClawChat" approach

---

## 1. Is the Simplified Path Correct?

**Verdict: Directionally correct, but the spec significantly glosses over the Ed25519 complexity.**

The simplified spec says "just be an external WebSocket client like ClawChat." This is the right *direction* — ClawChat proves external WebSocket clients work. But the spec's framing makes it sound like a simple port when it's actually a deep cryptographic handshake with non-trivial failure modes.

### What the spec gets right:
- No plugin needed. ClawChat proves the external client path works.
- The component mapping (GatewayClient ↔ gateway-client.ts, RPCClient ↔ client.call(), etc.) is correct.
- Our existing Swift code structure is genuinely close to what's needed.

### What the spec glosses over:

**a) ClawChat doesn't always send Ed25519.** The `_doHandshake()` method in `gateway-client.ts` has this critical conditional:

```typescript
// Build device identity only when we already hold a deviceToken
// (i.e. the device was previously paired). Sending an unsolicited device
// field to a token-auth gateway causes rejection ("not-paired").
let device: DeviceIdentity | undefined
if (this.deviceToken && this.challengeNonce) {
  // ... build device identity
}
```

**ClawChat only sends the device signature when it already has a `deviceToken`.** On first connection, it connects WITHOUT device identity, receives a deviceToken in `hello-ok`, and only on *subsequent* connections does it include the device field. This is a two-phase auth flow, and the simplified spec doesn't document it at all.

**b) First connection = limited scopes.** On first connect (no deviceToken, no device signature), ClawChat sends:
```typescript
auth: { token: this.token }
// No device field at all
```
This means the first connection likely gets limited scopes. The deviceToken from `hello-ok` enables elevated scopes on the *next* connection. The spec doesn't mention this bootstrap chicken-and-egg problem.

**c) The spec says our DeviceCrypto "needs to implement signing" as if it's a checkbox item.** It's actually the hardest part — wrong key type, wrong signature algorithm, or wrong payload format = instant rejection with no useful error message.

---

## 2. Data Flow Comparison: ClawChat useChat.ts vs SyncBridge.swift EventRouter

**Critical mismatch found. They are NOT handling the same events.**

### ClawChat (useChat.ts):
- Subscribes to the **`"chat"` event**
- Receives payloads with `state: "delta" | "final" | "error"`
- Delta: extracts text from `ev.message` (which is a `ChatMessage` — either a string or array of `ContentBlock[]`)
- Final: same extraction, marks streaming complete
- Error: reads `ev.errorMessage`

The event payload structure (from `protocol.ts`):
```typescript
ChatDeltaPayload:  { runId, sessionKey, seq, state: 'delta', message: ChatMessage }
ChatFinalPayload:  { runId, sessionKey, seq, state: 'final', message: ChatMessage }
ChatErrorPayload:   { runId, sessionKey, seq, state: 'error', errorMessage: string }
```

### BeeChat (EventRouter.swift):
- Subscribes to the **`"agent"` event**
- Receives payloads with `data.phase: "delta" | "final" | "error"`
- Extracts text from `event.data.text` (a plain string)
- Reads `event.data.itemId`, `event.runId`, `event.seq`, `event.ts`

### The Mismatch:

| Aspect | ClawChat ("chat" event) | BeeChat ("agent" event) |
|--------|------------------------|------------------------|
| Event name | `chat` | `agent` |
| State field | `state` (top-level) | `data.phase` (nested) |
| Message content | `message` (ChatMessage with ContentBlock[]) | `data.text` (plain string) |
| Error message | `errorMessage` (top-level) | Not handled specifically |
| Run ID | `runId` (top-level) | `runId` (top-level) |
| Sequence | `seq` (top-level) | `seq` (top-level) |

**These are two completely different event formats.** The gateway emits BOTH `"chat"` and `"agent"` events. ClawChat uses `"chat"` (the higher-level, client-friendly format). BeeChat's EventRouter is wired to `"agent"` (the lower-level, internal format).

### Recommendation:
**Switch EventRouter to listen for `"chat"` events, not `"agent"` events.** The `"chat"` event is designed for external clients — it gives you the assembled message text directly. The `"agent"` event is the internal stream with raw tool calls, intermediate states, etc. Using `"agent"` means we'd need to reconstruct the message ourselves, which is both harder and more fragile.

### Secondary issues in BeeChat's event handling:

1. **Delta accumulation:** ClawChat replaces the streaming message text on each delta (the gateway sends the full accumulated text). BeeChat's `processAgentEvent` *appends* text: `streamingBuffer[sessionKey, default: ""] += text`. If the `"agent"` event sends accumulated text (like `"chat"` does), this would double the content. If it sends incremental chunks, appending is correct. This needs verification against actual gateway behavior.

2. **Final event handling:** ClawChat extracts the complete message from `ev.message` in final events. BeeChat reads `event.data.text` — if this is null/empty in a final event (because the agent event format differs), we'd lose the final message.

3. **Error handling:** ClawChat has explicit `errorMessage` extraction. BeeChat just clears the buffer and notifies — no error message is surfaced to the user.

---

## 3. State Management Comparison

### Reconnection:

| Aspect | ClawChat | BeeChat |
|--------|----------|---------|
| Backoff | Exponential: 1s → 30s, max 10 retries | Exponential: 1s → 30s, max 10 retries |
| Fatal codes | 1008, 4xxx → stop retrying | 1008, 4000-4999 → stop retrying |
| Reconnect with deviceToken | ✅ Stores and reuses | ✅ Has TokenStore for this |
| Stream stall detection | ✅ 90s timeout, marks as errored | ❌ Not implemented |
| Connection loss during streaming | ✅ Immediately clears stuck state | ❌ Not handled |

**Missing in BeeChat:**
- **Stream stall detection.** ClawChat has a 90-second stall timer that fires if no delta arrives. BeeChat has nothing — if the gateway stops sending deltas without a final/error, the UI hangs forever showing a streaming indicator.
- **Connection loss during streaming.** ClawChat watches for `status !== 'connected' && isStreaming` and immediately clears the stuck state. BeeChat has no equivalent.

### Device Token Persistence:

| Aspect | ClawChat | BeeChat |
|--------|----------|---------|
| Storage | localStorage (JSON) | Keychain (proper secure storage) ✅ |
| Private key storage | localStorage (base64url) ⚠️ | Keychain (SecKey, hardware-backed) ✅ |
| Token reuse | ✅ | ✅ (but not wired into handshake) |
| Scope persistence | ❌ Not persisted | ❌ Not persisted |

**Keychain > localStorage for security.** BeeChat's Keychain storage is actually superior. But:

**Gotcha #1: Private key export.** ClawChat stores the private key as base64url in localStorage. BeeChat's `DeviceCrypto` uses `SecKeyCreateRandomKey` with `kSecAttrIsPermanent: true` which stores in Keychain — but the key is a P-256 EC key (see below), and it can only be accessed via `SecKey` operations, not exported as raw bytes. This is fine for signing, but it means we can't do what ClawChat does (export → reimport). The key is tied to the Keychain entry.

**Gotcha #2: Keychain across app reinstalls.** If BeeChat is deleted and reinstalled, the Keychain entries survive (on macOS, if the app uses a shared keychain group). But the Ed25519 key won't match the deviceId the gateway remembers, so re-pairing would be needed. ClawChat has the same problem (localStorage is cleared on uninstall in Electron).

---

## 4. The v2 vs v3 Signature Format — CRITICAL FINDING

**The gateway's own Control UI client (`client-DkWAat_P.js`) uses `v3`. ClawChat uses `v2`.**

### ClawChat's actual format (device-crypto-ed25519.ts):
```typescript
['v2', deviceId, clientId, clientMode, role, scopesStr, String(signedAtMs), tokenStr, nonce].join('|')
// 9 fields
```

### Gateway's Control UI format (from research doc, client-DkWAat_P.js):
```typescript
['v3', deviceId, clientId, clientMode, role, scopes.join(','), String(signedAtMs), token ?? '', nonce, platform, deviceFamily].join('|')
// 11 fields (adds platform + deviceFamily)
```

### BeeChat's current DeviceCrypto.swift:
```swift
"v2|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopes.joined(separator: ","))|\(signedAtMs)|\(token ?? "")|\(nonce)"
// 9 fields — matches ClawChat
```

**So which one does the gateway accept?**

Both. The gateway must accept v2 because ClawChat works. But the gateway's own client has moved to v3 (adding `platform` and `deviceFamily`). This suggests:

1. **v2 is the backwards-compatible format** that the gateway still accepts.
2. **v3 is the current preferred format** with additional fields.
3. **ClawChat works with v2** because the gateway accepts both.

**Risk:** If the gateway deprecates v2 in a future version, ClawChat (and BeeChat if we use v2) will break. Using v3 is more future-proof.

**Recommendation:** Use v3 format to match the gateway's own client, not v2. Add `platform` (e.g., "macos") and `deviceFamily` (e.g., "desktop" or empty string) fields. This is the safest choice — it matches the gateway's current preferred format and is trivially different from v2.

**The simplified spec's claim that "v2" is correct because "ClawChat uses v2" is misleading.** ClawChat works despite using v2, not because v2 is the right choice. The gateway's own client has already moved to v3.

---

## 5. Swift/CryptoKit Feasibility

**CRITICAL: Our current DeviceCrypto.swift uses the WRONG key type and algorithm.**

### Current BeeChat code (DeviceCrypto.swift):
- **Key type:** `kSecAttrKeyTypeECSECPrimeRandom` → **EC P-256**
- **Algorithm:** `.ecdsaSignatureMessageX962SHA256` → **ECDSA with P-256**
- **This is NOT Ed25519.**

### ClawChat code (device-crypto-ed25519.ts):
- **Key type:** `@noble/ed25519` → **Ed25519 (Curve25519)**
- **Algorithm:** `ed25519.signAsync(message, privateKey)` → **Ed25519 signing**

### These are completely different cryptographic schemes:
| | ECDSA P-256 (current BeeChat) | Ed25519 (required) |
|--|--|--|
| Curve | NIST P-256 | Curve25519 |
| Signature | ECDSA (randomized) | EdDSA (deterministic) |
| Key format | X9.63/SEC1 (65 bytes: 04 + x + y) | Raw (32 bytes public, 64 bytes signature) |
| Same signature twice? | ❌ Different (randomized k) | ✅ Same (deterministic) |

**The gateway verifies Ed25519 signatures. Our current code signs with ECDSA P-256. The signature will be rejected 100% of the time.**

### Swift Ed25519 Implementation:

**Option A: CryptoKit `Curve25519.Signing`**
```swift
import CryptoKit

let privateKey = Curve25519.Signing.PrivateKey()
let publicKey = privateKey.publicKey
let signature = try privateKey.signature(for: data)
```

**This SHOULD work** — `Curve25519.Signing` in CryptoKit implements Ed25519 (actually EdDSA over Curve25519, which is Ed25519). Apple's implementation follows RFC 8032.

**Option B: Security framework `SecKey` with `kSecAttrKeyTypeEd25519`**
```swift
let attributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeEd25519,
    kSecAttrKeySizeInBits as String: 256,
    // ...
]
let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)
let signature = SecKeyCreateSignature(privateKey, .signMessageEd25519, data as CFData, &error)
```

**This also works** on macOS 10.15+ and iOS 16+.

### Known incompatibilities between Ed25519 implementations:

1. **Key representation:** `@noble/ed25519` uses raw 32-byte private keys. CryptoKit's `Curve25519.Signing.PrivateKey` stores a 64-byte "extended" key (private + public). But when signing the same message with the same private key bytes, the signatures are byte-identical — Ed25519 is deterministic.

2. **Public key export format:** `@noble/ed25519` exports raw 32-byte public keys. CryptoKit's `publicKey.rawRepresentation` gives raw 32-byte public key. These should be identical for the same key material.

3. **Signature output:** Both produce 64-byte signatures. Both follow RFC 8032. Should be byte-identical for the same input.

**The critical path:** We must ensure:
- Private key is stored in a format that can be reimported
- Public key export is raw 32 bytes (not X9.63/SEC1 which is what P-256 gives)
- Signature is the raw 64-byte Ed25519 signature, not a DER-encoded ECDSA signature

**Our current code exports the public key using `SecKeyCopyExternalRepresentation`** which for P-256 gives 65 bytes (04 prefix + 32 + 32). For Ed25519, `SecKeyCopyExternalRepresentation` gives 32 raw bytes. So the *code structure* is fine — we just need to change the key type.

### Concrete fix:
```swift
// REPLACE: kSecAttrKeyTypeECSECPrimeRandom → kSecAttrKeyTypeEd25519
// REPLACE: .ecdsaSignatureMessageX962SHA256 → .signMessageEd25519
// REPLACE: SecKeyCopyExternalRepresentation for P-256 → for Ed25519 (same API, different output)
```

**Also need to fix base64url encoding.** Our current `exportPublicKey` uses `.base64EncodedString()` (standard base64). ClawChat uses base64url (no `+`, `/`, `=`). The gateway expects base64url for the `publicKey` field. Our code is missing the URL-safe conversion.

---

## 6. The "channel" Backend

ClawChat has `BackendType: 'openclaw' | 'channel'`:

### 'openclaw' backend:
- Full WebSocket handshake: `connect.challenge` → `connect` (with Ed25519) → `hello-ok`
- Gets operator scopes
- Can call any RPC method
- Receives all event types

### 'channel' backend:
- Receives `connect.welcome` — no handshake needed
- Skips Ed25519 entirely
- **But gets minimal scopes** — only channel-level access
- Can only do channel-specific operations

The channel backend exists for **in-process channel plugins** (Telegram, Discord, etc.) that run inside the gateway. They don't need Ed25519 because they're already authenticated by virtue of being loaded by the gateway.

### Should BeeChat support both?

**No.** BeeChat is an external macOS app. It should ONLY use the 'openclaw' backend. The 'channel' backend is for in-process plugins that BeeChat will never be.

The only scenario where 'channel' mode would be relevant is if someone wrote a BeeChat channel plugin that ran inside the gateway — but that's exactly the architecture we're moving AWAY from.

**Tradeoffs of supporting both:**
- Pro: Flexibility if someone wants to use BeeChat as a channel plugin later
- Con: Dead code, confused testing, split auth paths
- Con: Channel mode gets no operator scopes, so it can't do `sessions.list`, `chat.history`, etc.

**Recommendation:** Implement only 'openclaw' backend. Hard-code it. Don't even make it configurable.

---

## 7. Concrete Recommendation

### GO — with three hard requirements and one critical risk.

The simplified path is the right call. Being an external WebSocket client is proven by ClawChat. Our existing code structure is close. The pivot from channel plugin to external client was correct.

### Hard Requirements (must-fix before any integration testing):

**R1. Replace P-256 ECDSA with Ed25519.** This is a showstopper. The current `DeviceCrypto.swift` uses the wrong key type and algorithm. Every signature will be rejected. Fix:
- `kSecAttrKeyTypeECSECPrimeRandom` → `kSecAttrKeyTypeEd25519`
- `.ecdsaSignatureMessageX962SHA256` → `.signMessageEd25519`
- Add base64url encoding for public key export
- Add base64url encoding for signature export
- Test: sign the same payload in JS and Swift, verify identical output

**R2. Use v3 signature payload format.** Add `platform` and `deviceFamily` fields to match the gateway's own Control UI client. v2 works today but v3 is the current format. Fix:
```
v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily
```

**R3. Switch EventRouter from "agent" to "chat" events.** The "agent" event has a different structure than "chat". ClawChat uses "chat" for good reason — it's the client-friendly format. Fix EventRouter to:
- Listen for `"chat"` event
- Read `state` (not `data.phase`)
- Read `message` with ContentBlock extraction (not `data.text`)
- Read `errorMessage` for error events
- Replace append-based streaming with replacement-based (the gateway sends accumulated text)

### Additional Recommendations (should-fix but not blocking):

**A1. Implement the two-phase auth flow.** First connection: no device identity, receive deviceToken from hello-ok. Second connection: include device identity with signature. This matches ClawChat's actual behavior.

**A2. Add stream stall detection.** 90-second timeout with no delta = mark as errored. ClawChat has this; we don't. Without it, the UI can hang forever.

**A3. Add connection-loss-during-streaming handling.** When status drops to not-connected while streaming, immediately clear streaming state.

**A4. Store scopes alongside deviceToken.** ClawChat doesn't do this, but it's good practice. If the gateway changes scope grants, we want to know what we had vs what we get.

**A5. Fix the handshake to use stored deviceToken.** Our `GatewayClient.swift` currently hardcodes `auth: .init(token: config.token, deviceToken: nil)`. It should read from TokenStore.

### THE SINGLE BIGGEST RISK:

**The Ed25519 key storage and reimport problem.**

CryptoKit's `Curve25519.Signing.PrivateKey` stores an extended 64-byte key. If we use `SecKeyCreateRandomKey` with `kSecAttrKeyTypeEd25519`, the key is stored in Keychain as a `SecKey` reference. On subsequent launches, we retrieve it with `SecItemCopyMatching`. **But if the Keychain entry is corrupted or lost, we generate a new key, get a new deviceId, and the gateway no longer recognizes us.** We'd need to re-pair.

ClawChat avoids this by storing the private key as base64url in localStorage — it can always reimport. We can't easily do that with `SecKey` (Apple doesn't expose the raw private key bytes through `SecKeyCopyExternalRepresentation` for Ed25519 on all macOS versions).

**Mitigation:** Test that `SecKeyCopyExternalRepresentation` returns the full private key bytes for `kSecAttrKeyTypeEd25519` on macOS 13+. If it does, we can back up the raw key data as an additional Keychain entry. If it doesn't, we'll need to use `Curve25519.Signing.PrivateKey` from CryptoKit and store the `rawRepresentation` directly.

**This is the thing that will bite us at 2am when the Keychain entry gets corrupted during an OS update.** Have a backup path.

---

## Summary Table

| Question | Answer |
|----------|--------|
| Is simplified path correct? | Yes, directionally. But it glosses over Ed25519 complexity and the two-phase auth flow. |
| Data flow comparison | **Mismatch.** BeeChat listens to "agent" events; ClawChat uses "chat" events. Different payload structures. Must switch. |
| State management | BeeChat is missing stream stall detection and connection-loss handling. Keychain > localStorage for security. |
| v2 vs v3 | **ClawChat uses v2, but the gateway's own client uses v3.** Use v3 for future-proofing. |
| Swift/CryptoKit feasibility | Feasible BUT **current code uses P-256 ECDSA instead of Ed25519**. Showstopper bug. Easy fix once identified. |
| Channel backend support | No. Hard-code 'openclaw' only. Channel mode is for in-process plugins. |
| Go/no-go | **GO**, with three hard requirements: fix key type to Ed25519, use v3 payload, switch to "chat" events. |
| Biggest risk | Ed25519 private key storage/reimport resilience across app reinstalls or Keychain corruption. |

---

*End of review.*