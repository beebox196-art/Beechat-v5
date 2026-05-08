Updated: 2026-05-08T17:52:00Z
From/To: Q → next
Task: BC5-SPEC-005 — Fix scroll position detection (Jump to Latest button)
State: Implementation complete, committed (5358a38)
Next: Adam to test in live app — verify button hides when at bottom, appears when scrolled up
Blockers: None
Files: Sources/App/UI/Components/MessageCanvas.swift

## What was done

Replaced broken `GeometryReader` + `PreferenceKey` scroll detection with `onAppear`/`onDisappear` on a 120pt bottom anchor.

**Root cause:** LazyVStack deallocates off-screen views, causing PreferenceKey to fire with defaultValue (0), inverting detection. The coordinate math was also wrong (comparing viewport-relative minY against absolute thresholds).

**Changes:**
- Removed `BottomAnchorPreferenceKey` struct
- Removed `GeometryReader` overlay on bottom anchor
- Removed `enterBottomThreshold` / `leaveBottomThreshold` constants
- Removed `.coordinateSpace(name: "messageScrollView")` modifier
- Removed `.onPreferenceChange(BottomAnchorPreferenceKey.self)` handler
- Changed bottom anchor from 1pt to 120pt with `onAppear`/`onDisappear` (natural hysteresis)
- Added debouncing: 100ms delay on `isAtBottom = true`, 50ms on `isAtBottom = false`
- Kept all other logic intact: `isAtBottom`, `scrollProxy`, `scrollToBottom()` retry, Jump button, topic switching, streaming overrides, `WidthReader`/`WidthPreferenceKey`

**Build:** ✅ Succeeded
**Tests:** ✅ 87/87 passed