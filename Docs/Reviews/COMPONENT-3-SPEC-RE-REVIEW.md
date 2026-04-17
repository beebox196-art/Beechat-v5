# Component 3 Spec Re-Review — Post-Fix Verification

**Reviewer:** Kieran
**Date:** 2026-04-17
**Spec:** `Docs/Architecture/COMPONENT-3-SYNC-BRIDGE-SPEC.md`
**Component 2 source:** `Sources/BeeChatGateway/GatewayClient.swift`

---

## Verification Results

### Item 1 — Component 2 mode conflict ✅ FIXED

**Original issue:** `clientMode` was hardcoded to `"operator"` in Component 2's `ConnectParams.ClientInfo`, but the spec required `"webchat"`.

**Verification:**
- `GatewayClient.Configuration` now has a `clientMode: String` property (line 9)
- Default is `"webchat"` (line 19)
- `clientMode` is passed into `ConnectParams.ClientInfo` at construction (line 30): `mode: clientMode`
- `clientMode` is used in the handshake signature call (line 237): `clientMode: config.clientMode`
- Component 3 can now set `clientMode: "webchat"` in its configuration without touching Component 2 source

**Status:** ✅ FIXED. Clean.

---

### Item 2 — AgentEventData missing fields ✅ FIXED

**Original issue:** `meta`, `progressText`, `output` were absent from `AgentEventData`. `kind: "command"` and `stream: "command_output"` were not documented.

**Verification:**
- `meta: String?` added — line 112, with comment "Full command description (validated live)"
- `progressText: String?` added — line 113, with comment "Streaming progress text (validated live)"
- `output: String?` added — line 114, with comment "Command output chunks (validated live)"
- `kind: "command"` added to `AgentEventData` struct comment — line 106
- Handling rule for `kind: "command"` added — line 139: "command execution tracking (store as message metadata or skip for v1)"
- `stream: "command_output"` handling rule added — line 140: "streaming command output (ephemeral, like delta text)"

**Status:** ✅ FIXED. All three fields present, both undocumented stream/kind values now in spec.

---

### Item 3 — sessions.subscribe in start() lifecycle ✅ FIXED

**Original issue:** `start()` didn't mention calling `sessions.subscribe` after connect.

**Verification:**
- `start()` lifecycle section (line 308) now explicitly includes: `try await gatewayClient.call(method: "sessions.subscribe", params: [:])`
- Placement is correct: after handshake + hello-ok, before fetching sessions.list

**Status:** ✅ FIXED.

---

### Item 4 — Delivery ledger reconciliation: pending-without-runId case ✅ FIXED

**Original issue:** Reconnect reconciliation didn't distinguish between `pending` entries with vs. without a `runId`.

**Verification:**
- Lines 322–326 now specify:
  - pending without runId → ambiguous inflight case
  - If `idempotencyKey` is set → call `chat.history` and search
  - If found → mark as `delivered`
  - If not found and `retryCount < 3` → retry with same `idempotencyKey`
  - If not found and `retryCount >= 3` → mark as `failed`

**Status:** ✅ FIXED. Full branching logic now specified.

---

### Item 5 — Streaming buffer session-switch clear ✅ FIXED

**Original issue:** No explicit rule for clearing the streaming buffer when the user switches sessions mid-stream.

**Verification:**
- Line 424 now explicitly states: "On new session selection → clear `streamingBuffer` and `streamingSessionKey`"
- This is alongside the existing rule (line 425): "If a delta arrives for a different session than the active one, buffer it but don't surface it"

**Status:** ✅ FIXED.

---

### Item 6 — DB write failure severity classification ✅ FIXED

**Original issue:** No distinction between critical and non-critical DB write failures.

**Verification:**
- Error Handling table (line 440) now includes severity classification for DB write failures:
  - Session metadata write failure → log, retry on next event
  - Message write failure → log, flag for reconciliation on reconnect
  - Delivery ledger write failure → **critical**, alert user (message may be lost)

**Status:** ✅ FIXED. Three-tier severity with distinct recovery actions.

---

## New Issues Found

None. Scanning for:
- Inconsistent field names between spec and Component 2 source
- Gaps between "handling rules" prose and the actual struct definitions
- Regressions in the exit criteria
- Any newly introduced ambiguity in previously clean sections

The spec is internally consistent. The `AgentEventData` struct now matches live-captured event shape. The `clientMode` configuration path is clean end-to-end. All handling rules are traceable to struct fields or stream discriminators.

---

## Remaining Minor Gaps (Non-Blocking)

These were "Should Fix" items in the original review. They remain unaddressed but do not block build:

1. **`hello-ok.snapshot` on reconnect** — The spec references `hello-ok` for `deviceToken` persistence on reconnect (line 317) but doesn't explicitly say "process `hello-ok.snapshot` for initial state on reconnect the same way as first connect." GatewayClient already handles this (calls `handleHelloOk` on every connect), but the spec could be more explicit. **Non-blocking.**

2. **`chat` event alias** — `chat` events are not mentioned in the spec's event handling rules. If the gateway sends `chat` events (which it may alongside `agent`), there's no guidance on handling them. **Non-blocking for v1** since live capture confirms `agent` is the primary event.

3. **ValueObservation → AsyncStream bridge** — Implementation sketch still missing ("Map to AsyncStream for SwiftUI consumption" is still just a comment). Coder will need to implement this correctly without a template. **Non-blocking** — this is standard Swift concurrency pattern.

4. **SyncBridge write path** — The spec doesn't clarify whether SyncBridge writes via `GatewayEventConsumer` protocol or directly via repository methods. Source code (not yet written) will decide this. **Non-blocking.**

---

## Verdict

**PASS.** All 6 must-fix items verified fixed. No new issues introduced.

The spec is ready for Component 3 build. The coder has a clean contract: all data models match live-captured events, all lifecycle sequences are explicit, all edge cases in the delivery ledger are specified, and severity classification prevents silent data loss.

**Recommended action:** Proceed to build. File separate issue for the 4 non-blocking gaps if desired for v1.1.
