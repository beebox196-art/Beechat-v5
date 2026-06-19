# DEBUG.md — BeeChat 99% CPU Hang Root Cause

**Date:** 2026-05-13  
**Reporter:** Q (subagent)  
**Incident:** BeeChatApp PID 5690 at 99% CPU, 10.2GB footprint  
**Sample:** `CRASH-sample-2026-05-13.txt`  
**Consensus:** `CONSENSUS-crash-hang-2026-05-10.md`

---

## 1. What the Sample Shows

Out of **1448 main-thread samples**, **1370** are inside:

```
NSRunLoop.flushObservers
  → NSHostingView.beginTransaction()
    → ViewGraphRootValueUpdater.updateGraph
      → LazySubviewPlacements.placeSubviews
        → ForEachList.applyNodes
          → LazyStack.place
```

This is **not a deadlock**. It is a **SwiftUI infinite layout recomputation loop** — the main thread is continuously re-laying-out `LazyVStack` message positions and never settles.

---

## 2. Why It Loops Forever

Three state-update paths fire in rapid succession, each triggering the next, creating a cycle that never quiesces:

### Path A — 50 ms streaming poll (unconditional write)
`SyncBridgeObserver.startStreamingPoll()` assigns:

```swift
self.streamingContent = content   // every 50 ms, even if identical
```

`SyncBridgeObserver` is `@MainActor @Observable`. Every write to `@Published`-equivalent state triggers a full SwiftUI body re-evaluation for every view that reads `streamingContent`.

### Path B — `showStreamingBubble` computed property + `.onChange` scroll
`MessageCanvas.showStreamingBubble` depends on `streamingContent`:

```swift
private var showStreamingBubble: Bool {
    guard !streamingContent.isEmpty else { return false }
    if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
       lastAssistant.content == streamingContent {
        return false
    }
    return true
}
```

Every 50 ms this boolean can flip. `MessageCanvas` binds:

```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing { scrollToBottom(proxy: proxy) }
}
```

`scrollToBottom` calls `proxy.scrollTo("bottom-anchor", anchor: .bottom)`, which itself triggers a layout pass. Because the next 50 ms poll fires before the current layout pass completes, SwiftUI never finishes one pass before starting the next.

### Path C — GRDB `ValueObservation` yields new array references
`SyncBridge.messageStream(sessionKey:)` uses `ValueObservation.tracking` on the `messages` table. Every time the gateway writes a streaming delta to the DB, the observation fires and yields a **new `[Message]` array** (new reference, even if content is identical).

`MessageListObserver.setAllMessages(_:)` → `applyWindow()` unconditionally sets:

```swift
self.messages = windowed   // new array reference every time
```

`MessageCanvas` binds `.onChange(of: messages.count)`, so every DB write also triggers `scrollToBottom` again.

### Result: Three overlapping triggers
1. `streamingContent` update every 50 ms → body re-eval
2. `messages` array reference churn from DB → body re-eval + scroll
3. `scrollToBottom` → `proxy.scrollTo` → new layout pass

SwiftUI's `LazyVStack` recomputes `placeSubviews` for every message on every pass. With 162 messages in the windowed slice, this is expensive. The three paths overlap so that **one layout pass starts before the previous one finishes**, causing the infinite loop seen in the sample.

---

## 3. Why Approved Fix C Didn't Help

Fix C (`guard self.isStreaming else { return }` in the poll loop) **is already present** in `SyncBridgeObserver.swift` line 186. The guard only prevents the poll from running when `isStreaming == false`. When streaming IS active, the poll still runs every 50 ms and still triggers the layout loop via Paths A, B, and C.

---

## 4. Fix Plan

| Fix | File | What | Why |
|-----|------|------|-----|
| **D1** | `SyncBridgeObserver.swift` | Diff `streamingContent` before assignment | Stops Path A: no SwiftUI invalidation when string is unchanged |
| **D2** | `MessageListObserver.swift` | Diff `allMessages` before assignment | Stops Path C: no `messages` churn when DB data is identical |
| **D3** | `MessageCanvas.swift` | Debounce `scrollToBottom` during streaming | Stops overlapping `scrollTo` calls from stacking up |
| **A** | `GatewayClient.swift` + `PendingRequestMap.swift` | A2 (`remove()` return value) + A1 (`hasResumed`) defense-in-depth | Prevents `CheckedContinuation` double-resume crash |

### D1 — Content diff guard
```swift
let content = await bridge.streamingContent(for: selectedKey)
if self.streamingContent != content {
    self.streamingContent = content
}
```

### D2 — Message equality check
`Message` is not `Equatable`. We add lightweight comparison by `id` + `timestamp` + `content` to avoid churn.

### D3 — Scroll debounce
Track a `lastScrollTime` and skip `scrollToBottom` if called within ~100 ms of the previous scroll.

### A — `CheckedContinuation` double-resume
Implement consensus A2 (`remove()` returns `Bool`) + A1 (`hasResumed` in closures) + cancellation handler.

---

## 5. Verification

After fixes, the following should hold:
- `streamingContent` only updates when the gateway actually sends new text.
- `messages` only updates when DB rows actually change (not on every streaming buffer write).
- `scrollToBottom` fires at most once per 100 ms during active streaming.
- CPU usage returns to idle baseline within 1 s of streaming stopping.
