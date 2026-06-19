# Component 2 Review: BeeChatGateway
**Reviewer:** Kieran — Continuous Review Gate  
**Date:** 2026-04-17  
**Status:** **REVIEW COMPLETE — FAIL**  

---

## Summary

The implementation has significant structural and correctness issues that must be resolved before Component 3 can build on this foundation. The WebSocket transport loop is broken (immediate task cancellation before any receive can happen), the `hello-ok` parsing will always fail, the state machine does not correctly distinguish fatal from non-fatal close codes, and the `disconnect()` path leaks timer resources. These are not polish issues — they are functional defects.

---

## PASS — Things That Are Solid

### Spec Compliance
- ✅ All 5 `ConnectionState` values exist and are correctly named
- ✅ State machine enum structure matches spec
- ✅ `FrameType`, `RequestFrame`, `ResponseFrame`, `EventFrame` all match spec
- ✅ `ConnectParams`, `ClientInfo`, `AuthInfo`, `HelloOk` structs match spec
- ✅ `HelloOk.ServerInfo`, `HelloOk.Features`, `HelloOk.Policy`, `HelloOk.AuthResult` all match spec
- ✅ `DeviceIdentity` struct matches spec
- ✅ `DeviceCrypto.signChallenge()` uses the correct pipe-delimited canonical format: `v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce`
- ✅ `BackoffCalculator` formula is correct: `min(base * 2^attempt, max) ± 20% jitter`
- ✅ `KeychainTokenStore` uses correct service (`com.beechat.tokens`) and account keys
- ✅ `KeychainTokenStore.deleteAll()` uses `kSecClassGenericPassword` (correct class for generic password items)
- ✅ `AnyCodable` encoding/decoding is well-implemented with proper type coverage
- ✅ `BackoffCalculator.delay(forAttempt:)` uses `Double.random(in: -1...1)` — correct for ±20% jitter
- ✅ Device key tag is `com.beechat.device-identity` (stored in Keychain)
- ✅ `GatewayClient.Configuration` defaults: `requestTimeout = 30s`, `maxRetries = 10`, `baseRetryDelay = 1s`, `maxRetryDelay = 30s` — all correct
- ✅ `WebSocketTransport` uses native `URLSessionWebSocketTask` — no third-party dependency

### Code Quality
- ✅ `PendingRequestMap` is a proper `actor` — thread-safe
- ✅ `ConnectionState` is `Sendable` and `Codable`
- ✅ All frame types are `Sendable`
- ✅ `BackoffCalculator` is `Sendable`
- ✅ `GatewayClient` is a proper `actor`
- ✅ `KeychainTokenStore` conforms to `TokenStore: Sendable`
- ✅ `DeviceCryptoError` has proper `LocalizedError` conformance
- ✅ Tests are well-structured with `XCTestExpectation` for async work
- ✅ `PendingRequestMapTests` correctly tests resolve, reject, timeout, and clearAll
- ✅ `BackoffCalculatorTests` tests the jitter range, exponential growth, and max cap

### Protocol
- ✅ `connect` request includes `minProtocol: 3`, `maxProtocol: 3`
- ✅ `connect` request includes `client`, `role`, `scopes`, `auth` (all required fields)
- ✅ `device` field is only included when `currentDeviceToken` exists (per spec: "only send when deviceToken exists")
- ✅ `signedAt` uses `Int(Date().timeIntervalSince1970 * 1000)` — current time, correct
- ✅ Signature payload uses `v2` prefix (not v1)
- ✅ Device ID derived via SHA-256 of public key raw bytes, hex-encoded (64 chars)

---

## WARN — Fragile or Will Bite Later

### W1: `GatewayEvent` enum is missing from the package
**File:** `Sources/BeeChatGateway/Protocol/GatewayEvent.swift` does not exist. The spec lists it but it was never created. The spec says `GatewayEvent` defines "Event types (chat, agent, tick, etc.)" — these are not defined anywhere in the source. Component 3's `Sync Bridge` will need to parse event type strings like `"chat"`, `"agent"`, `"tick"` with no compiler-enforced enum. Not fatal for v1 but will be a source of bugs.

### W2: `deleteAll()` in KeychainTokenStore doesn't specify account
**File:** `TokenStore.swift`

```swift
public func deleteAll() throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    SecItemDelete(query as CFDictionary)
}
```

This query is missing `kSecAttrAccount as String: kSecMatchLimitAll` (or simply omit account to match all). As written it may not delete all token accounts under this service. The `SecItemDelete` with no account qualifier only deletes items that match **all** attributes exactly — since no account is specified, it deletes nothing. However, the test `testDeleteAll` only asserts that `deleteAll()` "doesn't throw" so this bug is invisible. See **T2** in Test Coverage.

### W3: `DeviceCrypto.getOrCreateKeyPair()` always creates a new key on first call
**File:** `DeviceCrypto.swift`

```swift
if status == errSecSuccess, let key = item {
    return key as! SecKey
}
// Generate new EC P-256 keypair ...
```

The `errSecSuccess` path is force-unwrapped (`item as! SecKey`). If the key exists and is retrieved, this is safe. But the problem is subtle: on first launch, the key doesn't exist, a new one is created and stored. However, the subsequent `SecKeyCreateRandomKey` call uses `kSecAttrIsPermanent: true` with only the tag — if another key with the same tag already existed (e.g., from a prior partial run), it could conflict. More importantly: the `SecKeyCreateRandomKey` error is taken via `error?.takeUnretainedValue()` which is safe, but the initial retrieval force-cast is not an issue — however, if `errSecSuccess` but `item` is unexpectedly nil, this crashes.

### W4: `PendingRequestMap` uses `DispatchSourceTimer` — not cancel-safe with actor isolation
**File:** `PendingRequestMap.swift`

The `PendingRequest` struct holds a `DispatchSourceTimer`. When `resolve`/`reject`/`remove` is called, the timer is accessed from the actor context. `DispatchSourceTimer` is not `Sendable`. In Swift 6 strict concurrency, this will be a compile error. For now it compiles because the project likely doesn't have strict concurrency enabled. This will break with Swift 6.

### W5: `WebSocketTransport` delegates to `URLSession` on `.main` queue
**File:** `WebSocketTransport.swift`

```swift
self.session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
```

All WebSocket delegate callbacks fire on the main thread. `GatewayClient` is an `actor`, so it will receive these callbacks from the main thread into actor-isolated methods. This is likely safe but could cause issues if `URLSession` delegate methods fire during actor suspension. Not immediately breaking, but worth monitoring.

### W6: `encodeParams` in `GatewayClient.performHandshake()` is unused
**File:** `GatewayClient.swift` line with `try encodeParams(params)` — the result is thrown away and `params` is encoded directly:

```swift
let data = try JSONEncoder().encode(frame)  // params encoded inside frame directly
```

The `encodeParams` helper is dead code.

### W7: No integration test for the full handshake flow
The test file only has unit tests. There are no tests that verify the full connect → challenge → connect-request → hello-ok → connected flow. This is a TODO per the spec ("are there TODO integration tests that need to be called out?").

### W8: Public API uses `gatewayMaxPayload` not `maxPayload` as property name
**File:** `GatewayClient.swift`

```swift
public var gatewayMaxPayload: Int { maxPayload }
```

Spec says `maxPayload`. Minor inconsistency but Component 3 consumers will reference the wrong name.

---

## FAIL — Must Fix Before Component 3

### F1: WebSocket receive loop is broken — Task is cancelled before any receive can happen
**File:** `GatewayClient.swift` — `performConnect()`

```swift
_ = transport.connect(url: url)  // BUG 1: return value ignored, task reference lost

Task {
    do {
        while state != .disconnected && state != .error {
            let message = try await transport.receive()  // BUG 2: receive() waits forever
            ...
        }
    } catch {
        await handleTransportError(error)
    }
}
```

**Problem 1:** `transport.connect(url:)` returns a `URLSessionWebSocketTask` that must be kept alive. The return value is discarded (`_ =`). Without storing it, the task is eligible for garbage collection immediately. `URLSessionWebSocketTask` is not retained by the `session` — the session only holds tasks weakly.

**Problem 2:** `transport.receive()` calls `task.receive()` on a task that may already be GC'd or never properly started. Even if the task reference were kept, `WebSocketTransport.receive()` does:

```swift
public func receive() async throws -> URLSessionWebSocketTask.Message {
    guard let task = task else { throw NSError(...) }  // BUG 3: task nil → throws
    return try await task.receive()
}
```

If `connect()` was called but the task reference was discarded, `task` will be `nil` and `receive()` throws immediately. The whole receive loop exits and `handleTransportError` is called, which triggers a reconnect. This creates an infinite loop of immediate reconnect attempts with no actual communication ever happening.

**Fix needed:** Store the `URLSessionWebSocketTask` reference in `WebSocketTransport` and expose it properly, or restructure so `receive()` doesn't need the caller to hold the task reference.

### F2: `hello-ok` parsing will always fail — nested Decodable mismatch
**File:** `GatewayClient.swift` — `handleHelloOk()`

```swift
guard let payload = frame.payload,
      let data = try? JSONEncoder().encode(payload) else { return }

let helloOk = try JSONDecoder().decode(HelloOk.self, from: data)
```

`frame.payload` is `[String: AnyCodable]?`. When encoded with `JSONEncoder`, `AnyCodable` encodes to a JSON object where each value is nested — e.g., `"maxPayload": {"_": 1048576}` instead of `"maxPayload": 1048576`. This is because `AnyCodable` wraps values and `encode(to:)` stores them under a `"_"` key (or similar). When `JSONDecoder` tries to decode this as `HelloOk`, it expects `Int` but gets a nested object — decoding fails.

The `hello-ok` is never actually parsed. `retryCount` is never reset. `maxPayload` is never set from the server. The client appears to work but silently ignores the server's handshake response.

**Fix needed:** Decode `HelloOk` directly from the raw `EventFrame` or raw JSON, not via re-encoding `AnyCodable` dictionary values. Either decode from the original raw data or construct `HelloOk` by extracting values from `AnyCodable` manually.

### F3: State machine does not distinguish fatal from non-fatal close codes
**File:** `GatewayClient.swift` — `handleTransportError()`

```swift
private func handleTransportError(_ error: Error) async {
    if retryCount < config.maxRetries {
        let delay = backoff.delay(forAttempt: retryCount)
        retryCount += 1
        updateState(.connecting)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await performConnect()
    } else {
        updateState(.error)
    }
}
```

There is no close code checking. The spec says:
- Fatal codes (1008, 4xxx) → `error` state, **no reconnect**
- Non-fatal codes → reconnect with backoff

Currently **all** errors trigger reconnect until max retries, then `error`. A 1008 (Policy Violation) or 4001 (auth failure) should immediately go to `error` state without retry. Without `URLSessionWebSocketDelegate` implementing `urlSession(_:webSocketTask:didCloseWith:reason:)` or checking close codes, this is impossible.

The `WebSocketTransport` class conforms to `NSObject, URLSessionWebSocketDelegate` but none of the delegate methods are implemented. Close events are never captured.

**Fix needed:** Implement `urlSession(_:webSocketTask:didCloseWith:reason:)` in `WebSocketTransport` and propagate the close code to `GatewayClient` so it can make the fatal/non-fatal decision.

### F4: `disconnect()` leaks DispatchSourceTimers
**File:** `GatewayClient.swift` — `disconnect()`

```swift
public func disconnect() async {
    transport.disconnect()
    await pendingRequests.clearAll(reason: "Client disconnected")
    updateState(.disconnected)
}
```

`pendingRequests.clearAll()` cancels all timers and rejects pending continuations, which is correct. However, `disconnect()` is called from `connect()` at the start:

```swift
public func connect() async {
    await disconnect()
    retryCount = 0
    await performConnect()
}
```

This is fine. The issue is in `PendingRequestMap.clearAll()`:

```swift
public func clearAll(reason: String) {
    for (id, req) in pending {
        req.timer.cancel()
        req.reject(NSError(...))
    }
    pending.removeAll()
}
```

This is correct. However, there is a subtle bug: `clearAll` is also called when `disconnect()` is called during a reconnect loop. The timers are cancelled but `pending.removeAll()` is called in the same synchronous pass as the loop. Since each timer cancellation dispatches a reject handler that might reference `self` (the actor), there is no race condition here because the actor executes sequentially. This is actually fine.

The real issue is that `PendingRequestMap.remove(id:reason:)` and `PendingRequestMap.reject(id:error:)` cancel the timer **before** removing from the dictionary. If the timer fires between cancellation and removal, it could theoretically fire twice (once for cancel, once for the original schedule). However, this is not a real problem because `DispatchSourceTimer` is one-shot — after firing it is automatically cancelled.

### F5: Request ID uses UUID — not incrementing
**File:** `GatewayClient.swift` — `call()`

```swift
let id = "bc-\(UUID().uuidString)"
```

Spec says request IDs must be "unique and incrementing (`bc-<incrementing>`)". UUIDs are unique but not incrementing. This is a spec violation. More importantly, the server or middleware may expect monotonically increasing integer IDs for correlation. UUIDs will work for most servers but violate the spec contract.

**Fix needed:** Use an `Int` counter (`nextRequestId` in the actor) instead of UUID.

### F6: `onStatusChange` and `onDeviceToken` callbacks are not actor-isolated
**File:** `GatewayClient.swift`

```swift
public var onStatusChange: ((ConnectionState) -> Void)?
public var onDeviceToken: ((String) -> Void)?
```

`GatewayClient` is an `actor`. These callbacks are `nonisolated` properties holding closures. When called from actor-isolated code (`updateState`, `handleHelloOk`), the closures are invoked from within the actor's isolation domain. This is technically safe but the closures themselves can be called from anywhere (they're `nonisolated`). If the consumer's closure captures non-Sendable types and the consumer is also an actor, this violates Sendable rules. In Swift 6 this will be an error.

**Fix needed:** Either make the callbacks `nonisolated` and document that they must be Sendable-safe, or use `unsafeBitCast` to call from actor context. The cleanest fix is to make them `@unchecked Sendable` closures or document the constraint.

### F7: `gatewayMaxPayload` vs `maxPayload` naming inconsistency
Already noted in W8. The spec public API uses `maxPayload` but the implementation uses `gatewayMaxPayload`. Component 3 will reference the wrong name if it follows the spec.

---

## ACTION ITEMS

### Priority 1 — Blocking (breaks core functionality)

1. **Fix WebSocket receive loop** (`F1`)
   - Store `URLSessionWebSocketTask` reference in `WebSocketTransport` as a property (not just returned)
   - Make `receive()` use `self.task` internally so callers don't need to hold the reference
   - Ensure the task stays alive for the duration of the connection

2. **Fix hello-ok parsing** (`F2`)
   - Do not re-encode `AnyCodable` dictionary to decode `HelloOk`
   - Decode `HelloOk` directly from the raw `EventFrame` data or raw JSON
   - Add a test that encodes/decodes a full `HelloOk` payload to verify the round-trip works

3. **Implement WebSocket close code handling** (`F3`)
   - Implement `urlSession(_:webSocketTask:didCloseWith:reason:)` delegate method in `WebSocketTransport`
   - Propagate close codes to `GatewayClient` (add a `closeCode` parameter to `handleTransportError` or similar)
   - Map: code 1008 and 4xxx-range → fatal (→ `error` state, no reconnect); others → non-fatal (reconnect with backoff)

### Priority 2 — Correctness (spec violations, will cause issues with Component 3)

4. **Use incrementing Int request IDs** (`F5`)
   - Replace `UUID().uuidString` with an actor-owned `Int` counter
   - Generate IDs as `"bc-\(nextRequestId)"` and increment atomically within the actor

5. **Create `GatewayEvent` enum** (`W1`)
   - Create `Sources/BeeChatGateway/Protocol/GatewayEvent.swift`
   - Define event types: `chat`, `agent`, `tick`, `presence`, `typing`, `error`, etc.
   - Used by Component 3's `Sync Bridge` for type-safe event routing

6. **Fix `KeychainTokenStore.deleteAll()`** (`W2`)
   - Add `kSecMatchLimit as String: kSecMatchLimitAll` to the query so it matches all accounts under the service
   - Or use `SecItemDelete` with a base query then delete by account key explicitly

### Priority 3 — Swift 6 / Future-Proofing

7. **Make callbacks Sendable-safe** (`F6`)
   - Add `@unchecked Sendable` annotation to `onStatusChange` and `onDeviceToken` closure types
   - Document that callers must ensure their closures are Sendable

8. **Make `DispatchSourceTimer` Sendable-safe** (`W4`)
   - Replace `DispatchSourceTimer` with `Task.sleep` for timeouts in `PendingRequestMap`
   - Store `Task` references instead of `DispatchSourceTimer`; cancel with `task.cancel()`
   - This eliminates the `DispatchSourceTimer` (non-Sendable) from the actor-isolated struct

9. **Rename `gatewayMaxPayload` to `maxPayload`** (`W7`)
   - Match spec public API exactly

### Priority 4 — Testing

10. **Add integration test for full handshake flow**
    - Test: connect → receive challenge → send connect request → receive hello-ok → verify state = connected
    - Use a mock WebSocket server or intercept `URLSessionWebSocketTask` messages

11. **Fix `testDeleteAll`** (`T2`)
    - After fixing `deleteAll()`, verify tokens are actually gone (not just that the call doesn't throw)

12. **Add test for hello-ok parsing** (`T3`)
    - Encode a `HelloOk` → decode via `AnyCodable` → verify it fails (to prove the bug)
    - Then fix and verify the round-trip works

---

## Test Coverage Assessment

**Unit tests cover:**
- `ConnectionState` (all 5 states, raw values, Codable round-trip)
- `BackoffCalculator` (jitter range, exponential growth, max cap)
- `DeviceCrypto` (key generation, device ID derivation, public key export, signing)
- `Frame` encoding/decoding (request, response, error, event)
- `KeychainTokenStore` (gateway token, device token, update)
- `PendingRequestMap` (resolve, reject, timeout, clearAll)

**NOT tested (critical for Component 3):**
- Full WebSocket handshake flow (connect → challenge → hello-ok → connected)
- `call(method:params:)` end-to-end RPC
- `eventStream()` AsyncStream delivery
- Reconnect with backoff (triggered by non-fatal close)
- Fatal close code handling (1008, 4xxx → error, no reconnect)
- `disconnect()` intentional no-reconnect behavior
- `hello-ok` → `deviceToken` → `KeychainTokenStore` persistence flow
- Error state transitions
- Multiple concurrent `call()` requests (request ID collision)
- Timeout behavior (request times out after 30s)
- `onStatusChange` and `onDeviceToken` delegate callbacks

**Specific test gaps:**
- T1: No integration test for the actual WebSocket transport
- T2: `testDeleteAll` does not verify deletion actually happened
- T3: No test for `hello-ok` parsing (the `AnyCodable` re-encoding path has a known bug — see F2)
- T4: No test for request ID uniqueness (UUID vs incrementing — see F5)
- T5: No test for `eventStream()` — no verification that events are delivered to the AsyncStream consumer
- T6: No test for fatal vs non-fatal close code handling

---

## Overall Verdict

**Result: FAIL** — The component cannot pass its exit criteria in its current state. The WebSocket receive loop is broken (F1), `hello-ok` parsing silently fails (F2), and close codes are not handled (F3). These three issues mean the component will not successfully connect, complete handshake, or transition to `connected` state in practice.

Component 3 integration should **not begin** until P1 items are resolved and at least one integration test verifies the full handshake flow end-to-end.

**Estimated fix scope:** 3–4 hours for P1 items, 2–3 hours for P2 items, 1–2 hours for P3+P4 items.
