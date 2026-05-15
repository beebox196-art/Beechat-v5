# Review: Fix D Implementation (Scroll Bounce + White Space)

**Reviewer:** Kieran (independent)  
**Date:** 2026-05-10  
**File:** `Sources/App/UI/Components/MessageCanvas.swift`  
**Spec:** `CONSENSUS-scroll-bounce-2026-05-10.md`

---

## Verification: All Four Changes

### 1. `.scrollBounceBehavior` conditional ✅ (with amendment)

**Spec:** `.scrollBounceBehavior(isStreaming || thinkingState != .idle ? .never : .basedOnSize, axes: .vertical)`

**Actual:** `.scrollBounceBehavior(isStreaming || thinkingState != .idle ? .automatic : .basedOnSize, axes: .vertical)`

**Amendment #3:** `.never` doesn't exist in the SwiftUI API. Changed to `.automatic`. Accepted — `.automatic` is the closest neutral option and the amendment was explicitly documented.

⚠️ **Note:** `.automatic` is the system default and on macOS behaves similarly to `.basedOnSize` (bounce when content exceeds viewport). This means the bounce suppression during streaming may be less aggressive than the original `.never` intent. However, the consensus identified three contributing factors, and `.scrollBounceBehavior` was the least impactful of the three — the target logic change (item 3) and `asyncAfter` removal (item 4) are the primary fixes. If bounce persists, this should be revisited, but it's not a blocker.

### 2. `onChange(of: showStreamingBubble)` removed ✅

**Spec:** Delete the entire `onChange(of: showStreamingBubble)` handler.

**Actual:** No `onChange(of: showStreamingBubble)` block exists. Replaced by an explanatory comment:
```swift
// showStreamingBubble scroll removed — target logic now uses showStreamingBubble
// to pick the correct scroll target, so a separate onChange is unnecessary.
```

The comment documents *why* it was removed, which is better than silent deletion. ✅

### 3. Target logic uses `isStreaming && showStreamingBubble` ✅

**Spec:** Target `"streaming-bubble"` when streaming, `"thinking-bee"` when thinking, else `messages.last?.id ?? "bottom-anchor"`.

**Amendment #2:** Use `showStreamingBubble` in the condition to avoid targeting a non-existent `"streaming-bubble"` ID during the pre-streaming gap.

**Actual:**
```swift
if isStreaming && showStreamingBubble {
    targetId = "streaming-bubble"
} else if thinkingState == .thinking {
    targetId = "thinking-bee"
} else {
    targetId = messages.last?.id ?? "bottom-anchor"
}
```

Correct. The `&& showStreamingBubble` guard prevents scrolling to `"streaming-bubble"` when the streaming bubble isn't rendered (during the thinking→streaming transition when `streamingContent` is still empty). This was the right amendment — without it, `scrollTo` would target a non-existent ID during the pre-streaming gap. ✅

### 4. `asyncAfter` removed entirely ✅

**Spec:** Remove `DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(...) }` from `scrollToBottom()`.

**Actual:** The `scrollToBottom()` method contains only:
```swift
if animated {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
} else {
    proxy.scrollTo(targetId, anchor: .bottom)
}
```

No `asyncAfter`. No trailing comment referencing it. Clean removal per amendment #1. ✅

---

## Unintended Changes Check

Compared the full file against expected structure:

- **`showStreamingBubble` computed property** — present, logic unchanged (guards against empty content and duplicate committed messages). ✅
- **Dedup guard** — `lastScrollTime` with 0.3s threshold for streaming/thinking. Present and unchanged. ✅
- **`onChange(of: messages.count)`** — present, logic unchanged (anchor message handling, pending topic scroll, `isAtBottom`/`isUserMessage`/`isStreaming` conditions). ✅
- **`onChange(of: isStreaming)`** — present, scrolls to bottom on stream start. ✅
- **`onChange(of: thinkingState)`** — present, logging only (no scroll action). ✅
- **`onChange(of: topicId)`** — present, logic unchanged. ✅
- **`onAppear`** — present, stores proxy and scrolls to bottom. ✅
- **Jump to Latest button** — present, unchanged. ✅
- **`bottom-anchor` spacer** — present with `onAppear`/`onDisappear` for `isAtBottom`. ✅
- **`defaultScrollAnchor(.bottom)`** — present. ✅

No unintended changes detected.

---

## Verdict: **APPROVE** ✅

All four specified changes are correctly implemented with both documented amendments applied:

1. `.scrollBounceBehavior` conditional — `.automatic` during streaming/thinking, `.basedOnSize` otherwise (amended from `.never` per API availability)
2. `onChange(of: showStreamingBubble)` — removed, replaced with explanatory comment
3. Target logic — `isStreaming && showStreamingBubble` → streaming-bubble, `thinkingState == .thinking` → thinking-bee, else → messages.last/bottom-anchor
4. `asyncAfter` — fully removed

No unintended changes. No regressions introduced.

**One follow-up recommendation:** The `.automatic` bounce behavior during streaming may not fully suppress bounce on macOS. If bounce persists after this fix, consider adding a throttled `onChange(of: streamingContent)` handler as suggested in the spec's P2/deferred Fix D2 item. The target logic change alone should eliminate the white space issue (Fix E) regardless.