# Review: Fix D Implementation Spec (Scroll Bounce + White Space)

**Reviewer:** Q (code implementation specialist)  
**Date:** 2026-05-10  
**Spec:** `CONSENSUS-scroll-bounce-2026-05-10.md`  
**Source:** `Sources/App/UI/Components/MessageCanvas.swift`

---

## Verdict: **APPROVE WITH CHANGES**

The spec is sound overall. Four changes, no conflicts, correct API usage. Two minor issues to address before implementation.

---

## 1. "Before" Snippet Accuracy

| Change | Match? | Notes |
|--------|--------|-------|
| Change 1 (scroll target) | ✅ Exact | `let targetId = messages.last?.id ?? "bottom-anchor"` matches current line |
| Change 2 (remove onChange) | ✅ Exact | Handler text matches exactly |
| Change 3 (remove asyncAfter) | ⚠️ Minor gap | Spec omits the comment line `// LazyVStack renders asynchronously — one-shot re-scroll after layout settles` that precedes the `asyncAfter` call. Must delete this comment too. |
| Change 4 (scrollBounceBehavior) | ✅ Exact | Current `.scrollBounceBehavior(.basedOnSize, axes: .vertical)` matches |

**Action:** Change 3 should specify removing the comment as well. Without it, a find-replace or manual edit will leave an orphaned comment.

---

## 2. Conflicts Between Changes

None. Changes 1 and 3 both touch `scrollToBottom()` but at different locations within the method. Changes 2 and 4 are in separate view modifier chains. No merge conflicts.

---

## 3. `.scrollBounceBehavior` Conditional API

```swift
.scrollBounceBehavior(isStreaming || thinkingState != .idle ? .never : .basedOnSize, axes: .vertical)
```

✅ Valid. The ternary produces `ScrollBounceBehavior.never` or `ScrollBounceBehavior.basedOnSize` — both valid enum cases. No type mismatch, no conditional expression issue.

---

## 4. Auto-Scroll After Removing `onChange(of: showStreamingBubble)`

**Concern: Narrow gap between `isStreaming` becoming true and streaming bubble appearing.**

Timeline:
1. `isStreaming` becomes true, `streamingContent` is empty → `onChange(of: isStreaming)` fires → `scrollToBottom()` targets `"streaming-bubble"` (but it doesn't exist yet; TypingIndicator is shown instead)
2. `streamingContent` becomes non-empty → `showStreamingBubble` becomes true → streaming bubble appears in LazyVStack

The removed `onChange(of: showStreamingBubble)` was the explicit scroll call for step 2. Without it, we rely on `defaultScrollAnchor(.bottom)` to keep the new content anchored.

**Assessment:** `defaultScrollAnchor(.bottom)` *should* handle this — SwiftUI anchors new content to the bottom when this modifier is active. The streaming bubble appearing counts as content addition. In practice this works on macOS 14+.

**Risk:** If macOS's ScrollView implementation doesn't re-anchor on content growth (only on initial layout), the view could stay stuck at the TypingIndicator position while the streaming bubble grows below it. This is the exact scenario called out in P2/Fix D2.

**Recommendation:** Proceed with the spec as-is, but test the "streaming starts from empty" case carefully. If the streaming bubble doesn't auto-scroll on first appearance, add `onChange(of: showStreamingBubble)` back with the improved target logic:

```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(animated: false)
    }
}
```

This is a safe fallback — it only fires once per streaming turn and the improved target logic prevents it from targeting the wrong element.

---

## 5. Edge Cases

### 5a. Thinking → Streaming transition
`thinkingState` changes from `.thinking` to `.streaming`. Target changes from `"thinking-bee"` to `"streaming-bubble"`. No explicit scroll call fires for this state change. `defaultScrollAnchor(.bottom)` handles the view swap — both IDs are at the bottom of the list, so position is maintained. **Low risk.**

### 5b. Orphaned comment
As noted in §1, the `// LazyVStack renders asynchronously...` comment must be removed along with the `asyncAfter` block. Leaving it would be confusing.

### 5c. Empty conversation
No messages, no streaming. `isStreaming = false`, `thinkingState = .idle`. Target: `messages.last?.id ?? "bottom-anchor"` → `"bottom-anchor"`. Bounce behavior: `.basedOnSize`. This matches current behavior. ✅

### 5d. Rapid state transitions (thinking → streaming → idle)
The dedup guard (`0.3s` cooldown) protects against rapid re-scrolls during these transitions. The conditional `scrollBounceBehavior` will flip between `.never` and `.basedOnSize`, but SwiftUI handles this as a single frame update — no visual bounce. ✅

### 5e. `thinkingState != .idle` scope
This covers both `.thinking` and `.streaming` enum cases, which is correct. Bounce is suppressed during both states, and allowed during `.idle`. ✅

---

## Required Changes Before Implementation

1. **Change 3:** Include the `// LazyVStack renders asynchronously — one-shot re-scroll after layout settles` comment in the deletion range.

## Recommended Testing Priority

Highest risk items first:
1. Short message streaming (content shorter than viewport — this is where `.scrollBounceBehavior(.never)` matters most)
2. Streaming start from empty state (where `onChange(of: showStreamingBubble)` was removed)
3. Thinking → Streaming transition (no explicit scroll call)

---

## Summary

The spec is implementable and correct. The only required change is including the orphaned comment in the asyncAfter deletion. The removed `onChange(of: showStreamingBubble)` creates a low-risk gap that should be validated in testing — if `defaultScrollAnchor(.bottom)` doesn't handle streaming bubble appearance, re-add it with the improved target logic as a quick fix.