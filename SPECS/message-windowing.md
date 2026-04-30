# SPEC: Message Windowing — Last 25 + Load Earlier (v2)

**Date:** 2026-04-30  
**Priority:** Medium — UX improvement, no data loss  
**Scope:** MessageListObserver + MessageCanvas + MainWindow  
**Risk:** Low — UI-layer slicing + one button  
**Review v1:** Q ⚠️ NEEDS CHANGES · Kieran ⚠️ NEEDS CHANGES — 7 items flagged, all incorporated in v2.
**Review v2:** Kieran ✅ APPROVED · Q ⚠️ 3 implementation fixes — incorporated below.

---

## Goal

Display only the last 25 messages per topic in the message window. Older messages remain in SQLite and can be loaded in batches of 25 via a "Load earlier messages" button at the top of the list.

**All messages stay stored in the database.** Nothing is deleted. This is a display/windowing change only.

---

## Standard Practice Check

This is a well-established pattern in messaging apps:

- **iMessage** — loads recent messages, "Load earlier" at top
- **WhatsApp** — infinite scroll up triggers batch load from local DB
- **Telegram** — same pattern, SQLite-backed pagination
- **Slack** — same, with virtual scrolling for performance

The standard implementation: **query a generous window from the DB, apply the display limit in the UI layer, expand on demand.** This keeps the data layer independent of UI concerns and avoids restarting observations on every "load more" tap. We are not inventing anything.

---

## Current State

Two observation paths exist:

1. **`SyncBridge.messageStream(sessionKey:)`** — `ValueObservation` with `.limit(500)`, yields full message list via `AsyncStream`. This is the **active path** used by `MessageListObserver`.
2. **`MessageViewModel.startLocalMessageObservation`** — older `ValueObservation` with `.limit(500)`. **Not dead code** — it's the fallback when `syncBridge` is nil (gateway not connected). Called by `MainWindow.wireUpObservers()` on startup and by the fallback path in `startObservationForSelectedTopic()`.

Both query:
```swift
Message
    .filter(Column("sessionId") == sessionKey)
    .order(Column("timestamp").asc)
    .limit(500)
    .fetchAll(db)
```

The `MessageCanvas` renders all messages in a `LazyVStack` with auto-scroll to bottom on `messages.count` change.

---

## Architecture Decision: UI-Layer Slicing, NOT DB-Layer Limiting

> **Kieran (MEDIUM) + Q:** The original spec changed the DB `LIMIT` per "load earlier" tap. This is non-standard — it requires cancelling and recreating the `AsyncStream` + `ValueObservation` on every tap, couples display limit to data layer, causes flicker, and risks observation region tracking issues.
>
> **Correct approach:** Keep `messageStream` returning up to 500 messages (unchanged). Apply the display window in `MessageListObserver` using `.suffix(messageLimit)`. When "Load earlier" is tapped, increase `messageLimit` — no stream restart, no flicker, no observation tear-down.

**The data layer stays dumb. The UI layer handles windowing.** This is how established messaging apps do it.

---

## Changes

### Change 1: `messageStream` — fix newest-500 query

> **Q (blocking):** Current query `.order(timestamp.asc).limit(500)` fetches the **oldest** 500 messages. Once a topic exceeds 500, `.suffix(25)` would show messages 476-500 of the oldest batch, not the latest messages.

Fix: fetch newest 500 descending, then reverse for display:

```swift
public func messageStream(sessionKey: String) -> AsyncStream<[Message]> {
    return AsyncStream { continuation in
        let observation = ValueObservation.tracking { db in
            let newest = try Message
                .filter(Column("sessionId") == sessionKey)
                .order(Column("timestamp").desc, Column("id").desc)
                .limit(500)
                .fetchAll(db)
            return Array(newest.reversed())
        }
        // ... rest unchanged
    }
}
```

The same fix applies to `startLocalMessageObservation` in `MessageViewModel`.

### Change 2: `MessageListObserver` — add UI-layer windowing

```swift
@MainActor
@Observable
final class MessageListObserver {
    var messages: [Message] = []        // The windowed slice shown in UI
    var sessionKey: String?
    var canLoadEarlier: Bool = false
    
    private var streamTask: Task<Void, Never>?
    private var allMessages: [Message] = []  // Full set from stream (up to 500)
    private var messageLimit: Int = 25
    
    func startObserving(syncBridge: SyncBridge, sessionKey: String) {
        streamTask?.cancel()
        self.sessionKey = sessionKey
        self.messageLimit = 25       // Reset on topic switch
        self.allMessages = []
        self.messages = []
        self.canLoadEarlier = false

        streamTask = Task { [weak self] in
            let stream = await syncBridge.messageStream(sessionKey: sessionKey)
            for await updatedMessages in stream {
                guard !Task.isCancelled else { return }
                self?.allMessages = updatedMessages
                self?.applyWindow()
            }
        }
    }
    
    /// Apply the display window to the full message set
    private func applyWindow() {
        let windowed = Array(allMessages.suffix(messageLimit))
        messages = windowed
        canLoadEarlier = allMessages.count > messageLimit
    }
    
    /// Load 25 more messages — no stream restart needed
    func loadEarlierMessages() {
        messageLimit += 25
        applyWindow()
    }
    
    func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
        sessionKey = nil
        allMessages = []
        messages = []
        canLoadEarlier = false
    }
}
```

**Key points:**
- `allMessages` holds the full set from the stream (up to 500)
- `messages` is the windowed slice for display
- `loadEarlierMessages()` just increases `messageLimit` and re-applies the window — **no stream restart**
- On topic switch, `messageLimit` resets to 25

### Change 3: `startLocalMessageObservation` — unified windowing through MessageListObserver

> **Q (blocking):** The fallback path sets `allMessages` via `updateMessages()` but `loadEarlierMessages()` only calls `messageListObserver.loadEarlierMessages()` which applies `.suffix()` on `allMessages`. In fallback mode, `allMessages` was never populated — only the windowed slice was passed.
>
> **Fix:** Both paths must feed `allMessages` into `MessageListObserver`, and the observer always applies `.suffix(messageLimit)`. No windowing in `MessageViewModel`.

```swift
private func startLocalMessageObservation(for sessionKey: String) {
    localMessageCancellable?.cancel()

    let observation = ValueObservation.tracking { db in
        let newest = try Message
            .filter(Column("sessionId") == sessionKey)
            .order(Column("timestamp").desc, Column("id").desc)
            .limit(500)
            .fetchAll(db)
        return Array(newest.reversed())
    }

    do {
        let writer = try DatabaseManager.shared.writer
        localMessageCancellable = observation.start(
            in: writer,
            scheduling: .mainActor,
            onError: { error in
                BeeChatLogger.log("[ThinkingBee] Local message observation error: \(error)")
            },
            onChange: { [weak self] allMessages in
                // Feed full set to observer, observer applies window
                self?.messageListObserver.setAllMessages(allMessages)
            }
        )
    } catch {
        BeeChatLogger.log("[ThinkingBee] Failed to start local message observation: \(error)")
    }
}
```

`MessageListObserver.setAllMessages()` replaces `updateMessages()` — both the stream path and local path use it, and `applyWindow()` is called internally.

### Change 4: `MessageListObserver.setAllMessages` — single entry point for both paths

```swift
func setAllMessages(_ allMessages: [Message]) {
    self.allMessages = allMessages
    applyWindow()
}
```

Both the stream-based path (`startObserving`) and the local fallback path (`startLocalMessageObservation`) call `setAllMessages()`. The observer always owns the windowing logic via `applyWindow()`.

The old `updateMessages(_ messages: [Message])` method is replaced by `setAllMessages()` — no more separate window-metadata signature.

### Change 5: "Load earlier messages" button in `MessageCanvas`

Add two new properties to `MessageCanvas`:

```swift
let canLoadEarlier: Bool
let onLoadEarlier: () -> Void
```

Button at the top of the `LazyVStack`:

```swift
LazyVStack(spacing: 0) {
    if canLoadEarlier {
        Button(action: onLoadEarlier) {
            HStack {
                Spacer()
                Text("Load earlier messages")
                    .font(themeManager.font(.caption))
                    .foregroundStyle(themeManager.color(.textSecondary))
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .id("load-earlier")
    }
    
    ForEach(messages, id: \.id) { message in
        MessageBubble(message: message)
            .id(message.id)
    }
    // ... streaming bubbles, bottom-anchor unchanged ...
}
```

Styling: subtle, non-intrusive. Secondary text colour, centered, light padding. The button sits naturally at the top of the message list.

### Change 6: Fix auto-scroll — anchor-based scroll preservation

> **Q + Kieran (HIGH):** Current `MessageCanvas` auto-scrolls on every `messages.count` change. Loading earlier increases count, so it yanks to bottom.
>
> **Kieran (recommended):** Use anchor message ID tracking instead of timing-based suppression. More deterministic, no magic numbers.

Add an `anchorMessageId` state to `MessageCanvas`:

```swift
@State private var anchorMessageId: String?
```

When "Load Earlier" is tapped, capture the current first visible message before loading:

```swift
Button(action: {
    anchorMessageId = messages.first?.id
    onLoadEarlier()
}) { ... }
```

In the `onChange(of: messages.count)` handler, restore scroll position if we have an anchor:

```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        // Restore position to the message that was at top before load
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else {
        scrollToBottom(proxy: proxy)
    }
}
```

Auto-scroll on streaming and appearance still works as before — only `messages.count` changes from "Load Earlier" are intercepted.

**Why this is better than `DispatchQueue.asyncAfter`:** No timing dependency. The scroll position is restored to the exact message the user was reading, regardless of layout speed. This is how iMessage and WhatsApp handle it.

### Change 7: Wiring in `MainWindow.swift`

> **Kieran (LOW):** `MessageCanvas` is instantiated in `MainWindow.swift` (line 162), not through `MessageViewModel`. Wire `canLoadEarlier` and `onLoadEarlier` there.

```swift
// In MainWindow.swift, where MessageCanvas is instantiated:
MessageCanvas(
    messages: messageViewModel.messages,
    isStreaming: syncBridgeObserver.isStreaming,
    streamingContent: syncBridgeObserver.streamingContent,
    thinkingState: syncBridgeObserver.thinkingState,
    canLoadEarlier: messageViewModel.canLoadEarlier,
    onLoadEarlier: { messageViewModel.loadEarlierMessages() }
)
```

> **Q (blocking):** `messageListObserver` is `private` on `MessageViewModel`. Expose computed properties:

```swift
// MessageViewModel
var canLoadEarlier: Bool {
    messageListObserver.canLoadEarlier
}

func loadEarlierMessages() {
    messageListObserver.loadEarlierMessages()
}
```

### Change 8: Deterministic message ordering — timestamp tie-breaker

> **Q:** Same-timestamp messages may reorder unpredictably. Add `id` as secondary sort.

No code change needed — the existing `Message` model already has a unique `id` field. The GRDB query should use:

```swift
.order(Column("timestamp").asc, Column("id").asc)
```

This applies to `messageStream` and `startLocalMessageObservation` — both already use `.order(Column("timestamp").asc)`. Add the `id` tie-breaker to both.

This is not a functional bug today (UUIDs are time-ordered enough), but it's good practice and prevents edge cases.

---

## Files Changed

| File | Change |
|---|---|
| `Sources/App/UI/Observers/MessageListObserver.swift` | Add `allMessages`, `messageLimit`, `canLoadEarlier`, `applyWindow()`, `loadEarlierMessages()`, update `updateMessages` signature |
| `Sources/App/UI/Components/MessageCanvas.swift` | Add `canLoadEarlier` + `onLoadEarlier` props, "Load earlier" button, `suppressAutoScroll` state, gated auto-scroll handlers |
| `Sources/App/UI/MainWindow.swift` | Wire `canLoadEarlier` and `onLoadEarlier` to `MessageCanvas` |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` | Add `canLoadEarlier` computed property, `loadEarlierMessages()`, update `startLocalMessageObservation` with newest-500 query + `setAllMessages()` |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Fix query to newest-500 descending + reverse, add `Column("id").desc` tie-breaker |

---

## What Does NOT Change

- `SyncBridge.messageStream` signature — zero changes (stays `sessionKey:` only)
- `SyncBridge.fetchHistory` — zero changes (write path, not display)
- Database schema — zero changes
- Gateway protocol — zero changes
- Message storage — all messages still persisted in SQLite
- Send/receive/streaming — zero changes
- SyncBridge event handling — zero changes
- Session key logic — zero changes
- `startLocalMessageObservation` — kept, updated with windowing (not removed)
- Any other component (persistence, gateway, reconciler)

---

## Validation

1. **Build:** `swift build -c release`
2. **Existing tests:** All 67 tests pass
3. **Manual — default load:** Select a topic with 50+ messages → only last 25 shown
4. **Manual — load earlier:** Tap "Load earlier messages" → 25 more appear at top, scroll position stays where user was reading (NOT yanked to bottom)
5. **Manual — topic switch:** Switch to different topic → resets to 25
6. **Manual — streaming:** Send message → response streams in → auto-scroll to bottom works, message window still capped at 25
7. **Manual — small topics:** Topic with <25 messages → no "Load earlier" button shown
8. **Manual — gateway offline:** Disconnect gateway → fallback observation still shows windowed 25 messages
9. **Manual — load all:** Keep tapping "Load earlier" until all messages loaded → button disappears

---

## Edge Cases

- **Topic has <25 messages:** No button shown, `canLoadEarlier = false`
- **User loads all history:** `canLoadEarlier` becomes false once `messageLimit >= allMessages.count`
- **New message arrives while at bottom:** Auto-scroll fires, new message appears at bottom within the 25-window
- **New message arrives while scrolled up:** Auto-scroll doesn't fire (user is reading). Window includes the new message if within limit.
- **Streaming response:** Streaming bubble appears at bottom as usual. When final message is persisted, `allMessages` updates, `applyWindow()` re-fires, window adjusts. No visual glitch.
- **Load earlier while streaming:** `suppressAutoScroll` prevents yank to bottom. Earlier messages appear above, streaming continues at bottom.
- **Very long topics (>500 messages):** `messageStream` returns up to 500. If user loads all 500 and there are more in DB, `canLoadEarlier` would still show false because `allMessages.count <= 500 <= messageLimit`. This is acceptable — 500 messages of history is generous. If we want to support >500 in future, we can increase the DB limit or add a second-tier gateway fetch. Not in scope for this spec.

---

## Rollback

If something goes wrong, set `messageLimit = 500` (or `Int.max`) as the default in `MessageListObserver`. The display goes back to showing everything. Zero risk — no data is ever deleted or moved.