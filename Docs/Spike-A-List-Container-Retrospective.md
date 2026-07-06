# SPIKE-A: List Container — Retrospective

> **Date:** 2026-07-06  
> **Branch:** `spike/list-container-a-2026-07-06` (preserved in git)  
> **Commits:** `6431e57` → `f70bedd` → `782b682` → `5edb2ff`  
> **Status:** Abandoned — fundamental SwiftUI/AppKit interop wall on macOS 26  
> **Outcome:** Baseline ScrollView+LazyVStack remains the production container  

---

## Problem Statement

Message canvas white-space jumps on window resize and font-scale change in the baseline `ScrollView`+`LazyVStack` container. Observed gaps of 4176pt, 3377pt, and 2728pt during resize events. The hypothesis was that a SwiftUI `List`-based container would eliminate layout invalidation artefacts because List manages row lifecycle internally.

## Approach

Replace the `ScrollView`+`LazyVStack` message canvas (`spikeScrollContainer`) with a `List`-based variant (`spikeListContainer`) gated behind compile flag `-DSPIKE_LIST_CONTAINER`. Key design choices:

- `List` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`
- Each message row wrapped in `.listRowInsets(EdgeInsets())` to zero insets
- `.listRowSeparator(.hidden)`, `.listRowBackground(...)` per row
- Trailing `Color.clear` row tagged `"bottom-anchor"` for `scrollTo`
- `isAtBottom` tracking via `onScrollGeometryChangeCompat` (80pt threshold)
- `SpikeScrollTrace` / `SpikeScrollTraceBootstrap` JSONL instrumentation added for diagnostics

## Bugs Found and Fixed (on spike branch only)

### Bug 1 — White-space on resize/font-scale change

**Symptom:** Large white-space blocks reappear when resizing window or changing font scale.  
**Root cause:** `List` relays out rows but `onChange(of: measuredWidth)` and `onChange(of: themeManager.fontScale)` didn't trigger `scrollTo("bottom-anchor")`.  
**Fix (commit 782b682):** Added `onChange(of: measuredWidth)` and `onChange(of: themeManager.fontScale)` inside `spikeListContainer`, guarded by `isAtBottom`, calling `proxy.scrollTo("bottom-anchor", anchor: .bottom)`.  
**Result:** Static white-space resolved. Resize and font-scale changes now scroll to bottom correctly.

### Bug 2 — Bubble width capped at ~50% of window

**Symptom:** Message bubbles never exceed ~50% of visible width regardless of window size. Reported as 81 characters max.  
**Root cause:** macOS `List` with `.listStyle(.plain)` adds ~20pt horizontal content margins per side. `WidthReader` in `.background()` measures the full outer width, but rows render in the narrower content area. `canvasWidth * 0.66` calculates against the outer width while being constrained by the inner width.  
**Fix (commit 5edb2ff):** Added `ListContentMarginsModifier` applying `.contentMargins(.horizontal, 0, for: .scrollContent)` on macOS 15+ (no-op on macOS 14).  
**Result:** Margins removed, but this didn't fix the deeper propagation issue (see below).

### Bug 3 — Topic switch / Jump-to-Latest not scrolling to bottom

**Symptom:** Switching topics leaves the view at the top; Jump-to-Latest button does nothing.  
**Root cause:** `.onChange(of: topicId)` fires synchronously during the SwiftUI view update cycle, before the `List` has laid out rows for the new topic. `proxy.scrollTo("bottom-anchor")` silently fails because the target ID doesn't exist yet.  
**Fix (commit 5edb2ff):** Set `isAtBottom = true` on topic switch and wrap `proxy.scrollTo` in `DispatchQueue.main.async` to defer one layout pass.  
**Result:** Partially worked but unreliable — List layout timing is non-deterministic.

## Why It Was Abandoned

**Fatal issue: PreferenceKey propagation failure on macOS 26 (Tahoe).**

Debug overlays revealed that `onPreferenceChange` does not fire inside `List` `.background()` modifiers on macOS 26. The `WidthReader` (a `GeometryReader` in `.background()` that reports width via `WidthPreferenceKey`) never updates `measuredWidth`. It stays at the `CanvasWidthKey.defaultValue` of 1200pt forever.

This means:
- **Bubble width is hardcoded** — `canvasWidth * 0.66` = 792pt regardless of actual window width
- **`onChange(of: measuredWidth)` never fires** — the resize scroll-to-bottom fix is dead code
- **Environment propagation is unreliable** — `@Environment(\.canvasWidth)` inside `MessageBubble` may also be stuck at the default

This is a SwiftUI/AppKit interop wall. The macOS `List` is backed by `NSScrollView` + `NSTableView`, and preference keys from SwiftUI `ViewModifier`s placed in `.background()` don't propagate through the AppKit bridging layer. Each attempted fix exposed another layer of incompatibility.

**Additional concern:** The AppKit backing also ignores SwiftUI `defaultScrollAnchor(.bottom)`, meaning topic-switch anchoring relies entirely on manual `scrollTo` calls — which are timing-sensitive and fragile.

## What Didn't Work

| Approach | Why It Failed |
|---|---|
| `WidthReader` via `.background()` + `PreferenceKey` | `onPreferenceChange` never fires inside List on macOS 26 |
| `ListContentMarginsModifier` `.contentMargins(.horizontal, 0)` | Fixes margins but doesn't fix width propagation |
| `DispatchQueue.main.async` wrap on `scrollTo` | Works sometimes; List layout is non-deterministic |
| `isAtBottom = true` on topic switch | Helps intent but doesn't fix the timing issue |
| Debug overlays in `@Environment(\.canvasWidth)` | Overlays clipped by List row geometry; couldn't confirm propagation |

## Architecture Context

- **Baseline container:** `spikeScrollContainer` — `ScrollViewReader` + `ScrollView` + `LazyVStack(spacing: 0)`. Pure SwiftUI. Works as documented. Has the original white-space-on-resize bug (separate issue, addressable with targeted `onChange` handlers).
- **Spike container:** `spikeListContainer` — `ScrollViewReader` + `List` + `.listStyle(.plain)`. AppKit-backed. Preference keys don't propagate. Multiple fundamental incompatibilities with macOS 26.
- **Gating:** All spike code is wrapped in `#if SPIKE_LIST_CONTAINER`. Baseline is completely untouched.
- **Instrumentation:** `SpikeScrollTrace` / `SpikeScrollTraceBootstrap` added for diagnostics. These log scroll geometry events to JSONL and are also gated by the compile flag.

## Key Files (on spike branch)

| File | Relevance |
|---|---|
| `Sources/App/UI/Components/MessageCanvas.swift` | Both container variants; `spikeListContainer` at ~line 161, `spikeScrollContainer` at ~line 105 |
| `Sources/App/UI/Components/MessageBubble.swift` | `BubbleWidthModifier` uses `@Environment(\.canvasWidth)` for `maxWidth: canvasWidth * 0.66` |
| `Sources/App/UI/Theme/Theme.swift` | Spacing tokens (lg=16pt used for horizontal padding) |
| `Sources/App/UI/Theme/Tokens/SpacingToken.swift` | Token definitions |

## If We Revisit

Possible paths forward (untested, for future reference):

1. **Targeted ScrollView fixes** — Address the white-space bug on the baseline `ScrollView`+`LazyVStack` with specific `onChange` handlers for geometry changes. This is the lowest-risk path.

2. **Manual width tracking outside List** — Pass width via `@State` on the parent view (not via PreferenceKey) and inject it directly as `.environment(\.canvasWidth, width)`. This avoids the PreferenceKey propagation issue but requires restructuring how width flows into the List.

3. **UIKitRepresentable / NSViewRepresentable** — Wrap an `NSTableView` directly with full control over layout, bypassing SwiftUI's List entirely. High effort, full control.

4. **Wait for Apple fixes** — macOS 26 is still in beta (build 25F80 at time of writing). PreferenceKey propagation through List backgrounds may be a known SwiftUI regression that gets fixed.

5. **SwiftUI LazyVStack with scrollTargetLayout** — iOS 17+/macOS 14+ introduced `scrollTargetLayout` and `scrollPosition` APIs that could replace `defaultScrollAnchor`. May provide better scroll anchoring without switching to List.

## Archived Artifacts

- **Spike binary:** `/Users/openclaw/projects/BeeChat-v5/archive/BeeChatApp-SPIKE-A.app` (commit `5edb2ff`, ad-hoc signed)
- **Spike branch:** `spike/list-container-a-2026-07-06` in git
- **Baseline app:** `/Applications/BeeChatApp.app` (commit `72b1cd3`, v0.9.5c 2026.07.04-html, production)

---

*Documented by Bee, 2026-07-06. Revisit this before attempting another List-based message container.*