# Scroll Bar Bouncing — Diagnosis & Fix Report

**Project:** BeeChat v5  
**File:** `Sources/App/UI/Components/MessageCanvas.swift`  
**Date:** 2026-05-09  
**Severity:** Medium (recurring UX irritant)

---

## 1. Root Cause Analysis

The elastic/rubber-band bounce effect in the message canvas is caused by a **combination of missing modifiers and fragile scroll-to-bottom logic** that repeatedly perturbs the ScrollView's content offset.

### Primary Causes

| # | Cause | Evidence in Code |
|---|-------|-----------------|
| 1 | **Missing `.scrollBounceBehavior(.basedOnSize)`** | `ScrollView` has no bounce-behavior modifier. macOS defaults to elastic overscroll even when `LazyVStack` content is shorter than the viewport. |
| 2 | **Missing `.defaultScrollAnchor(.bottom)`** | No anchor set. When the view appears or resizes, the scroll position can drift, especially during keyboard show/hide or window resize. |
| 3 | **LazyVStack content < viewport height** | When a conversation has only a few short messages, total content height is less than the ScrollView bounds. Without `.basedOnSize`, macOS treats this as an infinitely scrollable surface and bounces. |
| 4 | **`Color.clear` bottom anchor with delayed state** | The 2pt invisible view at `.id("bottom-anchor")` has `onAppear`/`onDisappear` handlers that fire 100ms/50ms delayed tasks to update `isAtBottom`. These async state changes can interleave with `scrollTo` calls, causing layout recalculation and visual bounce. |
| 5 | **Multiple `DispatchQueue.main.async` delays in `scrollToBottom()`** | The animated path uses `DispatchQueue.main.async` + `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)`. This creates a ~500ms window where the scroll offset is being rewritten while the view is still laying out, which macOS interprets as elastic overscroll. |

### Why It Keeps Coming Back

Previous fixes likely patched only one of these (e.g., removed a dispatch delay or tweaked the anchor). Because there are **multiple interacting triggers**, the bounce resurfaces when another code path (topic switch, stream start, load-earlier) hits a different trigger.

---

## 2. What Other Apps Do

Research into iMessage, Telegram, Discord, Slack and professional SwiftUI chat implementations shows consistent patterns:

- **`.scrollBounceBehavior(.basedOnSize)`** is the standard fix for macOS 13.3+/iOS 17+. It disables bounce when content fits, enables it only when content overflows. This is what iMessage and Telegram effectively do natively.
- **`.defaultScrollAnchor(.bottom)`** (iOS 17+) is used to keep the view pinned to the bottom during size changes (keyboard open/close, window resize). Without it, the scroll offset can drift and cause rubber-banding.
- **Avoid `Color.clear` invisible anchors** for scroll-position detection. Professional implementations use `onScrollGeometryChange` (iOS 18+/macOS 15+) or `GeometryReader` inside the scroll content to detect proximity to bottom, not an invisible view that triggers `onAppear`/`onDisappear`.
- **`List` vs `ScrollView` + `LazyVStack`**: `List` handles bounce more naturally on macOS because it wraps `NSTableView`, but it sacrifices the layout control needed for custom chat bubbles. Most modern SwiftUI chat apps use `ScrollView` + `LazyVStack` with the bounce-behavior modifier.
- **No async delays for scroll-to-bottom**: The best implementations scroll synchronously or use a single `withAnimation` block. Multiple `DispatchQueue.main.async` calls are a known source of jitter.

---

## 3. The Fix

### 3.1 Add Two Missing Modifiers

Add these two modifiers to the `ScrollView`:

```swift
ScrollView(.vertical, showsIndicators: true) {
    LazyVStack(spacing: 0) {
        // ... existing content ...
    }
}
.scrollBounceBehavior(.basedOnSize, axes: .vertical)   // ← NEW: eliminates bounce when content < viewport
.defaultScrollAnchor(.bottom)                           // ← NEW: keeps view pinned to bottom
```

**Why these two:**
- `.scrollBounceBehavior(.basedOnSize)` tells SwiftUI: "only allow bounce if the content is actually larger than the container." This is the canonical fix for the "few messages bounce" problem.
- `.defaultScrollAnchor(.bottom)` ensures the scroll position starts at and stays anchored to the bottom. This prevents drift during resize, topic switch, and keyboard events.

**Availability:** Both require macOS 14+ / iOS 17+. BeeChat v5 targets macOS 14, so this is safe.

### 3.2 Clean Up `scrollToBottom()`

Replace the current `scrollToBottom()` implementation with a simpler, synchronous-first version:

```swift
private func scrollToBottom(animated: Bool = false) {
    guard let proxy = scrollProxy else { return }

    // During streaming/thinking, deduplicate: skip if scrolled recently
    if isStreaming || thinkingState != .idle {
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
        lastScrollTime = now
    }

    // Prefer scrolling to the last message when available
    let targetId = messages.last?.id ?? "bottom-anchor"

    if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(targetId, anchor: .bottom)
        }
    } else {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
}
```

**What changed:**
- Removed `DispatchQueue.main.async` wrapper around animated scroll.
- Removed `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` fallback.
- `withAnimation` on the main thread is sufficient; SwiftUI coalesces layout changes.

### 3.3 Harden the Bottom-Anchor Detection (Optional but Recommended)

The `Color.clear` + `onAppear`/`onDisappear` approach is fragile. Replace with `onScrollGeometryChange` if targeting macOS 15+ (iOS 18+), or keep the current approach but remove the debounce delays:

**Option A — macOS 15+ (preferred if available):**
```swift
.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { oldOffset, newOffset in
    // Detect if we're within 50pt of bottom
    // Update isAtBottom accordingly
}
```

**Option B — Keep `Color.clear` but remove debounce (minimal change):**
```swift
Color.clear
    .frame(height: 2)
    .id("bottom-anchor")
    .onAppear { isAtBottom = true }
    .onDisappear { isAtBottom = false }
```

The debounce tasks were added defensively but they create race conditions with `scrollTo`. Removing them makes the state update immediate and deterministic.

---

## 4. Exact Code Changes for `MessageCanvas.swift`

Here is the complete diff. Lines marked `+` are additions; lines marked `-` are removals.

```diff
@@ -54,6 +54,8 @@ struct MessageCanvas: View {
                 }
                 .scrollContentBackground(.hidden)
+                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
+                .defaultScrollAnchor(.bottom)
                 .background(
                     WidthReader { width in
@@ -62,22 +64,10 @@ struct MessageCanvas: View {
                     }
                 )
-                        Color.clear
-                            .frame(height: 2)
-                            .id("bottom-anchor")
-                            .onAppear {
-                                debounceTask?.cancel()
-                                debounceTask = Task {
-                                    try? await Task.sleep(nanoseconds: 100_000_000)
-                                    guard !Task.isCancelled else { return }
-                                    await MainActor.run { isAtBottom = true }
-                                }
-                            }
-                            .onDisappear {
-                                debounceTask?.cancel()
-                                debounceTask = Task {
-                                    try? await Task.sleep(nanoseconds: 50_000_000)
-                                    guard !Task.isCancelled else { return }
-                                    await MainActor.run { isAtBottom = false }
-                                }
-                            }
+                        Color.clear
+                            .frame(height: 2)
+                            .id("bottom-anchor")
+                            .onAppear { isAtBottom = true }
+                            .onDisappear { isAtBottom = false }
@@ -130,18 +120,10 @@ struct MessageCanvas: View {
     private func scrollToBottom(animated: Bool = false) {
         guard let proxy = scrollProxy else { return }
 
-        // During streaming/thinking, deduplicate: skip if scrolled recently
         if isStreaming || thinkingState != .idle {
             let now = Date()
             guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
             lastScrollTime = now
         }
 
-        // Prefer scrolling to the last message when available — more reliable than
-        // bottom-anchor because the anchor is only 2pt and ScrollView may not
-        // layout LazyVStack content immediately on topic switch.
         let targetId = messages.last?.id ?? "bottom-anchor"
 
         if animated {
-            DispatchQueue.main.async { [proxy] in
-                withAnimation(.easeInOut(duration: 0.2)) {
-                    proxy.scrollTo(targetId, anchor: .bottom)
-                }
-            }
-            // Fallback: re-scroll after layout settles (LazyVStack renders asynchronously)
-            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [proxy] in
+            withAnimation(.easeInOut(duration: 0.2)) {
                 proxy.scrollTo(targetId, anchor: .bottom)
             }
         } else {
-            // Synchronous — no animation, no fallback, no dispatch delay
             proxy.scrollTo(targetId, anchor: .bottom)
         }
     }
```

Also remove the now-unused `@State private var debounceTask: Task<Void, Never>?` property.

---

## 5. Secondary Improvements Worth Making

While in this file, consider these cleanups:

1. **Remove `debounceTask` state** — It will be unused after the fix.
2. **Use `messages.last?.id` consistently** — The comment about `bottom-anchor` being unreliable is correct. Since `messages.last?.id` is already the preferred target, consider removing the `Color.clear` bottom anchor entirely and scrolling only to the last message ID. This removes one more view from the hierarchy.
3. **Add `.scrollClipDisabled(false)` if needed** — If bubbles ever draw outside the ScrollView bounds (e.g., during animation), `.scrollClipDisabled(false)` (default) keeps them clipped. Only change this if you see visual artifacts.
4. **Consider `onScrollGeometryChange` for bottom detection** (macOS 15+) — This is the modern, Apple-recommended way to detect scroll position without invisible anchor views.
5. **Add a minimum height to `LazyVStack`** — If you want to guarantee the content always fills the viewport (another way to prevent bounce), add `.frame(minHeight: geometry.size.height)` inside the `LazyVStack`. However, `.scrollBounceBehavior(.basedOnSize)` is the cleaner solution.

---

## 6. Validation Steps

After applying the fix, verify:

| Test | Expected Result |
|------|-----------------|
| Open a new topic with 0–3 short messages | No bounce. Scroll bar stays still. |
| Send a message in a short conversation | Smooth auto-scroll to bottom, no rubber-band. |
| Open a long conversation (100+ messages) | Normal scrolling with natural bounce at top/bottom edges only. |
| Scroll up manually, then receive new message | "Jump to Latest" appears. Tap it → smooth scroll to bottom. |
| Click "Load earlier messages" | Scroll position anchors to first previously-visible message. No bounce. |
| Resize window during streaming | View stays anchored to bottom, no drift or bounce. |

---

## 7. Summary

The bounce is caused by **macOS defaulting to elastic overscroll** combined with **fragile async scroll logic** that repeatedly rewrites the content offset. The fix is **two missing modifiers** and **simpler, synchronous scroll-to-bottom logic**. This addresses all known triggers and should prevent the issue from recurring.
