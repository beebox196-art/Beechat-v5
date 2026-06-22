# FEAT-004: Session Reset with Summary Injection

**Priority:** High  
**Status:** Spec — awaiting review  
**Author:** Bee (Coordinator)  
**Date:** 2026-04-25

## Problem

Topics accumulate messages over time, causing sluggishness. The traffic light indicators (🟢🟡🔴) show when a topic is bloated (>150 messages), but there's no way to reset it while preserving conversation context. The AI loses all prior context when a new session starts.

## Goal

When a topic is red (>150 messages), the user can tap the red dot to reset the session. The system:
1. Fetches the conversation history
2. Generates a summary
3. Creates a new session
4. Injects the summary as the first message so the AI has context continuity

## Architecture

**Modular approach — zero changes to core working code.**

All new code lives in new files/modules. Existing `SyncBridge`, `MessageViewModel`, `TopicRepository`, and database models are untouched. The feature can be backed out by removing new files only.

### Component 1: `SessionResetManager` (new actor)

Location: `Sources/BeeChatSyncBridge/SessionResetManager.swift`

Actor that orchestrates the reset flow:

```swift
@MainActor
public actor SessionResetManager {
    /// Generate a summary from the conversation history
    func generateSummary(sessionKey: String, syncBridge: SyncBridge) async throws -> String
    
    /// Reset a topic: create new session, inject summary, update topic
    func resetTopic(topicId: String, summary: String, syncBridge: SyncBridge, topicRepo: TopicRepository) async throws -> String
}
```

**generateSummary:**
1. Fetch conversation history via `syncBridge.fetchHistory(sessionKey:limit:)`
2. Construct a summary prompt:
   ```
   Summarise the following conversation in 3-5 bullet points covering key decisions, context, and outstanding items:
   
   [user]: message text
   [assistant]: message text
   ...
   ```
3. Send via `syncBridge.sendMessage(sessionKey:text:)` with a special marker
4. Capture the AI's summary response
5. Return the summary text

**resetTopic:**
1. Generate a new UUID for the new session key
2. Send the summary as the first message to the new session (this creates it)
3. Update the topic's `sessionKey` to the new value
4. Update the `TopicSessionBridge` record
5. Return the new session key

### Component 2: `SessionResetSheet` (new SwiftUI view)

Location: `Sources/App/UI/Components/SessionResetSheet.swift`

Bottom sheet that appears when the user taps a red health dot:

```
┌─────────────────────────────────┐
│  🔄 Reset Session               │
│                                 │
│  This topic has 247 messages.   │
│  Resetting will:                │
│  • Create a summary of this     │
│    conversation                 │
│  • Start a fresh session        │
│  • Inject the summary so the    │
│    AI remembers context         │
│                                 │
│  [Cancel]          [Reset Now]  │
└─────────────────────────────────┘
```

After reset completes, show:
```
┌─────────────────────────────────┐
│  ✅ Session Reset               │
│                                 │
│  Summary:                       │
│  • User requested X...          │
│  • AI suggested Y...            │
│  • Decision made: Z...          │
│                                 │
│  [Done]                         │
└─────────────────────────────────┘
```

### Component 3: `SessionRow` tap handler (minimal change)

Location: `Sources/App/UI/Components/SessionRow.swift`

Add a tap gesture to the red health dot when `messageCount > 150`:

```swift
Circle()
    .fill(healthColor)
    .frame(width: 8, height: 8)
    .onTapGesture {
        if topic.messageCount > 150 {
            showResetSheet = true
        }
    }
```

**This is the ONLY change to an existing file.** All other code is new.

### Component 4: `SessionResetRecord` model (new table)

Location: `Sources/BeeChatPersistence/Models/SessionResetRecord.swift`

Track reset history per topic:

```swift
public struct SessionResetRecord: Codable, UpsertableRecord {
    public let id: String          // UUID
    public let topicId: String
    public let oldSessionKey: String
    public let newSessionKey: String
    public let summary: String
    public let resetAt: Date
}
```

**Migration008:** Add `session_resets` table.

## Data Flow

```
User taps red dot
    ↓
SessionResetSheet appears
    ↓
User confirms "Reset Now"
    ↓
SessionResetManager.generateSummary(oldSessionKey)
    ├── fetchHistory(sessionKey, limit: 500)
    ├── construct summary prompt
    ├── sendMessage(newSessionKey, summaryPrompt)
    └── return AI's summary response
    ↓
SessionResetManager.resetTopic(topicId, summary)
    ├── generate new UUID
    ├── sendMessage(newSessionKey, summary)  // creates new session
    ├── update topic.sessionKey = newSessionKey
    ├── update TopicSessionBridge
    └── save SessionResetRecord
    ↓
SessionResetSheet shows summary
    ↓
User taps "Done" → sheet dismisses
```

## Files Changed

| File | Change |
|---|---|
| `Sources/BeeChatSyncBridge/SessionResetManager.swift` | **NEW** — orchestration actor |
| `Sources/App/UI/Components/SessionResetSheet.swift` | **NEW** — reset confirmation sheet |
| `Sources/App/UI/Components/SessionRow.swift` | **MINOR** — add tap gesture to red dot |
| `Sources/BeeChatPersistence/Models/SessionResetRecord.swift` | **NEW** — reset history model |
| `Sources/BeeChatPersistence/Database/DatabaseManager.swift` | **MINOR** — add Migration008 |

## Acceptance Criteria

1. Tapping red dot (>150 messages) shows reset confirmation sheet
2. Summary is generated from conversation history (3-5 bullet points)
3. New session is created with summary as first message
4. Topic's sessionKey is updated to the new session
5. Old session's messages are preserved in database (not deleted)
6. Reset history is recorded in `session_resets` table
7. AI in new session has context from summary
8. Build succeeds clean
9. No changes to existing SyncBridge, MessageViewModel, or Topic models

## Rollback

Remove 4 new files and revert SessionRow.swift change. No data migration rollback needed (Migration008 is additive only).

## Out of Scope

- Automatic reset triggers (user-initiated only)
- Summary quality tuning (basic prompt first, iterate later)
- Token count display
- Multi-topic batch reset
- Archive/delete old session messages