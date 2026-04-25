# FEAT-002: Thinking Bee Indicator

**Priority:** Medium  
**Status:** Spec — awaiting review  
**Author:** Bee (Coordinator)  
**Date:** 2026-04-25

## Problem

When a user sends a message in BeeChat, there's a visual gap between pressing send and the first streaming delta arriving. During this "thinking" window the app appears stalled — no feedback, no animation. Users report thinking the app has frozen when it's actually waiting for the AI to start responding.

## Design Concept

A small animated bee that indicates AI processing state:

| State | Visual | When |
|-------|--------|------|
| **Thinking** | Bee with animated wings (buzzing), slight bounce | Message sent → first delta arrives |
| **Streaming** | Not shown (StreamingBubble handles this) | First delta → final event |
| **Dormant** | Small sleeping bee icon in sidebar session row | Topic is idle (no active stream) |

## Architecture: Self-Contained Module

**This feature is implemented as an isolated module with a single integration point.** It must be possible to remove the entire feature by reverting the integration point and deleting one folder.

### New Files (all in `Sources/App/UI/Components/ThinkingBee/`)

```
ThinkingBee/
├── ThinkingBeeIndicator.swift    — Main view (thinking + dormant states)
├── BeeWingsAnimation.swift       — Wing path + flapping animation (SwiftUI only, no Lottie)
├── ThinkingState.swift           — Observable state machine (idle → thinking → streaming)
└── ThinkingBeeStyles.swift       — Theme-aware sizing/colour tokens
```

### Integration Points (minimal surface area)

**1. `ComposerViewModel.swift`** — Fire callback on send:
```swift
// Add one property:
var onMessageSent: (() -> Void)?

// In send(), after clearing input:
func send() async {
    guard canSend else { return }
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    inputText = ""
    onMessageSent?()          // ← NEW: notify thinking state
    do {
        try await messageViewModel?.sendMessage(text: text)
    } catch {
        print("[ComposerViewModel] Send failed: \(error)")
    }
}
```

**2. `SyncBridgeObserver.swift`** — Wire thinking state to streaming lifecycle:
```swift
// Add one published property:
var thinkingState: ThinkingState = .idle

// In didStartStreaming:
self.thinkingState = .streaming   // bee hides, StreamingBubble takes over

// In didStopStreaming:
self.thinkingState = .idle        // bee goes dormant in sidebar
```

**3. `MessageCanvas.swift`** — Show ThinkingBeeIndicator between messages and composer:
```swift
// Updated init signature:
MessageCanvas(
    messages: ...,
    isStreaming: ...,
    streamingContent: ...,
    thinkingState: syncBridgeObserver.thinkingState  // NEW
)

// Insert BEFORE the existing TypingIndicator check:
if thinkingState == .thinking {
    ThinkingBeeIndicator(mode: .thinking)
} else if isStreaming && streamingContent.isEmpty {
    // Suppress TypingIndicator during thinking→streaming transition
    // to prevent brief flash between ThinkingBee and StreamingBubble
    if thinkingState != .streaming {
        TypingIndicator()
    }
} else if showStreamingBubble {
    StreamingBubble(content: streamingContent)
}
```

**4. `MainWindow.swift`** — Show dormant bee in sidebar session row:
```swift
// In SessionRow, add a trailing icon when the topic is idle and recently active:
// hasRecentActivity = topic's lastActivityAt is within the last 5 minutes
if thinkingState == .idle && topic.lastActivityAt > Date.now - 300 {
    ThinkingBeeIndicator(mode: .dormant)
}
```

**Definition:** `hasRecentActivity` uses the existing `lastActivityAt` column on the Topic model. A 5-minute window (`Date.now - 300`) determines "recent." The value is computed per-topic in the sidebar, not stored globally. No debounce needed — `lastActivityAt` is a fixed timestamp that doesn't flicker at boundaries.

### What Does NOT Change

- No changes to `SyncBridge`, `EventRouter`, `BeeChatPersistence`, or `BeeChatGateway`
- No changes to `StreamingBubble` or `TypingIndicator` — they remain as fallbacks
- No changes to the message pipeline or data layer
- `ThinkingState` is a new type that does not replace or alias `isStreaming`

## ThinkingState Machine

```swift
/// Isolated state for the thinking indicator.
/// Does not touch existing state — observes it.
enum ThinkingState {
    case idle       // No activity — show dormant bee in sidebar
    case thinking   // Message sent, waiting for first delta — show buzzing bee
    case streaming  // Deltas arriving — hide bee, StreamingBubble handles it
}
```

**Transitions:**
| From | To | Trigger |
|------|----|---------|
| idle | thinking | `ComposerViewModel.onMessageSent` |
| thinking | streaming | `SyncBridgeObserver.didStartStreaming` |
| thinking | idle | `SyncBridgeObserver.didStopStreaming` (no deltas arrived — error or empty response) |
| streaming | idle | `SyncBridgeObserver.didStopStreaming` |

**Edge case — rapid messages:** If the user sends another message while already thinking, `onMessageSent` fires again but state is already `.thinking`, so no visual glitch.

**Edge case — sending while streaming:** If the user sends a second message while a stream is active, `onMessageSent` must NOT downgrade state from `.streaming` to `.thinking`. The invariant is: once streaming, stay streaming until `didStopStreaming`. Implementation:
```swift
// In onMessageSent handler:
if thinkingState != .streaming {
    thinkingState = .thinking
}
```

**Edge case — streaming starts before thinking:** If `didStartStreaming` fires before `onMessageSent` (gateway is very fast), state goes directly to `.streaming`. The thinking bee never shows, StreamingBubble takes over. Correct behaviour.

## Bee Animation Design

**Pure SwiftUI — no Lottie, no third-party dependency.**

### Thinking Mode (Buzzing Bee)
- Body: Small rounded capsule (8×12pt), colour from theme `.accentPrimary`
- Wings: Two ellipses that rotate on the Y-axis (flapping), 3° tilt animation
- Movement: Gentle vertical bounce (2pt, easeInOut, 1.5s cycle)
- Wing flap speed: 120ms per cycle (visible buzz, not seizure-inducing)
- Accessibility: `.accessibilityLabel("AI is thinking")`, `.accessibilityHint("Waiting for response")`
- `.accessibilityAnnouncement("AI is thinking")` on state change to `.thinking` so VoiceOver users are notified
- `@Environment(\.accessibilityReduceMotion)` — when active, wings are static (no flap), body uses subtle opacity pulse (0.6↔1.0, 2s cycle) instead of bounce

### Dormant Mode (Sleeping Bee)
- Body: Same capsule, slightly desaturated colour from theme `.textSecondary`
- Wings: Static, folded down
- Zzz: Tiny "z" text that fades in/out (1.5s cycle)
- Size: 16×16pt icon for sidebar use
- Accessibility: `.accessibilityLabel("Available")` — or omit from VoiceOver entirely (decorative, not actionable). Prefer omission via `.accessibilityHidden(true)` since dormant state is the default and not meaningful to announce.

### ThinkingBeeStyles
```swift
enum ThinkingBeeSize {
    case canvas    // Larger, for message area (32×32pt)
    case sidebar   // Smaller, for session row (16×16pt)
}
// All colours pulled from ThemeManager tokens — no hardcoded values
```

## Rollback Plan

To remove this entire feature:
1. Delete `Sources/App/UI/Components/ThinkingBee/` folder
2. Remove 3 lines from `MessageCanvas.swift` (the `if thinkingState == .thinking` block)
3. Remove 2 lines from `ComposerViewModel.swift` (`onMessageSent` property + call)
4. Remove 2 lines from `SyncBridgeObserver.swift` (`thinkingState` property + assignments)
5. Remove sidebar icon from `MainWindow.swift`

Total: ~10 lines removed from 4 existing files. No data layer changes to revert.

## Validation Criteria

1. **Build:** `xcodebuild -scheme BeeChatApp -destination 'platform=macOS' build` passes
2. **No regressions:** Existing streaming, TypingIndicator, and StreamingBubble all work unchanged
3. **Thinking bee shows** between message send and first streaming delta
4. **Thinking bee hides** when streaming starts (StreamingBubble replaces it)
5. **Dormant bee shows** in sidebar for idle topics (optional — can defer to polish)
6. **Accessibility:** VoiceOver announces "AI is thinking" when bee appears
7. **Theme-aware:** Bee uses theme colours, not hardcoded values
8. **Removability:** Feature can be removed by deleting folder + 10 lines in 4 files

## Out of Scope

- Lottie animations (pure SwiftUI only)
- Sound effects
- Custom animation per theme
- Bee in the composer text field (just the message area + sidebar)
- Changes to data layer, SyncBridge, or EventRouter