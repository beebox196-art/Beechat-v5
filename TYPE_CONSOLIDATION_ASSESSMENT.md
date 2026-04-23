# Type Consolidation Assessment — BeeChat v5

## Inventory of Types by Module

### BeeChatGateway (18 types)
| Type | Kind | File |
|------|------|------|
| `AnyCodable` | struct | AnyCodable.swift |
| `DeviceCrypto` | enum (static-only) | Auth/DeviceCrypto.swift |
| `DeviceIdentity` | struct | Auth/DeviceIdentity.swift |
| `DeviceCryptoError` | enum | Auth/DeviceCrypto.swift |
| `TokenStore` | protocol | Auth/TokenStore.swift |
| `KeychainTokenStore` | class | Auth/TokenStore.swift |
| `ConnectionState` | enum | ConnectionState.swift |
| `GatewayClient` | actor | GatewayClient.swift |
| `GatewayClient.Configuration` | struct | GatewayClient.swift |
| `BackoffCalculator` | struct | Internal/BackoffCalculator.swift |
| `PendingRequestMap` | actor | Internal/PendingRequestMap.swift |
| `ConnectParams` | struct | Protocol/ConnectParams.swift |
| `ConnectParams.ClientInfo` | struct | Protocol/ConnectParams.swift |
| `ConnectParams.AuthInfo` | struct | Protocol/ConnectParams.swift |
| `ConnectParams.DeviceIdentity` | struct | Protocol/ConnectParams.swift |
| `HelloOk` | struct | Protocol/ConnectParams.swift |
| `HelloOk.ServerInfo` | struct | Protocol/ConnectParams.swift |
| `HelloOk.Features` | struct | Protocol/ConnectParams.swift |
| `HelloOk.Policy` | struct | Protocol/ConnectParams.swift |
| `HelloOk.AuthResult` | struct | Protocol/ConnectParams.swift |
| `FrameType` | enum | Protocol/Frame.swift |
| `RequestFrame` | struct | Protocol/Frame.swift |
| `ResponseFrame` | struct | Protocol/Frame.swift |
| `ResponseFrame.ResponseError` | struct | Protocol/Frame.swift |
| `EventFrame` | struct | Protocol/Frame.swift |
| `GatewayEvent` | enum | Protocol/GatewayEvent.swift |
| `WebSocketTransport` | class | Transport/WebSocketTransport.swift |

### BeeChatPersistence (15 types)
| Type | Kind | File |
|------|------|------|
| `MessageStore` | protocol | Protocols/MessageStore.swift |
| `GatewayEventConsumer` | protocol | Protocols/MessageStore.swift |
| `BeeChatPersistenceStore` | class | BeeChatPersistenceStore.swift |
| `DatabaseManager` | class | Database/DatabaseManager.swift |
| `DatabaseManagerError` | enum | Database/DatabaseManager.swift |
| `Attachment` | struct | Models/Attachment.swift |
| `Message` | struct | Models/Message.swift |
| `MessageBlock` | struct | Models/MessageBlock.swift |
| `MessageBlock.BlockType` | enum | Models/MessageBlock.swift |
| `Session` | struct | Models/Session.swift |
| `Topic` | struct | Models/Topic.swift |
| `TopicSessionBridge` | struct | Models/Topic.swift |
| `AttachmentRepository` | class | Repositories/AttachmentRepository.swift |
| `MessageRepository` | class | Repositories/MessageRepository.swift |
| `SessionRepository` | class | Repositories/SessionRepository.swift |
| `TopicRepository` | class | Repositories/TopicRepository.swift |

### BeeChatSyncBridge (22 types)
| Type | Kind | File |
|------|------|------|
| `SyncBridgeDelegate` | protocol | Protocols/SyncBridgeDelegate.swift |
| `SyncBridgeConfiguration` | struct | Protocols/SyncBridgeConfiguration.swift |
| `EventRouter` | struct | EventRouter.swift |
| `AgentEventPayload` | struct | Models/AgentEvent.swift |
| `AgentEventData` | struct | Models/AgentEvent.swift |
| `ChatEventPayload` | struct | Models/AgentEvent.swift |
| `ChatEventMessage` | struct | Models/AgentEvent.swift |
| `ChatEventContent` | enum | Models/AgentEvent.swift |
| `ChatEventContentBlock` | struct | Models/AgentEvent.swift |
| `ChatMessagePayload` | struct | Models/ChatMessage.swift |
| `DeliveryLedgerEntry` | struct | Models/DeliveryLedgerEntry.swift |
| `DeliveryLedgerEntry.DeliveryStatus` | enum | Models/DeliveryLedgerEntry.swift |
| `HealthEventPayload` | struct | Models/HealthEvent.swift |
| `HealthEventPayload.HealthChannelStatus` | struct | Models/HealthEvent.swift |
| `HealthEventPayload.HealthAgentStatus` | struct | Models/HealthEvent.swift |
| `HealthEventPayload.HealthSessionStatus` | struct | Models/HealthEvent.swift |
| `SessionInfo` | struct | Models/SessionInfo.swift |
| `MessageObserver` | struct | Observation/MessageObserver.swift |
| `SessionObserver` | struct | Observation/SessionObserver.swift |
| `DeliveryLedgerRepository` | struct | Persistence/DeliveryLedgerRepository.swift |
| `Migration003_DeliveryLedger` | struct | Persistence/Migration003_DeliveryLedger.swift |
| `RPCClientProtocol` | protocol | RPCClient.swift |
| `RPCClient` | struct | RPCClient.swift |
| `Reconciler` | struct | Reconciler.swift |
| `SyncBridge` | actor | SyncBridge.swift |

### BeeChatApp (24 types)
| Type | Kind | File |
|------|------|------|
| `AppDebugLog` | class | AppDebugLog.swift |
| `AppRootView` | struct | AppRootView.swift |
| `Composer` | struct | UI/Components/Composer.swift |
| `GatewayStatusBar` | struct | UI/Components/GatewayStatusBar.swift |
| `MacTextView` | struct | UI/Components/MacTextView.swift |
| `MessageBubble` | struct | UI/Components/MessageBubble.swift |
| `MessageCanvas` | struct | UI/Components/MessageCanvas.swift |
| `MessageContent` | struct | UI/Components/MessageContent.swift |
| `SessionRow` | struct | UI/Components/SessionRow.swift |
| `StreamingBubble` | struct | UI/Components/StreamingBubble.swift |
| `TypingIndicator` | struct | UI/Components/TypingIndicator.swift |
| `MainWindow` | struct | UI/MainWindow.swift |
| `MessageListObserver` | class | UI/Observers/MessageListObserver.swift |
| `SessionListObserver` | class | UI/Observers/SessionListObserver.swift |
| `SyncBridgeObserver` | class | UI/Observers/SyncBridgeObserver.swift |
| `Theme` | struct | UI/Theme/Theme.swift |
| `ThemeManager` | class | UI/Theme/ThemeManager.swift |
| `ThemeMetadata` | struct | UI/Theme/ThemeMetadata.swift |
| `AnimationToken` | enum | UI/Theme/Tokens/AnimationToken.swift |
| `ColorToken` | enum | UI/Theme/Tokens/ColorToken.swift |
| `RadiusToken` | enum | UI/Theme/Tokens/RadiusToken.swift |
| `ShadowDefinition` | struct | UI/Theme/Tokens/ShadowToken.swift |
| `ShadowToken` | enum | UI/Theme/Tokens/ShadowToken.swift |
| `SpacingToken` | enum | UI/Theme/Tokens/SpacingToken.swift |
| `TypographyToken` | enum | UI/Theme/Tokens/TypographyToken.swift |
| `ComposerViewModel` | class | UI/ViewModels/ComposerViewModel.swift |
| `MessageViewModel` | class | UI/ViewModels/MessageViewModel.swift |
| `TopicViewModel` | struct | UI/ViewModels/TopicViewModel.swift |

## Consolidation Issues Found

### 1. DUPLICATE: `DeviceIdentity` (HIGH CONFIDENCE)
**Problem:** Two identical structs exist:
- `BeeChatGateway/Auth/DeviceIdentity.swift` → `public struct DeviceIdentity` (UNUSED)
- `BeeChatGateway/Protocol/ConnectParams.swift` → `ConnectParams.DeviceIdentity` (used in GatewayClient.swift)

GatewayClient.swift exclusively uses `ConnectParams.DeviceIdentity`. The standalone `DeviceIdentity` in Auth/ is never imported or referenced.

**Action:** Delete `Auth/DeviceIdentity.swift`.

### 2. DEAD CODE: `Migration003_DeliveryLedger` (HIGH CONFIDENCE)
**Problem:** `BeeChatSyncBridge/Persistence/Migration003_DeliveryLedger.swift` defines a struct with a static `apply(db:)` method that is NEVER called anywhere. The delivery_ledger migration is already handled by `Migration004_CreateDeliveryLedger` inside `DatabaseManager.migrate()`.

**Action:** Delete `Persistence/Migration003_DeliveryLedger.swift`.

### 3. UNUSED PROTOCOL: `GatewayEventConsumer` (HIGH CONFIDENCE)
**Problem:** `GatewayEventConsumer` protocol is implemented by `BeeChatPersistenceStore` but never used as a type anywhere. No variable, parameter, or return type references it. It's a vestigial interface.

**Action:** Remove protocol and conformance.

### 4. UNUSED TYPES: `ChatEventPayload`, `ChatEventMessage`, `ChatEventContent`, `ChatEventContentBlock` (HIGH CONFIDENCE)
**Problem:** These 4 types in `Models/AgentEvent.swift` are never referenced anywhere outside their definition file. EventRouter manually parses chat events from `[String: AnyCodable]` instead of using these structured types.

**Action:** Remove these 4 types. Keep `AgentEventPayload` and `AgentEventData` (used by EventRouter and SyncBridge).

### 5. UNUSED TYPES: `HealthEventPayload` and nested types (HIGH CONFIDENCE)
**Problem:** `HealthEventPayload` and its 3 nested types (`HealthChannelStatus`, `HealthAgentStatus`, `HealthSessionStatus`) are never referenced anywhere. The `handleHealthEvent` method in EventRouter is a no-op.

**Action:** Delete `Models/HealthEvent.swift`.

### 6. QUESTIONABLE: `MessageStore` protocol (MEDIUM CONFIDENCE — leave for now)
**Problem:** `MessageStore` is only implemented by `BeeChatPersistenceStore` and never used as a type. The App layer bypasses it entirely, calling `TopicRepository` and `DatabaseManager` directly. However, it provides useful abstraction for testing, so leaving it is safer.

### 7. NAMING INCONSISTENCY: `MessageObserver` vs `MessageListObserver` (LOW PRIORITY)
**Problem:** `BeeChatSyncBridge/Observation/MessageObserver` wraps GRDB observations. `App/UI/Observers/MessageListObserver` wraps the SyncBridge observer for SwiftUI. The naming is confusing but they serve different layers.

## Summary of Actions (COMPLETED)
| # | Action | Status | Impact |
|---|--------|--------|--------|
| 1 | Delete `Auth/DeviceIdentity.swift` | ✅ DONE | Removed 1 unused duplicate type |
| 2 | Delete `Persistence/Migration003_DeliveryLedger.swift` | ✅ DONE | Removed 1 dead type |
| 3 | Remove `GatewayEventConsumer` protocol | ✅ DONE | Removed 1 unused protocol + 4 methods + conformance |
| 4 | Remove 4 unused ChatEvent types | ✅ DONE | Removed `ChatEventPayload`, `ChatEventMessage`, `ChatEventContent`, `ChatEventContentBlock` |
| 5 | Delete `Models/HealthEvent.swift` | ✅ DONE | Removed `HealthEventPayload` + 3 nested types |

**Total: Removed 11 unused/duplicate types across 3 deleted files + 3 edited files.**

## Build Verification
- ✅ `swift build` completes successfully with 0 errors
- Pre-existing warnings remain (Sendable, preconcurrency, unused results) — unrelated to consolidation
- 65 Swift source files remain (down from 68)

## Remaining Items (Not Consolidated)
| Item | Reason |
|------|--------|
| `MessageStore` protocol | Only implemented by `BeeChatPersistenceStore`, but provides useful abstraction for testing. App layer bypasses it but that's an architectural issue, not a type duplication. |
| `RPCClientProtocol` | Used by `Reconciler` for dependency injection — good design. |
| `MessageObserver`/`MessageListObserver` naming | Different layers (SyncBridge vs App), different purposes. Naming is confusing but not a duplication. |
| App layer bypassing `MessageStore` | Architectural concern — App calls `TopicRepository` and `DatabaseManager` directly. Out of scope for type consolidation. |
