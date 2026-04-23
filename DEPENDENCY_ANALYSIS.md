# BeeChat v5 — Dependency Graph Analysis

## Module Structure (from Package.swift)

```
BeeChatPersistence ──→ GRDB
BeeChatGateway     ──→ (no internal deps)
BeeChatSyncBridge  ──→ GRDB, BeeChatPersistence, BeeChatGateway
BeeChatApp         ──→ BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge
```

## Import Dependency Map (from source files)

### BeeChatPersistence
- Imports: Foundation, GRDB
- **No internal module imports** ✅
- Provides: Models (Message, Session, Topic, Attachment), Repositories, BeeChatPersistenceStore, MessageStore protocol

### BeeChatGateway
- Imports: Foundation, CryptoKit, Security
- **No internal module imports** ✅
- Provides: GatewayClient, ConnectionState, AnyCodable, Frame types, ConnectParams/HelloOk, WebSocket transport

### BeeChatSyncBridge
- Imports: Foundation, GRDB, BeeChatGateway, BeeChatPersistence
- **Depends on both leaf modules** (as designed)
- Provides: SyncBridge (main coordinator), RPCClient, EventRouter, Reconciler, Observers, DeliveryLedgerRepository

### BeeChatApp
- Imports: BeeChatSyncBridge, BeeChatPersistence, BeeChatGateway
- **Top-level consumer** of all three library modules

## Dependency Graph (Directed Acyclic Graph)

```
                    ┌─────────────────┐
                    │   BeeChatApp    │  (executable)
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

No module imports a module that transitively imports it. There are zero circular chains.

## Architectural Observations

### Strengths
- **Clean layered architecture**: Leaf → Bridge → App follows a standard dependency inversion pattern
- **Protocol-based decoupling**: `MessageStore` protocol in Persistence, `RPCClientProtocol` in SyncBridge
- **SyncBridgeDelegate protocol**: Decouples SyncBridge from its consumers (App layer)
- **SessionKeyNormalizer**: Shared utility extracted to avoid duplication

### Minor Concerns (not blocking)
1. **SessionKeyNormalizer duplication**: `SyncBridge.isBeeChatSession()` and `Reconciler.isBeeChatSession()` duplicate logic that exists in `SessionKeyNormalizer`. The normalizer should be the single source of truth.
2. **GRDB re-import in SyncBridge**: `MessageObserver`, `SessionObserver`, and `DeliveryLedgerRepository` import both GRDB and BeeChatPersistence. Since they use `DatabaseManager` directly (which is internal to Persistence), this is a design smell — they should use the public `MessageStore` protocol instead of reaching into the DB layer.
3. **DatabaseManager.shared singleton**: SyncBridge modules bypass the `MessageStore` protocol and access `DatabaseManager.shared` directly, creating a hidden dependency path that isn't visible in the module graph.

### No Refactoring Required for Circular Dependencies
Since there are no circular dependencies, no untangling is needed. The architecture is sound.

## Build Verification

### Build Status: ✅ PASS (clean build, 0 errors)

```
$ swift build
Build complete! (14.73s)
```

### Build Fixes Applied
The following missing theme token types were created to fix build errors in the App module:
- `Sources/App/UI/Theme/Tokens/SpacingToken.swift` — semantic spacing tokens (2px–48px)
- `Sources/App/UI/Theme/Tokens/RadiusToken.swift` — corner radius tokens (0–full)
- `Sources/App/UI/Theme/Tokens/ShadowToken.swift` — `ShadowDefinition` struct + `ShadowToken` enum
- `Sources/App/UI/Theme/Tokens/AnimationToken.swift` — animation duration tokens (0–0.8s)

These were referenced in `ThemeManager.swift` but never defined. No dependency-related build issues were found.

### Warnings (non-blocking)
Several `try? await` calls in SyncBridge produce "result of try? is unused" warnings. These are intentional fire-and-forget patterns for best-effort history fetches and are not errors.
