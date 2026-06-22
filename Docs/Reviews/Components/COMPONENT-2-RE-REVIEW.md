# Component 2 Re-Review: BeeChatGateway — Post-Fix Verification
**Reviewer:** Kieran — Continuous Review Gate
**Date:** 2026-04-17
**Context:** Round 2 review following fixes for issues identified in COMPONENT-2-REVIEW.md
**Files Reviewed:**
- `Sources/BeeChatGateway/GatewayClient.swift`
- `Sources/BeeChatGateway/Transport/WebSocketTransport.swift`
- `Sources/BeeChatGateway/Protocol/Frame.swift`
- `Sources/BeeChatGateway/Protocol/GatewayEvent.swift` (NEW)
- `Sources/BeeChatGateway/Auth/TokenStore.swift`

---

## FAIL Items — Verification

### FAIL-1: WebSocket receive loop broken — URLSessionWebSocketTask not retained
**Original Finding:** Return value of `transport.connect(url:)` was discarded (`_ =`), task was GC-eligible immediately. `receive()` would throw because `task` was nil.

**Fix Applied:**
```swift
// WebSocketTransport.swift
private var task: URLSessionWebSocketTask?  // Strong property — lives on self

public func connect(url: URL) {
    let task = session.webSocketTask(with: url)
    self.task = task  // Stored on self, not discarded
    task.resume()
}

public func receive() async throws -> URLSessionWebSocketTask.Message {
    guard let task = task else { throw NSError(...) }  // References stored task
    return try await task.receive()
}

public func disconnect() {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil  // Released on disconnect
}
```

**Analysis:**
- `URLSessionWebSocketTask` is now stored as a strong instance property on `WebSocketTransport`
- It survives for the full connection lifetime; GC cannot collect it mid-use
- `receive()` correctly references `self.task` — callers no longer need to hold a separate reference
- `disconnect()` cancels the task and releases the reference cleanly
- The `receive()` loop in `performConnect()` correctly awaits `transport.receive()` in a `Task` that stays alive while `state != .disconnected && state != .error`

**VERIFIED** ✅

---

### FAIL-2: hello-ok parsing always fails — nested AnyCodable Decodable mismatch
**Original Finding:** `handleHelloOk()` re-encoded `frame.payload` (`[String: AnyCodable]`) via `JSONEncoder` → `JSONDecoder`. `AnyCodable` encodes values as `{"_": value}` so decoding `HelloOk` (which expects bare values) always failed silently.

**Fix Applied:**
```swift
// Frame.swift — ResponseFrame
public struct ResponseFrame: Codable, Sendable {
    // ... other properties ...
    public var rawData: Data? = nil  // NEW: store original bytes
}

// GatewayClient.handleMessage()
let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
var resFrame = try JSONDecoder().decode(ResponseFrame.self, from: data)
resFrame.rawData = data  // Capture raw bytes before AnyCodable mutates structure

// GatewayClient.handleHelloOk()
guard let data = frame.rawData ?? (try? JSONEncoder().encode(frame.payload)) else { return }
let helloOk = try JSONDecoder().decode(HelloOk.self, from: data)  // Decodes from original JSON
```

**Analysis:**
- **Happy path is fixed.** When `frame.rawData` is present (which it always is from `handleMessage`), `JSONDecoder().decode(HelloOk.self, from: data)` decodes directly from the original un-mutated JSON bytes. This is the correct fix.
- **The fallback path** (`try? JSONEncoder().encode(frame.payload)`) still has the `AnyCodable` nesting bug. It will decode as `{"_": ...}` nested objects and fail. But this path is now only hit if `rawData` is `nil`.
- **Risk:** If any code path creates a `ResponseFrame` without going through `handleMessage` (e.g., a unit test, or a future call path), it would hit the broken fallback. This is a latent bug but not a current regression.
- The fallback should ideally be removed or the `AnyCodable` encoding should be fixed. But the primary path works correctly.

**VERIFIED (happy path) / PARTIAL (fallback still broken but not exercised)**

---

### FAIL-3: State machine doesn't distinguish fatal from non-fatal close codes
**Original Finding:** No `URLSessionWebSocketDelegate` method captured close events. All errors triggered reconnect-with-backoff regardless of severity.

**Fix Applied:**
```swift
// WebSocketTransport.swift
public var onClose: ((Int, String?) -> Void)?  // NEW callback

public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                       didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    let code = Int(closeCode.rawValue)
    let reasonString = reason != nil ? String(data: reason!, encoding: .utf8) : nil
    onClose?(code, reasonString)  // Propagates to GatewayClient
}

// GatewayClient.performConnect()
transport.onClose = { [weak self] code, reason in
    Task { await self?.handleClose(code: code, reason: reason) }
}

// GatewayClient.handleClose()
private func handleClose(code: Int, reason: String?) async {
    if code == 1008 || (code >= 4000 && code <= 4999) {
        updateState(.error)  // Fatal — no reconnect
    } else {
        await handleTransportError(...)  // Non-fatal — reconnect with backoff
    }
}
```

**Analysis:**
- `urlSession(_:webSocketTask:didCloseWith:reason:)` is properly implemented
- `onClose` callback correctly propagates `Int` close code and optional reason string
- `handleClose` correctly implements the spec's fatal/non-fatal decision:
  - `1008` (Policy Violation) → `.error`, no reconnect
  - `4000–4999` (application-defined fatal) → `.error`, no reconnect
  - All others (including `1000` normal, `1001` going away, network errors) → reconnect with backoff
- Note: `handleClose` calls `handleTransportError` with a synthetic error for non-fatal codes, which applies backoff and reconnects. This is correct.
- Note: The `urlSession(_:task:didCompleteWithError:)` error delegate method is NOT implemented. For connection-level errors that don't produce a close code (e.g., network unreachable, TLS failures), the task completes with an error but no close frame. In these cases `didCloseWith` may not fire. This means fatal application errors (4xxx) are handled, but connection-level fatal errors may still silently fall through to reconnect logic. This is acceptable for now but worth noting as a future hardening item.

**VERIFIED** ✅

---

## WARN Items — Verification

### W1: GatewayEvent enum was missing
**Original Finding:** No `GatewayEvent.swift` existed. Event type strings were untyped.

**Fix Applied:**
```swift
// GatewayEvent.swift (NEW)
public enum GatewayEvent: String, Codable, Sendable {
    case chat
    case agent
    case tick
    case presence
    case typing
    case error
    case connectChallenge = "connect.challenge"
    case stateSnapshot = "state.snapshot"
    case sessionUpdate = "session.update"
    case messageUpdate = "message.update"
}
```

**Analysis:**
- File now exists and defines the key event types
- `connectChallenge` is correctly string-aliased to `"connect.challenge"`
- `stateSnapshot`, `sessionUpdate`, `messageUpdate` are defined but NOT used in `handleEvent()` yet — Component 3's Sync Bridge will need to route these
- Conforms to `Codable, Sendable` as required

**VERIFIED** ✅ (file exists; not yet integrated into message handling)

---

### W2: deleteAll() didn't specify kSecMatchLimitAll
**Original Finding:** Query lacked `kSecMatchLimitAll` so `SecItemDelete` deleted nothing (matched zero items since no account was specified).

**Fix Applied:**
```swift
public func deleteAll() throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll  // FIXED
    ]
    SecItemDelete(query as CFDictionary)
}
```

**Analysis:**
- `kSecMatchLimitAll` correctly tells Security.framework to delete all items matching the query (service + class), regardless of account
- This will delete both `gatewayToken` and `deviceToken` in one call
- Apple's `SecItemDelete` with `kSecMatchLimitAll` returns `errSecSuccess` even if no items matched — the original test assertion (just "doesn't throw") was already passing before the fix, so this was invisible without a read-back verification

**VERIFIED** ✅

---

### W8: gatewayMaxPayload vs maxPayload naming
**Original Finding:** Spec says `maxPayload`, implementation exposed `gatewayMaxPayload`.

**Fix Applied:**
```swift
public var maxPayload: Int { _maxPayload }  // Was: gatewayMaxPayload
```

**Analysis:** Public property is now correctly named `maxPayload`, matching the spec. Component 3 consumers can follow the spec directly.

**VERIFIED** ✅

---

### F5: Request IDs use UUID — not incrementing
**Original Finding:** `let id = "bc-\(UUID().uuidString)"` — violates spec's "unique and incrementing" requirement.

**Fix Applied:**
```swift
private var nextRequestId: Int = 0  // Actor state

public func call(method:params:) async throws -> [String: AnyCodable] {
    let id = "bc-\(nextRequestId)"  // Was: UUID
    nextRequestId += 1
    // ...
}
```

**Analysis:**
- `nextRequestId` is actor-isolated (`GatewayClient` is an `actor`) — thread-safe
- IDs are monotonically increasing integers: `bc-0`, `bc-1`, `bc-2`...
- Server-side correlation is now possible (monotonic integer vs UUID)
- No upper bound is set — at extreme scale `Int` overflow is theoretically possible but unrealistic for any real deployment

**VERIFIED** ✅

---

## REGRESSIONS INTRODUCED BY FIXES

### REGRESSION-1: handleHelloOk fallback path still has AnyCodable bug
**File:** `GatewayClient.swift` — `handleHelloOk()`

```swift
guard let data = frame.rawData ?? (try? JSONEncoder().encode(frame.payload)) else { return }
```

If `frame.rawData` is `nil`, the fallback path executes `JSONEncoder().encode(frame.payload)` where `frame.payload` is `[String: AnyCodable]?`. As documented in the original FAIL-2, `AnyCodable` encodes values as `{"_": value}` — a nested structure. `JSONDecoder().decode(HelloOk.self, from: data)` then fails because `HelloOk.maxPayload` is `Int`, not `{"_": Int}`.

**Severity:** Low in practice — `frame.rawData` is set by `handleMessage()` for all real traffic. The fallback only fires if `ResponseFrame` is constructed without going through `handleMessage`. No current code path does this.

**Recommendation:** Remove the fallback or fix it by using a proper AnyCodable → flat JSON encoding.

**REGRESSION** (latent, not currently exercised)

---

### REGRESSION-2: performHandshake() swallows device crypto failures and proceeds
**File:** `GatewayClient.swift` — `performHandshake()`

```swift
if let deviceToken = currentDeviceToken {
    do {
        // ... crypto operations ...
        device = DeviceIdentity(...)
    } catch {
        print("Handshake crypto failed: \(error)")
        // Falls through — device stays nil, request still sent
    }
}
// Sends connect request with device=nil even if crypto completely failed
let frame = RequestFrame(id: "handshake", method: "connect", params: try encodeParams(params))
```

**Analysis:** If `DeviceCrypto` throws (key generation failure, signing failure, device ID derivation failure), the error is logged and `device` stays `nil`. The connect request is still sent without the `device` field. The server may reject this. This was present before but the original review didn't flag it explicitly.

**NEW ISSUE** (pre-existing but not flagged in original review)

---

## NEW ISSUES

### NEW-1: WebSocketTransport delegate queue is .main — all callbacks fire on main thread
**File:** `WebSocketTransport.swift`

```swift
self.session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
```

`URLSessionWebSocketDelegate` callbacks (including `didCloseWith`, `didCompleteWithError`) all fire on the main thread. `GatewayClient` is an `actor`. The `onClose` callback in `performConnect()` does:

```swift
transport.onClose = { [weak self] code, reason in
    Task { await self?.handleClose(code: code, reason: reason) }
}
```

The `[weak self]` closure is called from the main thread, then a new `Task` is spawned to run `handleClose` on the actor. This is safe because:
1. The actor is kept alive by the `Task`
2. The closure captures self weakly so no retain cycle
3. The `Task { await self?.handleClose(...) }` correctly hops to the actor

**Severity:** Low. This is a common pattern. However, if the main thread is blocked or the actor is busy, close events queue on the main thread. If the actor's executor is saturated, the `Task { await ... }` may be scheduled after a delay. Not a correctness bug but a potential latency issue for close event handling.

**NEW ISSUE** (not present in original review)

---

### NEW-2: eventContinuation not finished on disconnect
**File:** `GatewayClient.swift`

```swift
private var eventContinuation: AsyncStream<...>.Continuation?

public func eventStream() -> AsyncStream<...> {
    AsyncStream { continuation in
        self.eventContinuation = continuation
    }
}

public func disconnect() async {
    // eventContinuation is NEVER finished or nil'd here
}
```

`eventContinuation` is stored but never had `.finish()` called on disconnect. If a consumer iterates the `AsyncStream` after `disconnect()`, it will hang forever waiting for a yielded event that never arrives (and never fails). The stream has no terminal event.

**Severity:** Medium — consumers of `eventStream()` who call it before `disconnect()` and then try to iterate after disconnect will hang. Should call `eventContinuation?.finish()` in `disconnect()`.

**NEW ISSUE**

---

### NEW-3: onStatusChange/onDeviceToken not Sendable — Swift 6 violation
**File:** `GatewayClient.swift`

```swift
public var onStatusChange: ((ConnectionState) -> Void)?  // Not @unchecked Sendable
public var onDeviceToken: ((String) -> Void)?              // Not @unchecked Sendable
```

Still unfixed from original F6. Swift 6 compile will fail.

**Noted in original — not yet fixed.**

---

### NEW-4: PendingRequestMap uses DispatchSourceTimer — Swift 6 violation
**File:** `PendingRequestMap.swift` (referenced in original W4)

`DispatchSourceTimer` is not `Sendable`. Still unfixed.

**Noted in original — not yet fixed.**

---

## KNOWN GAPS (Requested Tests Not Added)

The following 4 tests were explicitly requested in the original review's ACTION ITEMS and **none were added**:

| Test | Purpose | Status |
|---|---|---|
| `testHelloOkParsingFromRawJSON` | Verify `HelloOk` decodes correctly from raw JSON bytes | **NOT ADDED** |
| `testGatewayEventEnum` | Verify all `GatewayEvent` cases encode/decode | **NOT ADDED** |
| `testRequestIdIncrementing` | Verify `nextRequestId` produces monotonic integers | **NOT ADDED** |
| `testDeleteAllKeychain` | Verify tokens are actually gone after `deleteAll()` | **PARTIAL** — existing test still only checks "doesn't throw" |

The `testDeleteAll` in `KeychainTokenStoreTests` was not updated to verify read-back-after-delete.

**Gap remains open.**

---

## Summary Table

| Item | Original Status | Fixed? | Notes |
|---|---|---|---|
| FAIL-1: Task not retained | FAIL | ✅ VERIFIED | Strong property, receive loop now functional |
| FAIL-2: AnyCodable parsing | FAIL | ✅ VERIFIED (happy path) | rawData path works; fallback still broken |
| FAIL-3: Close code handling | FAIL | ✅ VERIFIED | Proper fatal/non-fatal discrimination |
| W1: GatewayEvent missing | WARN | ✅ VERIFIED | File created, enum defined |
| W2: deleteAll broken | WARN | ✅ VERIFIED | kSecMatchLimitAll now present |
| W8: gatewayMaxPayload naming | WARN | ✅ VERIFIED | Renamed to maxPayload |
| F5: UUID request IDs | FAIL | ✅ VERIFIED | Incrementing Int IDs |
| F6: Callbacks not Sendable | FAIL | ❌ NOT FIXED | Swift 6 violation |
| W4: DispatchSourceTimer not Sendable | WARN | ❌ NOT FIXED | Swift 6 violation |
| Regression: handleHelloOk fallback | — | ⚠️ REGRESSION | Latent fallback still broken |
| Regression: crypto failure proceeds | — | ⚠️ NEW ISSUE | Pre-existing not flagged |
| NEW: Main thread delegate queue | — | ⚠️ NEW | Latency concern, not correctness |
| NEW: eventContinuation not finished | — | ⚠️ NEW | Consumer hang after disconnect |
| Tests not added | Gap | ❌ NOT ADDRESSED | 4 requested tests missing |

---

## VERDICT

**Result: FAIL — Component 3 should not build on this yet**

The three blocking FAILs (F1, F2, F3) are genuinely fixed. The component will now:
- Keep the WebSocket task alive for the full connection duration
- Correctly parse `hello-ok` from the server's raw JSON response
- Distinguish fatal from non-fatal close codes and act accordingly

These are real, meaningful fixes.

However, two **new issues** introduced by the fixes are correctness bugs:

1. **NEW-2 (eventContinuation not finished):** Any consumer of `eventStream()` that tries to use the stream after `disconnect()` will hang forever. This is a guaranteed deadlock for the Component 3 sync bridge if it holds a reference to the event stream across a reconnect.

2. **NEW-1 (main thread delegate queue):** While not a correctness bug today, close events firing on `.main` with an actor waiting to handle them is a latent priority inversion. If the main thread is busy, close events are delayed, which affects reconnection latency.

Additionally, the **regression in handleHelloOk's fallback path** is a time bomb. The fallback path is broken and will produce silent `hello-ok` parse failures if any future code path bypasses `handleMessage()`. It should either be removed or fixed properly.

### Minimum Fixes Required Before Component 3

| Priority | Issue | Fix |
|---|---|---|
| P0 | NEW-2: eventContinuation not finished | Call `eventContinuation?.finish()` in `disconnect()` |
| P0 | REGRESSION: handleHelloOk fallback | Remove the `?? (try? JSONEncoder().encode(frame.payload))` fallback entirely; require `rawData` |
| P1 | NEW-1: main thread delegate queue | Change `delegateQueue: .main` to `delegateQueue: nil` (creates serial OperationQueue) |
| P2 | F6/F6: Swift 6 violations | Add `@unchecked Sendable` to callbacks; replace `DispatchSourceTimer` with `Task.sleep` |
| P2 | Tests not added | Add at minimum `testHelloOkParsingFromRawJSON` and `testDeleteAllKeychain` with read-back verification |

---

**Estimated fix scope for remaining items:** 2–3 hours.

The foundation is now solid enough that Component 3 CAN begin parallel work on non-event-stream parts of the sync bridge. But the `eventContinuation` hang bug must be fixed before the sync bridge's event consumption pipeline is integrated.
