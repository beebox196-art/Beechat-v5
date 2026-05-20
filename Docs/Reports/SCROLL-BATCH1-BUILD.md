# Scroll Remediation — Batch 1 Build Report

**Date:** 2026-05-19  
**Branch:** `fix/scroll-remediation`  
**Tag:** `PRE-SCROLL-REMEDIATION`  
**Build:** ✅ Succeeded (Debug, `platform=macOS`, arm64)  
**Scheme:** `BeeChatApp`

---

## Changes Made

### Fix 1: Remove forced `scrollToBottom` from `onChange(of: messages.count)`
**File:** `Sources/App/UI/Components/MessageCanvas.swift`

- Removed the `else if isAtBottom { scrollToBottom(proxy: proxy, animated: false) }` branch from the `onChange(of: messages.count)` handler.
- Retained `anchorMessageId` (load earlier) and `pendingTopicScroll` (topic switch) paths unchanged.
- `defaultScrollAnchor(.bottom)` now handles staying pinned during streaming content growth.

### Fix 1A: Short-content fallback scroll
**File:** `Sources/App/UI/Components/MessageCanvas.swift`

- Added `@State private var contentFillsContainer: Bool = false`
- Added `contentFillsContainer = geo.contentSize.height >= geo.containerSize.height` inside `onScrollGeometryChangeCompat` handler, before the hysteresis logic.
- Added conditional `if !contentFillsContainer { scrollToBottom(proxy: proxy, animated: false) }` at the end of `onChange(of: messages.count)`.
- This is the ONE legitimate use of forced scroll: when content is shorter than the viewport, `defaultScrollAnchor(.bottom)` is ignored by macOS and content aligns to the top.

### Fix 2: Remove `scrollToBottom` from `onChange(of: thinkingState)`
**File:** `Sources/App/UI/Components/MessageCanvas.swift`

- Removed `if newState == .thinking && isAtBottom { scrollToBottom(proxy: proxy, animated: false) }` from the `onChange(of: thinkingState)` handler.
- Retained the log line for debugging.
- `defaultScrollAnchor(.bottom)` handles the transition from user message to thinking indicator.

### Fix 7: Use `safeAreaInset(edge: .bottom)` for Composer
**File:** `Sources/App/UI/MainWindow.swift`

- Removed `Divider()` and `Composer(viewModel: composerViewModel, onSend: composerSend)` from the VStack at the bottom of the detail area.
- Added `.safeAreaInset(edge: .bottom)` modifier on `MessageCanvas(...)` containing a `VStack(spacing: 0)` with the `Divider()` and `Composer(...)`.
- The safeAreaInset content has `.background(themeManager.color(.bgSurface))` to prevent transparency.
- The `ZStack(alignment: .top)` wrapping `MessageCanvas + resetIndicator` remains at the MainWindow level — `safeAreaInset` is applied to `MessageCanvas` inside the ZStack.
- The `resetIndicator` is unaffected (top overlay, not impacted by bottom inset).

---

## Remaining Programmatic Scroll Calls

After Batch 1, the only `scrollToBottom` calls remaining in `MessageCanvas.swift` are:

1. **`onAppear`** — initial scroll on view load
2. **`onChange(of: topicId)`** — scroll on topic switch (via `pendingTopicScroll` for empty topics, direct `scrollToBottom` for non-empty)
3. **Short-content fallback** — only when `!contentFillsContainer`
4. **"Jump to Latest" button** — user-initiated

This matches the Telegram pattern: no programmatic scroll during streaming content growth.

---

## Deviations from Spec

None. All four fixes implemented exactly as specified.

---

## Notes from Reviews Considered

- **Q review (Fix 7):** Confirmed `resetIndicator` ZStack stays at MainWindow level. `safeAreaInset` applied to `MessageCanvas` inside the ZStack. ✅
- **Q review (Fix 1):** The `isAtBottom` flicker concern during send — the hysteresis (50pt enter / 120pt leave) makes this unlikely, but should be tested manually.
- **Kieran review (K5):** `safeAreaInset` with dynamic Composer height — no animation wrapper added yet. Kieran recommended `animation(.easeInOut(duration: 0.15), value: composerHeight)`. Since we don't have a `composerHeight` binding available at this level, this may need to be addressed in a follow-up if testing reveals jank. The Composer already has its own animation for height changes, so `safeAreaInset` should propagate the inset change smoothly.
- **Kieran review (K1):** macOS 14 `onScrollGeometryChangeCompat` fallback — `contentFillsContainer` will stay `false` on macOS 14 (no geometry tracking), meaning the short-content fallback will always fire. This is safe: on macOS 14 with no geometry data, `contentFillsContainer` defaults to `false`, and the `scrollToBottom` fallback will fire for every new message. Not ideal (we'd prefer it only for short content), but it won't cause bounce because on macOS 14 there's no streaming race condition from the geometry handler. A proper macOS 14 fallback for geometry tracking is a Batch 2+ concern.

---

## Testing Checklist (Manual — not yet performed)

- [ ] Messages appear smoothly without bouncing during streaming
- [ ] Scrolling up during streaming keeps position (no forced scroll-to-bottom)
- [ ] "Jump to latest" button appears when scrolled up and scrolls to bottom correctly
- [ ] Typing multi-line messages in Composer does NOT cause whitespace or focus jumps
- [ ] Switching topics scrolls to bottom of new topic correctly
- [ ] Cross-topic streaming (Topic A displayed while Topic B streams) — no bounce on A
- [ ] Thinking indicator appears without scroll disruption
- [ ] Streaming bubble grows smoothly without bounce
- [ ] Load earlier messages preserves scroll position (anchor on oldest visible message)
- [ ] Sidebar resize/collapse with new layout (Kieran recommendation)