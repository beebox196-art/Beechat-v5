# BeeChatGateway — Component 2 Specification

**Date:** 2026-04-17  
**Phase:** Build Phase 2  
**Predecessor:** Component 1 (Persistence) — ✅ Complete, reviewed, verified  
**Exit Criteria:** Can connect to OpenClaw gateway, complete handshake, receive events, call RPC methods, auto-reconnect

---

## Overview

BeeChatGateway is a Swift package providing the WebSocket transport layer for BeeChat v5. It connects to the OpenClaw Gateway (Protocol v3), handles the `connect.challenge` → `connect` → `hello-ok` handshake, manages request/response correlation, event streaming, and reconnect with bounded exponential backoff.

**Critical design rule:** The gateway owns session state. BeeChatGateway is a transport and protocol layer — it does NOT store messages, manage UI state, or make business decisions.

**Architecture source:** Adapted from ClawChat's `gateway-client.ts` (MIT, ngmaloney/clawchat). Ported to native Swift with Swift Concurrency.

---

## Architecture

```
BeeChatGateway (Swift Package)
├── Sources/
│   └── BeeChatGateway/
│       ├── GatewayClient.swift           — Main client: connect, disconnect, call, event stream
│       ├── ConnectionState.swift          — State machine enum
│       ├── Protocol/                      — Protocol DTOs
│       │   ├── Frame.swift                — Request, Response, Event frame types
│       │   ├── ConnectParams.swift         — Connect handshake parameters
│       │   ├── HelloOk.swift              — hello-ok response model
│       │   └── GatewayEvent.swift         — Event types (chat, agent, tick, etc.)
│       ├── Transport/
│       │   └── WebSocketTransport.swift   — URLSessionWebSocketTask wrapper
│       ├── Auth/
│       │   ├── DeviceIdentity.swift       — Device identity model
│       │   ├── DeviceCrypto.swift         — Key generation, signing, device ID derivation
│       │   └── TokenStore.swift           — Keychain-backed token persistence
│       └── Internal/
│           ├── PendingRequestMap.swift    — Request ID → promise correlation
│           └── BackoffCalculator.swift    — Exponential backoff with jitter
├── Tests/
│   └── BeeChatGatewayTests/
│       ├── GatewayClientTests.swift
│       ├── ConnectionStateTests.swift
│       ├── FrameTests.swift
│       ├── PendingRequestMapTests.swift
│       ├── BackoffCalculatorTests.swift
│       └── DeviceCryptoTests.swift
└── Package.swift
```

---

## Connection State Machine

```swift
public enum ConnectionState: String, Sendable {
    case disconnected    // Initial state or after disconnect()
    case connecting      // WebSocket connecting (before open)
    case handshaking     // WS open, waiting for challenge or sending connect
    case connected       // hello-ok received, ready for RPC/events
    case error           // Fatal error or max retries exceeded
}
```

Transitions:
- `disconnected` → `connecting` (on `connect()` called)
- `connecting` → `handshaking` (on WS `onopen`)
- `handshaking` → `connected` (on `hello-ok` received)
- `handshaking` → `error` (on handshake timeout or rejection)
- Any state → `disconnected` (on `disconnect()` called)
- `connected`/`handshaking`/`connecting` → `connecting` (on non-fatal close, triggers reconnect)
- Any state → `error` (on fatal close code: 1008, 4xxx)

---

## Protocol Frame Types

### Frame (base)
```swift
enum FrameType: String, Codable {
    case req  = "req"
    case res  = "res"
    case event = "event"
}
```

### RequestFrame
```swift
struct RequestFrame: Encodable {
    let type: String = "req"
    let id: String
    let method: String
    let params: [String: AnyCodable]?
}
```

### ResponseFrame
```swift
struct ResponseFrame: Decodable {
    let type: String  // "res"
    let id: String
    let ok: Bool
    let payload: [String: AnyCodable]?
    let error: ResponseError?
}

struct ResponseError: Decodable {
    let message: String
    let code: String?
}
```

### EventFrame
```swift
struct EventFrame: Decodable {
    let type: String  // "event"
    let event: String
    let payload: [String: AnyCodable]?
    let seq: Int?
    let stateVersion: Int?
}
```

---

## Connect Handshake

### 1. Open WebSocket
- URL: gateway URL with `?token=<gatewayToken>` query param
- Use `URLSessionWebSocketTask` (native Swift, no third-party dependency)

### 2. Receive `connect.challenge`
```json
{ "type": "event", "event": "connect.challenge", "payload": { "nonce": "...", "ts": 1737264000000 } }
```
- Capture `nonce` for device signing

### 3. Send `connect` request

**Critical rules from ClawChat research:**
- Only send `device` field when a `deviceToken` already exists
- `signedAt` must be **current time**, not challenge timestamp
- Device signature payload includes: deviceId, clientId, clientMode, role, scopes, signedAtMs, token (or null), nonce

```swift
struct ConnectParams: Encodable {
    let minProtocol: Int = 3
    let maxProtocol: Int = 3
    let client: ClientInfo
    let role: String
    let scopes: [String]
    let caps: [String]?
    let commands: [String]?
    let permissions: [String: Bool]?
    let auth: AuthInfo
    let locale: String?
    let userAgent: String?
    let device: DeviceIdentity?
}

struct ClientInfo: Encodable {
    let id: String       // "beechat"
    let version: String  // app version
    let platform: String // "macos"
    let mode: String     // "operator"
}

struct AuthInfo: Encodable {
    let token: String
    let deviceToken: String?
}
```

### 4. Receive `hello-ok`
```swift
struct HelloOk: Decodable {
    let type: String  // "hello-ok"
    let protocol: Int
    let server: ServerInfo
    let features: Features
    let snapshot: [String: AnyCodable]?
    let policy: Policy
    let auth: AuthResult?
}

struct Policy: Decodable {
    let maxPayload: Int
    let maxBufferedBytes: Int?
    let tickIntervalMs: Int?
}

struct AuthResult: Decodable {
    let deviceToken: String?
    let role: String?
    let scopes: [String]?
}
```

- **Persist `deviceToken`** from `hello-ok.auth` to Keychain via `TokenStore`
- **Capture `maxPayload`** from `hello-ok.policy` for outbound size limits
- **Transition to `connected`**

---

## GatewayClient Public API

```swift
public actor GatewayClient {
    // Configuration
    public struct Configuration: Sendable {
        public let url: String
        public let token: String
        public let deviceToken: String?
        public let clientInfo: ClientInfo
        public let requestTimeout: TimeInterval  // default 30s
        public let maxRetries: Int               // default 10
        public let baseRetryDelay: TimeInterval   // default 1s
        public let maxRetryDelay: TimeInterval    // default 30s
    }
    
    // Lifecycle
    public init(config: Configuration)
    public func connect() async
    public func disconnect() async
    
    // RPC
    public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable]
    
    // Events — AsyncStream
    public func eventStream() -> AsyncStream<(event: String, payload: [String: AnyCodable]?)>
    
    // State
    public var connectionState: ConnectionState { get }
    public var maxPayload: Int { get }
    
    // Delegate callbacks
    public var onStatusChange: ((ConnectionState) -> Void)? { get set }
    public var onDeviceToken: ((String) -> Void)? { get set }
}
```

### Key behaviors:
- `call()` throws if not connected (except for `connect` method during handshake)
- `call()` generates unique request IDs (`bc-<incrementing>`)
- `call()` times out after `requestTimeout` (default 30s)
- Events are delivered via `AsyncStream` — consumers iterate asynchronously
- `disconnect()` is intentional — no reconnect triggered
- Non-fatal WS close triggers automatic reconnect with backoff
- Fatal close codes (1008, 4xxx) transition to `error` state — no reconnect

---

## Device Identity & Crypto

Ported from ClawChat's `device-crypto.ts`, adapted for Swift CryptoKit.

### Key Generation & Storage
- Generate Ed25519 keypair using `Security.SecKeyCreateRandomKey`
- Store in macOS Keychain with tag `com.beechat.device-identity`
- Derive `deviceId` from SHA-256 hash of public key raw bytes, hex-encoded
- Export `publicKey` as base64-encoded raw bytes for transport

### Challenge Signing
```swift
struct DeviceCrypto {
    /// Get or create the persistent Ed25519 keypair from Keychain
    static func getOrCreateKeyPair() throws -> SecKey
    
    /// Derive device ID from public key
    static func getDeviceId(_ key: SecKey) throws -> String
    
    /// Export public key as base64 raw bytes
    static func exportPublicKey(_ key: SecKey) throws -> String
    
    /// Sign the challenge payload
    static func signChallenge(
        _ key: SecKey,
        deviceId: String,
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int,
        token: String?,
        nonce: String
    ) throws -> String
}
```

### Signature Payload
The signature is over a canonical JSON string of:
```json
{
  "deviceId": "...",
  "clientId": "beechat",
  "clientMode": "operator",
  "role": "operator",
  "scopes": ["operator.read", "operator.write"],
  "signedAtMs": 1737264000000,
  "token": null,
  "nonce": "..."
}
```

---

## Token Persistence (TokenStore)

```swift
public protocol TokenStore: Sendable {
    func getGatewayToken() throws -> String?
    func setGatewayToken(_ token: String) throws
    func getDeviceToken() throws -> String?
    func setDeviceToken(_ token: String) throws
    func deleteAll() throws
}

/// Keychain-backed implementation
public final class KeychainTokenStore: TokenStore {
    // Uses Security framework
    // Service: "com.beechat.tokens"
    // Account: "gatewayToken" / "deviceToken"
}
```

---

## Reconnect & Backoff

```swift
struct BackoffCalculator {
    let baseDelay: TimeInterval     // 1 second
    let maxDelay: TimeInterval       // 30 seconds
    let maxRetries: Int              // 10
    
    func delay(forAttempt attempt: Int) -> TimeInterval {
        // Exponential: base * 2^attempt, capped at maxDelay
        // Add random jitter ±20%
        let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
        let jitter = exponential * 0.2 * Double.random(in: -1...1)
        return exponential + jitter
    }
}
```

### Reconnect rules:
- Only reconnect on **non-fatal** close codes
- Fatal codes: 1008 (policy violation), 4xxx (application-specific)
- Reset retry counter on successful `hello-ok`
- On max retries exceeded, transition to `error` state

---

## WebSocket Transport

```swift
class WebSocketTransport {
    private var task: URLSessionWebSocketTask?
    
    func connect(url: URL) async throws -> AsyncThrowingStream<String, Error>
    func send(_ message: String) async throws
    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
```

Uses `URLSessionWebSocketTask` — no third-party WebSocket dependency.

---

## AnyCodable Helper

Needed for dynamic JSON payloads. Implement a minimal `AnyCodable` that supports:
- Encodable/Decodable passthrough for `[String: AnyCodable]`
- JSONSerialization fallback for unstructured data

Include as `AnyCodable.swift` in the package.

---

## Exit Criteria (MUST ALL PASS)

1. ✅ GatewayClient connects to WebSocket URL with token
2. ✅ Connection state transitions: disconnected → connecting → handshaking → connected
3. ✅ `connect.challenge` received and nonce captured
4. ✅ `connect` request sent with correct protocol v3 params
5. ✅ `hello-ok` response parsed, deviceToken persisted to Keychain
6. ✅ `call(method:params:)` sends request and receives response
7. ✅ Request IDs are unique and correlated correctly
8. ✅ Request timeout works (pending request rejected after 30s)
9. ✅ Event stream delivers events to AsyncStream consumers
10. ✅ Reconnect with exponential backoff on non-fatal close
11. ✅ Fatal close codes (1008, 4xxx) transition to error state, no reconnect
12. ✅ `disconnect()` is intentional — no reconnect triggered
13. ✅ Device identity generated and persisted to Keychain
14. ✅ Challenge signing produces valid Ed25519 signature
15. ✅ Device token stored and retrieved from Keychain
16. ✅ All unit tests pass
17. ✅ `swift build` succeeds
18. ✅ `swift test` succeeds

---

## Build Instructions

Swift Package Manager project alongside BeeChatPersistence:

```bash
mkdir -p BeeChat-v5/Sources/BeeChatGateway
mkdir -p BeeChat-v5/Tests/BeeChatGatewayTests
```

Package.swift should declare a second library target `BeeChatGateway` with:
- Platform: macOS 14.0+
- No external dependencies (URLSessionWebSocketTask is native, CryptoKit is native, Security framework is native)
- Products: `BeeChatGateway` library

---

## Integration with Component 1

BeeChatGateway does NOT directly import BeeChatPersistence. They are separate packages.

Integration happens in Component 3 (Sync Bridge), which:
- Subscribes to `GatewayClient.eventStream()`
- Routes events to `GatewayEventConsumer` (from BeeChatPersistence)
- Calls `GatewayClient.call("sessions.list")` → upserts to local DB
- Calls `GatewayClient.call("chat.history")` → upserts messages to local DB

---

## Attribution

- `gateway-client.ts` patterns adapted from ClawChat (`ngmaloney/clawchat`, MIT)
- `device-crypto.ts` signing logic adapted from ClawChat (`ngmaloney/clawchat`, MIT)
- Protocol v3 specification from OpenClaw docs (https://docs.openclaw.ai/gateway/protocol)
- No external WebSocket library — native `URLSessionWebSocketTask`

---

*This spec is the contract for Component 2. The coder MUST deliver all exit criteria before Component 3 begins.*