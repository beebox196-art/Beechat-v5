# BeeChat v5 — Dependency Graph Analysis

**Last Updated:** 2026-04-23  
**Analyst:** Bee (subagent: beechat-deps)

## Module Structure (from Package.swift)

```
BeeChatPersistence ──→ GRDB
BeeChatGateway     ──→ (no internal deps)
BeeChatSyncBridge  ──→ GRDB, BeeChatPersistence, BeeChatGateway
BeeChatApp         ──→ BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge
BeeChatIntegrationTest ──→ BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge
```

## Import Dependency Map (from source files)

### BeeChatPersistence
- Imports: Foundation, GRDB
- **No internal module imports** ✅
- Provides: Models (Message, Session, Topic, Attachment), Repositories, BeeChatPersistenceStore, DatabaseManager

### BeeChatGateway
- Imports: Foundation, CryptoKit, Security
- **No internal module imports** ✅
- Provides: GatewayClient, ConnectionState, AnyCodable, Frame types, ConnectParams/HelloOk, WebSocket transport

### BeeChatSyncBridge
- Imports: Foundation, GRDB, BeeChatGateway, BeeChatPersistence
- **Depends on both leaf modules** (as designed)
- Provides: SyncBridge (main coordinator), RPCClient, EventRouter, Reconciler, DeliveryLedgerRepository

### BeeChatApp
- Imports: SwiftUI, BeeChatSyncBridge, BeeChatPersistence, BeeChatGateway, GRDB, os
- **Top-level consumer** of all three library modules

### BeeChatIntegrationTest
- Imports: Foundation, BeeChatGateway, BeeChatPersistence, BeeChatSyncBridge
- **Top-level consumer** of all three library modules

## Dependency Graph (Directed Acyclic Graph)

```
                    ┌─────────────────┐
                    │   BeeChatApp    │  (executable)
                    │BeeChatIntegrationTest│
                    └────┬─────┬──────┘
                         │     │
                         ▼     ▼
              ┌──────────────────────┐
              │  BeeChatSyncBridge   │
              └────┬──────────┬──────┘
                   │          │
                   ▼          ▼
    ┌──────────────────┐ ┌──────────────┐
    │BeeChatPersistence│ │BeeChatGateway│
    │      (GRDB)      │ │  (CryptoKit) │
    └──────────────────┘ └──────────────┘
```

## Circular Dependency Assessment

### ✅ NO CIRCULAR DEPENDENCIES FOUND

The dependency graph is a clean DAG:
1. **BeeChatPersistence** — leaf module, depends only on GRDB
2. **BeeChatGateway** — leaf module, depends only on system frameworks
3. **BeeChatSyncBridge** — middle layer, depends on both leaf modules
4. **BeeChatApp** — top layer, depends on all three

No module imports a module that transitively imports it. There are zero circular chains. No untangling is needed.

## Architectural Concerns (Not Blocking, But Worth Addressing)

### 1. DatabaseManager Singleton Bypass (Design Smell)
**Severity:** Medium  
**Location:** SyncBridge → `DatabaseManager.shared`

`DeliveryLedgerRepository` and `SyncBridge.messageStream()` both access `DatabaseManager.shared` directly, bypassing the `BeeChatPersistenceStore` abstraction. This creates a hidden dependency path:

```
SyncBridge → DatabaseManager.shared (internal to Persistence)
```

While not a circular dependency, it means SyncBridge has two paths into Persistence:
- **Public:** `BeeChatPersistenceStore` (via protocol/config)
- **Hidden:** `DatabaseManager.shared` (singleton)

**Recommendation:** Either (a) expose `DatabaseManager` as a public API of BeeChatPersistence, or (b) add delivery ledger methods to `BeeChatPersistenceStore` so SyncBridge uses only the public path.

### 2. GRDB Re-import in SyncBridge
**Severity:** Low  
**Location:** SyncBridge/Persistence/DeliveryLedgerRepository.swift, SyncBridge/SyncBridge.swift

SyncBridge imports GRDB directly and executes raw SQL. This is acceptable for the delivery ledger (which is SyncBridge-specific), but `SyncBridge.messageStream()` also uses GRDB's `ValueObservation` directly against `DatabaseManager.shared.writer`. This couples SyncBridge to GRDB's observation API.

**Recommendation:** Consider adding an observation API to `BeeChatPersistenceStore` (e.g., `observeMessages(sessionId:changes:)`) so the UI layer can observe DB changes without importing GRDB in SyncBridge.

### 3. Duplicated Session Key Logic
**Severity:** Low  
**Location:** SyncBridge.swift, Reconciler.swift

`isBeeChatSession()` and `normalizeSessionKey()` are duplicated between `SyncBridge` and `Reconciler`. Both use `TopicRepository` directly.

**Recommendation:** Extract a `SessionKeyNormalizer` struct into a shared location (or into BeeChatPersistence) and have both use it.

## Build Verification

### Build Status: ✅ PASS (clean build, 0 errors)

```
$ swift build
Build complete! (0.86s)
```

### Build Fixes Applied (2026-04-23)

1. **GatewayClient.swift** — Fixed 6 unhandled `try` errors in `resolveHandshake`:
   - Attempt 1 (rawData decode): replaced `try` chain with `flatMap` + `try?`
   - Attempt 2 (AnyCodable round-trip): replaced `try` chain with `flatMap` + `try?`
   - `tokenStore.setDeviceToken()`: changed `try` to `try?` (best-effort keychain write)

2. **AppRootView.swift** — Fixed 1 unhandled `try` error in `defaultDatabasePath()`:
   - `FileManager.default.createDirectory()`: changed `try` to `try?`

### Warnings (non-blocking)
- `AnyCodable.swift:5` — `value` property of Sendable-conforming struct has non-Sendable type `Any`; this is an error in Swift 6 language mode. Known limitation of the type-erasure pattern.
