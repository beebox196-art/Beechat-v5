# Review: Fix C — Streaming Poll Safety Guard (Implementation)

**Reviewer:** Kieran  
**Date:** 2026-05-10  
**Spec:** `SPEC-FIX-C-poll-guard.md` v1.1  
**File:** `Sources/App/UI/Observers/SyncBridgeObserver.swift`

---

## Verification Checklist

### 1. `[weak self]` on Task closure ✅

```swift
streamingPollTask = Task { [weak self] in
```

`[weak self]` capture list present on the Task closure. Matches spec exactly.

### 2. `guard let self, self.isStreaming else { return }` as first line inside while loop ✅

```swift
while !Task.isCancelled {
    guard let self, self.isStreaming else { return }
    ...
}
```

Guard is the first statement after the `while` opening brace, before any other logic. Matches spec exactly.

### 3. All other lines unchanged ✅

Comparing the body of `startStreamingPoll()` against the spec's "After" version:

| Line | Spec | Implementation | Match |
|------|------|----------------|-------|
| `stopStreamingPoll()` | `stopStreamingPoll()` | `stopStreamingPoll()` | ✅ |
| `if let bridge = self.syncBridge {` | `if let bridge = self.syncBridge {` | ✅ |
| `let selectedKey = self.streamingSessionKey ?? ""` | `let selectedKey = self.streamingSessionKey ?? ""` | ✅ |
| `let content = await bridge.streamingContent(for: selectedKey)` | `let content = await bridge.streamingContent(for: selectedKey)` | ✅ |
| `self.streamingContent = content` | `self.streamingContent = content` | ✅ |
| Comment: "Yield to prevent CPU spin…" | Identical | ✅ |
| `try await Task.sleep(nanoseconds: 50_000_000)` | Identical | ✅ |

No lines added, removed, or modified beyond the two spec'd changes.

### 4. Rest of SyncBridgeObserver untouched ✅

Reviewed the full file (≈330 lines). No methods outside `startStreamingPoll()` were altered:

- `didStartStreaming` — unchanged
- `didStopStreaming` — unchanged
- `resetStreamingState` — unchanged
- `stopStreamingPoll` — unchanged
- `startStreamingTimeout` / `cancelStreamingTimeout` — unchanged
- `startThinkingTimeout` / `cancelThinkingTimeout` — unchanged
- `AgentActivityTracker` — unchanged
- All other properties and methods — unchanged

---

## Verdict: **APPROVE** ✅

Implementation matches the approved spec exactly. Two changes, two changes only, no collateral drift. Clean merge.