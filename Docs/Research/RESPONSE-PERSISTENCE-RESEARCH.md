# Research: How BeeChat v1 Persisted AI Responses — And How to Make v5 Work the Same Way

**Date:** 2026-04-22  
**Issue:** AI responses flash up briefly then disappear in BeeChat v5

---

## 1. How v3 (Closest to v1) Handled Response Persistence

### Architecture
v3 used a **polling-based HTTP approach** — no WebSocket streaming at all:

1. **`OpenClawClient.swift`** polled `sessions_history` every 5 seconds via HTTP
2. **`MessageStore.swift`** was the single source of truth — an `@Published var messages: [Message]` array
3. On each poll, the client:
   - Called `sessions_history` RPC to get the last 10 messages
   - Compared each message against a `shownMessageHashes` set (dedup by `role:content`)
   - For new `assistant` messages → appended to `messages` array + called `saveMessageToDB()`
4. **Persistence was immediate and explicit:** every received message was saved to SQLite (`SQLiteManager`) in the same callback that added it to the UI array
5. There was **no streaming state** — the user saw a "thinking" indicator until the full response arrived via polling

### Key v3 Code (MessageStore.swift)
```swift
private func handleReceivedMessage(_ content: String, role: String) {
    // ...
    if role == "assistant" {
        isThinking = false
        let aiMessage = Message(content: content, senderId: "ai", senderName: "Assistant", topicId: "default")
        messages.append(aiMessage)          // UI update
        saveMessageToDB(aiMessage)          // DB persist — SAME callback
    }
}
```

### Why v3 Worked
- **Single source of truth:** `MessageStore.messages` array was both the UI data source AND persisted to DB
- **No streaming intermediaries:** Full message arrived via polling → immediately persisted → immediately displayed
- **No race conditions:** Polling was on a timer, no concurrent streaming deltas competing with persistence

---

## 2. How v4 Handled Response Persistence

### Architecture
v4 used **WebSocket with streaming** — significantly more complex:

1. **`WebSocketClient.swift`** connected via WebSocket and received `GatewayPush` events via `AsyncStream<GatewayPush>`
2. **`StreamingMessageHandler.swift`** managed streaming state machine (`idle → streaming → complete/error/aborted`)
3. **`ConversationViewModel.swift`** subscribed to both the legacy `messageListener` callback AND the `AsyncStream<GatewayPush>`
4. **`HistorySyncManager.swift`** managed GRDB persistence via `appendIncomingMessage()`
5. Messages flowed through two paths:
   - **Streaming path (delta/final events):** `StreamingMessageHandler` displayed partial content in real-time
   - **Persistence path:** `HistorySyncManager.appendIncomingMessage()` upserted to GRDB

### Key v4 Code (ConversationViewModel.swift)
```swift
private func processIncomingMessage(_ message: Message) {
    if message.isStreamingEvent {
        streamingHandler.handleMessage(message)
        
        if message.isStreamDelta {
            // Update or append streaming message
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        } else if message.isStreamFinal {
            // Final: update message and clear streaming
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        // PERSIST to local DB
        if let hsm = historySyncManager {
            hsm.appendIncomingMessage(message)
        }
        return
    }
    // ...
}
```

### Why v4 Worked
- **`messageListener` callback** provided every chat event (delta, final, error) directly to the ViewModel
- **Streaming and persistence happened in the same callback** — no race between display and storage
- **`final` events** carried the complete message text and were persisted immediately
- **HistorySyncManager** upserted by `messageId` — delta updates replaced content in-place, final confirmed it

---

## 3. How v5 Currently Handles Response Persistence

### Architecture
v5 uses a **layered SyncBridge architecture**:

1. **`GatewayClient`** (actor) receives WebSocket frames → parses events → yields `(event, payload)` via `AsyncStream`
2. **`EventRouter`** routes events by name: `"chat"`, `"session.message"`, `"agent"`, etc.
3. **`SyncBridge`** (actor) processes events:
   - `processChatDelta()` → updates `streamingBuffer`, notifies delegate
   - `processChatFinal()` → calls `fetchHistory()` then notifies delegate
   - `processAgentEvent()` → handles legacy agent stream events
4. **`SyncBridgeObserver`** receives delegate callbacks → publishes `isStreaming`, `streamingContent` to UI
5. **`MessageListObserver`** observes GRDB `ValueObservation` on the messages table via `SyncBridge.messageStream()`
6. **`MessageViewModel`** holds the `MessageListObserver` and provides `messages` to the view

### The Problem — Where Messages Disappear

**The critical flow for AI responses in v5:**

1. Gateway sends `chat` event with `state: "delta"` → `EventRouter.handleChatEvent()`
2. Delta handler calls `SyncBridge.processChatDelta()` → updates streaming buffer, delegate callback
3. **Streaming text is displayed via polling `SyncBridgeObserver.streamingContent` at 10Hz**
4. Gateway sends `chat` event with `state: "final"` → `EventRouter.handleChatEvent()`
5. Final handler:
   - Saves the message to DB via `syncBridge.config.persistenceStore.saveMessage(message)` ✅
   - Calls `processChatFinal()` which:
     - Clears streaming buffer
     - Calls `fetchHistory()` to refresh from gateway ✅
     - Notifies delegate → `SyncBridgeObserver.didStopStreaming`

**But here's the gap:** After `didStopStreaming`, the UI clears the streaming content. The `MessageListObserver` is observing the GRDB messages table via `ValueObservation`. The question is: **does the GRDB observation fire and deliver the persisted message before or after the streaming content is cleared?**

Looking at `MessageListObserver.startObserving()`:
```swift
func startObserving(syncBridge: SyncBridge, sessionKey: String) {
    streamTask = Task { [weak self] in
        let stream = await syncBridge.messageStream(sessionKey: sessionKey)
        for await messages in stream {
            self?.messages = messages
        }
    }
}
```

This observes via `SyncBridge.messageStream()` which creates a `MessageObserver` with GRDB `ValueObservation`:
```swift
public func observeMessages(sessionKey: String) -> AsyncStream<[Message]> {
    AsyncStream { continuation in
        let observation = ValueObservation.tracking { db in
            try Message.filter(Column("sessionId") == sessionKey)
                .order(Column("timestamp").asc).limit(500).fetchAll(db)
        }
        let cancellable = observation.start(in: writer, scheduling: .mainActor, onChange: { messages in
            continuation.yield(messages)
        })
    }
}
```

**The race condition:** When the `final` event arrives:
1. `saveMessage()` is called on the persistence store (writes to GRDB)
2. `processChatFinal()` clears `streamingBuffer` and calls `fetchHistory()` 
3. Delegate notifies `SyncBridgeObserver` → streaming UI cleared
4. GRDB `ValueObservation` fires asynchronously (it uses `.mainActor` scheduling, but the write and the observation callback are on different execution contexts)
5. **Between steps 3 and 4, there's a visual gap** — streaming content is gone but the persisted message hasn't arrived from GRDB yet

### Why `session.message` Events Don't Help

The `session.message` event handler in `EventRouter`:
```swift
private func handleSessionMessage(payload: [String: AnyCodable]?) async {
    // ...
    try? syncBridge.config.persistenceStore.saveMessage(message)
}
```

This also persists messages, but it has the same issue — it writes to GRDB but the UI only sees it when `ValueObservation` fires. If the `chat` final event and `session.message` arrive close together, both persist but the UI clearing happens before either observation fires.

### The Core Problem in v5

**v5 has a timing gap between clearing the streaming bubble and the GRDB observation delivering the persisted message.**

In v4, the same message object was both displayed AND persisted in the same callback — no gap. In v3, the full message arrived via polling and was immediately added to the array.

In v5, the architecture splits these concerns:
- Streaming display = polling `SyncBridgeObserver.streamingContent` (actor isolation)
- Persisted display = GRDB `ValueObservation` via `MessageListObserver`
- The transition from streaming → persisted has no guarantee of atomicity

---

## 4. Comparison Table

| Aspect | v3 (Working) | v4 (Working) | v5 (Broken) |
|--------|-------------|--------------|--------------|
| Transport | HTTP polling (5s interval) | WebSocket + AsyncStream | WebSocket + AsyncStream |
| Event that delivers final message | `sessions_history` poll response | `messageListener` callback → `isStreamFinal` | `chat` event with `state: "final"` |
| How it's persisted | `SQLiteManager.insertMessage()` directly | `HistorySyncManager.appendIncomingMessage()` → GRDB upsert | `persistenceStore.saveMessage()` → GRDB upsert |
| How UI observes it | `@Published var messages` in `MessageStore` | `@Published var messages` in `ConversationViewModel` + `StreamingMessageHandler` | GRDB `ValueObservation` via `MessageListObserver` |
| Timing of persistence vs streaming | N/A (no streaming) | Same callback — streaming state AND DB write happen together | Separate paths — streaming cleared before GRDB observation fires |
| Race condition? | No | No | **Yes** — visual gap between streaming clear and GRDB delivery |

---

## 5. Minimal Fix Specification

### Root Cause
The streaming bubble disappears when `didStopStreaming` is called, but the GRDB `ValueObservation` hasn't fired yet to deliver the persisted message. The user sees a brief flash of the streaming text, then an empty chat until the observation catches up.

### Fix Options (in order of preference)

#### Option A: Keep the Persisted Message Visible During Transition (Recommended)

**What:** In `EventRouter.handleChatEvent()`, when `state == "final"`, the message is already being saved to the database. The fix is to ensure the `didStopStreaming` delegate callback only fires **after** the GRDB observation has delivered the new message list.

**How:**
1. In `SyncBridge.processChatFinal()`, after `fetchHistory()` completes, add a small delay or confirmation mechanism to ensure the GRDB `ValueObservation` has fired before clearing the streaming state
2. OR: Change `MessageListObserver` to also accept direct message updates (like v4's `HistorySyncManager.appendIncomingMessage()`) so the UI gets the message immediately rather than waiting for the GRDB observation

**Minimal code change:**

In `EventRouter.handleChatEvent()`, for `state: "final"`:
```swift
case "final":
    if let text = messageText {
        let message = Message(...)
        try? syncBridge.config.persistenceStore.saveMessage(message)
    }
    // DON'T call processChatFinal immediately
    // Instead, fetch history and THEN clear streaming
    await syncBridge.processChatFinal(sessionKey: sessionKey)
```

In `SyncBridge.processChatFinal()`:
```swift
internal func processChatFinal(sessionKey: String) async {
    cancelStallTimer()
    streamingBuffer.removeValue(forKey: sessionKey)
    currentStreamingSessionKey = nil
    
    // Fetch history BEFORE notifying the delegate
    do {
        _ = try await fetchHistory(sessionKey: sessionKey)
    } catch { }
    
    // Small yield to allow GRDB observation to fire
    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    
    delegate?.syncBridge(self, didStopStreaming: sessionKey)
}
```

**BUT** — this is a hack with a fixed delay. A better approach:

#### Option B: Direct Message Injection into MessageListObserver (Better)

**What:** Instead of relying solely on GRDB `ValueObservation` to deliver the persisted message, inject the final message directly into the `MessageListObserver` when the streaming completes. This mirrors v4's approach where streaming and persistence happened in the same callback.

**How:**
1. Add a method to `MessageListObserver` to directly inject/update messages
2. In `SyncBridgeObserver.didStopStreaming`, also deliver the final message content directly
3. When the GRDB observation fires, it will confirm/update the message (upsert behavior means no duplicates)

**Code changes:**

In `MessageListObserver.swift`:
```swift
/// Directly inject a message (for streaming final → persisted transition)
func injectMessage(_ message: Message) {
    if let idx = messages.firstIndex(where: { $0.id == message.id }) {
        messages[idx] = message
    } else {
        messages.append(message)
    }
}
```

In `SyncBridge.swift`, add a property to store the final message:
```swift
/// The last final message text, keyed by session, for direct injection
private var lastFinalMessage: [String: Message] = [:]
```

In `processChatFinal()`, before clearing streaming:
```swift
internal func processChatFinal(sessionKey: String) async {
    cancelStallTimer()
    
    // Save the final message for direct injection
    let finalMessage = lastFinalMessage.removeValue(forKey: sessionKey)
    
    streamingBuffer.removeValue(forKey: sessionKey)
    if currentStreamingSessionKey == sessionKey {
        currentStreamingSessionKey = nil
    }
    
    // Fetch history to ensure DB is complete
    do {
        _ = try await fetchHistory(sessionKey: sessionKey)
    } catch { }
    
    // Notify delegate — pass the final message for direct injection
    delegate?.syncBridge(self, didStopStreaming: sessionKey, finalMessage: finalMessage)
}
```

Update `SyncBridgeDelegate`:
```swift
public protocol SyncBridgeDelegate: AnyObject {
    func syncBridge(_ bridge: SyncBridge, didUpdateConnectionState state: ConnectionState)
    func syncBridge(_ bridge: SyncBridge, didEncounterError error: Error)
    func syncBridge(_ bridge: SyncBridge, didStartStreaming sessionKey: String)
    func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String, finalMessage: Message?)
}
```

In `SyncBridgeObserver`, when `didStopStreaming` is called:
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String, finalMessage: Message?) {
    Task { @MainActor in
        if let message = finalMessage {
            // Directly inject the message for immediate display
            // MessageListObserver will confirm via GRDB observation shortly
            messageListObserver?.injectMessage(message)
        }
        self.isStreaming = false
        self.streamingSessionKey = nil
        self.streamingContent = ""
        self.stopStreamingPoll()
    }
}
```

#### Option C: Simplest Possible Fix (Recommended for Speed)

**What:** The simplest fix is to NOT clear the streaming content until the GRDB observation confirms the message has arrived. This means keeping the streaming bubble visible until the persisted message appears in the observed list.

**How:**
1. In `SyncBridgeObserver.didStopStreaming`, DON'T clear `streamingContent` immediately
2. Instead, keep the streaming content visible until `MessageListObserver.messages` updates to include a message with matching content (or a message newer than the streaming start)
3. Only then clear the streaming state

**Code change in `SyncBridgeObserver`:**

```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
    Task { @MainActor in
        // DON'T clear streaming content yet!
        // Keep it visible until the GRDB observation delivers the persisted message.
        // The MessageListObserver will fire and update messages, which will
        // naturally replace the streaming bubble in the UI.
        self.isStreaming = false
        self.streamingSessionKey = nil
        // NOTE: streamingContent is NOT cleared here
        // It will be cleared when the MessageListObserver delivers the message
    }
}
```

Then in `MessageCanvas.swift`, modify the view logic:
```swift
// Instead of showing streaming OR persisted messages:
// Show persisted messages, and overlay streaming content if still streaming
ForEach(messages, id: \.id) { message in
    MessageBubble(message: message)
        .id(message.id)
}

// Only show streaming bubble if we're actively streaming
// AND the last persisted message doesn't match the streaming content
if isStreaming && streamingContent.isNotEmpty {
    // Check if the streaming content is already in the persisted messages
    let lastAssistantContent = messages.last(where: { $0.role == "assistant" })?.content
    if streamingContent != lastAssistantContent {
        StreamingBubble(content: streamingContent)
    }
}
```

But this is still tricky. The **simplest and most robust** approach:

---

### **Recommended Fix: Option D — Keep Streaming Content Until Confirmation**

**What:** Modify `SyncBridgeObserver` to NOT clear `streamingContent` until `MessageListObserver` confirms the final message has arrived. This eliminates the visual gap entirely.

**Implementation:**

1. **`SyncBridgeObserver`** gets a reference to `MessageListObserver` (or a callback)
2. When `didStopStreaming` fires, set `isStreaming = false` but KEEP `streamingContent`
3. `MessageCanvas` shows BOTH the streaming content AND the persisted messages, deduplicating by content
4. When `MessageListObserver.messages` updates and includes a message whose content matches the streaming content, clear `streamingContent`

Actually, the simplest version of this: **just don't clear streamingContent on didStopStreaming**. Let `MessageCanvas` handle the overlap:

In `SyncBridgeObserver.didStopStreaming`:
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
    Task { @MainActor in
        self.isStreaming = false
        self.streamingSessionKey = nil
        // DON'T clear streamingContent — let it persist until 
        // the GRDB observation delivers the final message.
        // The streaming bubble will be hidden once isStreaming == false
        // and the message list includes the persisted message.
        self.stopStreamingPoll()
    }
}
```

In `MessageCanvas.swift`, update the display logic:
```swift
// Show all persisted messages
ForEach(messages, id: \.id) { message in
    MessageBubble(message: message)
        .id(message.id)
}

// Show streaming content if:
// 1. We're actively streaming (isStreaming == true), OR
// 2. Streaming content exists but hasn't appeared in persisted messages yet
// This handles the transition gap
let lastAssistantContent = messages.last(where: { $0.role == "assistant" })?.content
let showStreaming = isStreaming || (streamingContent.isNotEmpty && streamingContent != lastAssistantContent)

if showStreaming {
    if streamingContent.isEmpty {
        TypingIndicator()
            .id("typing-indicator")
    } else {
        StreamingBubble(content: streamingContent)
            .id("streaming-bubble")
    }
}
```

This ensures the streaming bubble stays visible until the persisted message with matching content arrives via GRDB observation, closing the visual gap.

**Files to change:**
1. `Sources/App/UI/Observers/SyncBridgeObserver.swift` — don't clear `streamingContent` in `didStopStreaming`
2. `Sources/App/UI/Components/MessageCanvas.swift` — show streaming bubble until persisted message confirms

No changes needed to the SyncBridge, EventRouter, or persistence layers. The fix is purely in the UI observation layer.

---

## 6. Additional Observations

### The `session.message` Event
The gateway also sends `session.message` events, which `EventRouter.handleSessionMessage()` handles by persisting directly to the DB. This is a **secondary persistence path** that could help ensure messages are saved, but it doesn't solve the UI timing issue.

### The `agent` Event Path
The `agent` event path (legacy) has its own `processAgentEvent()` handler in `SyncBridge`. It also persists the final message and fetches history. This is a fallback path and is less commonly used.

### History Fetch After Final
Both `processChatFinal()` and `processAgentEvent()` call `fetchHistory()` before notifying the delegate. This is good — it means the DB is updated before the delegate is told streaming is done. The issue is that the **GRDB observation** fires asynchronously after the write, and the UI clears the streaming content before the observation delivers.

### The `fetchHistory()` Call
```swift
internal func processChatFinal(sessionKey: String) async {
    // ...
    do {
        _ = try await fetchHistory(sessionKey: sessionKey)
    } catch { }
    
    delegate?.syncBridge(self, didStopStreaming: sessionKey)
}
```

This fetches history from the gateway and upserts into the DB. The GRDB observation should then fire. But because the observation is scheduled on `.mainActor`, it competes with the delegate callback (also on main actor). The delegate callback may execute before the GRDB observation fires.

---

## 7. Summary

| Version | Why It Worked | Why v5 Breaks |
|---------|--------------|---------------|
| v3 | Polling → full message → immediate persist + display | N/A (no streaming) |
| v4 | WebSocket → same callback for display + persist | N/A (worked correctly) |
| v5 | Streaming → persist → GRDB observation → display | **Race condition**: streaming cleared before GRDB observation delivers |

**The fix is simple:** Don't clear the streaming content until the persisted message is confirmed in the observed message list. This is a 2-file change in the UI observation layer.