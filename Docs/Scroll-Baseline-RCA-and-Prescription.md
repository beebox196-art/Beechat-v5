# Message Canvas Scroll — Root Cause Analysis & Fix Prescription

**Author:** Fable review · **Date:** 2026-07-09 · **Scope:** ScrollView+LazyVStack baseline only (List is a confirmed dead end per Spike-A retrospective)
**Verdict up front: all three bugs are solvable on the current architecture.** Nothing here is fundamentally broken on macOS 26. Bug 3 is *mitigable to visually calm* rather than perfectly eliminable — its tail is asynchronous WebView height physics, not a SwiftUI defect.

---

## 0. Two findings from the repo the brief didn't include

**0.1 The regression is real and attributable.** `git log` on MessageCanvas.swift shows commit `2c507d5` ("strip auto-scroll code causing bounce — let defaultScrollAnchor handle it") removed, in one sweep: the `onChange(of: topicId)` scroll (→ Bug 1 born), the `onChange(of: messages.count)` / streaming scrolls, **and the isAtBottom hysteresis** (enter-threshold 50px / leave-threshold 120px, replaced by today's single 80px test). The stripped hysteresis is why the jump button now flickers during streaming/layout settle. An earlier commit `b40e9db` ("Fix blank space on topic switch: reduce anchor, defer scroll, target last message") shows topic-switch scrolling *had* a working treatment that was later discarded. So: not imagination — the rollback state is objectively worse than the pre-spike state, and we know exactly which lines to re-earn.

**0.2 Bubbles are conditionally WKWebView-backed with async height.** `MessageContent.swift`: when `conversion.needsWebView` (tables, unknown tags, resource caps), the bubble is a `MessageWebView` whose height starts at **40pt** and arrives later via ResizeObserver (JS) → `bcHeight` message → async binding write → `.frame(height: settledWebViewHeight)`. Content height therefore changes *after* cells materialize — by hundreds of points for table-heavy messages. This is the dominant term in Bug 2's large misses and a first-class driver of Bug 3.

**0.3 macOS 14 reality check.** `onScrollGeometryChangeCompat` no-ops below macOS 15, so `isAtBottom` never leaves its initial `true` on macOS 14 — **the jump button already never appears there.** Gating the Bug-2 fix to macOS 15+ costs nothing that macOS 14 users currently have.

---

## 1. Root Cause Analysis

### Bug 1 — topic switch doesn't scroll to bottom

`defaultScrollAnchor(.bottom)` (single-argument, macOS 14 form) does two things: positions content at the anchor **when the scroll view instance first resolves layout**, and keeps content pinned to the anchor on content-size changes **only while the position is still at the anchor** (i.e., the user hasn't scrolled away). It is a *default*, in the precise sense: it stops governing the moment the scroll position has a user-determined value.

On topic switch, nothing about the view's *identity* changes — it's the same `ScrollView` at the same position in the view tree; only the `messages` data changed. SwiftUI diffing keeps the same underlying scroll view instance, and with it the current scroll offset (clamped to the new content size). There is no "initial layout" event, so the anchor never re-applies. If the user was scrolled up in topic A, they land scrolled-up-somewhere in topic B. The `onChange(of: topicId)` comment ("defaultScrollAnchor handles it") encodes a false premise.

**Answer to Key Question 1:** initial-per-*view-identity*, not per-content. Content replacement within the same identity never re-triggers it.

### Bug 2 — "Jump to Latest" stops short

`ScrollViewProxy.scrollTo(_:anchor:)` resolves the target's frame from the **current** layout and animates to a fixed computed offset. Two stacked error sources make that offset stale:

1. **Lazy estimation.** `LazyVStack` assigns estimated extents to unmaterialized cells. A scroll target far below the viewport has its offset computed from estimates; as the scroll animates, cells materialize with real heights, content size shifts, and the animation — which does **not** retarget — lands at the old, wrong coordinate. Error accumulates with transcript length and bubble-height variance.
2. **Async WebView heights (the "hundreds of points").** Even *materialized* WebView bubbles start at 40pt and grow when ResizeObserver reports. A single table bubble between the viewport and the bottom invalidates the computed offset by its full settle delta, after the scroll has landed.

The 4px `bottom-anchor` is a perfectly good *target identity* (**Key Question 6:** it's always present, height is irrelevant, and switching to the last message's id would inherit the identical estimation problem while adding churn as the last message changes). The anchor is not the problem — the *coordinate it resolves to* is stale by the time the animation finishes.

**Answer to Key Question 3:** yes, this is the known failure mode — estimated extents plus post-hoc content-height changes; `scrollTo` computes once and never re-resolves.

### Bug 3 — white-space gaps on resize / font-scale change

A width change triggers a multi-stage reflow under an anchored scroll view:

1. `WidthReader` (GeometryReader in `.background`) publishes the new width via PreferenceKey → `measuredWidth` @State → environment → **every bubble re-lays** (this is a two-pass layout by design: pass 1 measures, pass 2 re-renders content at new widths). During live window-resize this runs **per resize tick**, including for sub-pixel floating-point deltas.
2. Native text bubbles re-wrap synchronously, but off-screen lazy cells keep stale estimated heights until re-materialized — so total content height is a mix of fresh-real, stale-real, and estimated values mid-drag.
3. Every WebView bubble independently re-wraps in JS and reports a new height **asynchronously**, arriving over multiple frames after the resize tick.
4. Meanwhile the scroll view is trying to maintain an offset (and the single-arg anchor tries to hold bottom if you're there) against a content height that is thrashing. The visible symptom is exactly what you'd predict: transient white space where the coordinate space says content should be but the settled heights disagree — until everything converges.

Font-scale change is the same cascade, plus a CSS re-render inside every WebView. **Answer to Key Question 4:** the combination isn't "known broken" as such — it's each mechanism behaving as documented, stacked; and no, a `scrollPosition` binding doesn't help here (it doesn't change how heights settle).

---

## 2. Solvability

| Bug | Solvable on ScrollView+LazyVStack? | Degree |
|---|---|---|
| 1 — topic switch | **Yes, completely and deterministically** | structural fix, no timing code |
| 2 — jump stops short | **Yes, completely on macOS 15+** (which is where the button exists at all — §0.3) | edge-targeted scroll |
| 3 — resize white-space | **Yes, to visually calm** | mitigation package; the async-WebView tail is physics, but it can be hidden at the reading edge and massively reduced in frequency |

Nothing requires List, AppKit, or architecture change.

---

## 3. Prescription

### Fix 1 — topic switch: change the *identity*, don't chase the timing

Apply `.id(topicId)` to the **ScrollViewReader subtree inside MessageCanvas** (not to MessageCanvas at the call site). On topic switch SwiftUI then tears down and rebuilds the scroll view — and `defaultScrollAnchor(.bottom)` applies as a genuine initial layout, the one path that demonstrably already works (initial appearance is correct today, including with lazy estimation, because SwiftUI materializes from the anchored end).

- **Why inside, not at the call site:** keeps MessageCanvas's `@State` alive — critically `measuredWidth`, which would otherwise reset to 1200 and flash wrong bubble widths until the preference round-trip completes.
- In `onChange(of: topicId)`: set `isAtBottom = true` (the fresh scroll view *is* at bottom; the geometry callback will confirm) and `anchorMessageId = nil` (kills a stale load-earlier scroll racing across a topic switch).
- **This is the only approach with zero races** — and the answer to **Key Question 5**: `onChange(of: topicId)` fires in the *same update transaction* as the content swap, so any `proxy.scrollTo` there targets the outgoing layout; `DispatchQueue.main.async` lands after an unknowable number of lazy-materialization and WebView-height passes — that's why deferred scrolls are a lottery. Identity change removes the sequencing question instead of trying to win it. Don't scroll after the load; make it a load.
- macOS 14-safe: `.id` and `defaultScrollAnchor` are both 14 APIs. No gates.
- **Key Question 2** (scrollPosition(id:) for topic switch): it exists on macOS 14 and would need `.scrollTargetLayout()` on the LazyVStack, but it inherits the same post-swap timing/estimation exposure and adds a second scroll-control system. Not recommended for this bug; the identity fix strictly dominates.

### Fix 2 — jump to latest: target the *edge*, not a view

On macOS 15+, attach `.scrollPosition($position)` where `position` is the **`ScrollPosition` struct**, and make the button call `position.scrollTo(edge: .bottom)` (inside `withAnimation`). Edge targets are resolved by the scroll view against **live content size** — not from a child view's estimated frame — and remain correct as WebView heights settle. This lands at the true bottom in one click, by construction. Structure it as a small `@available(macOS 15)`-gated wrapper subview owning the `ScrollPosition` state, so the macOS 14 build compiles cleanly.

- Keep `ScrollViewReader` **solely** for the load-earlier anchor scroll. Do not also add a `scrollPosition(id:)` binding — one programmatic controller per scroll view; mixing them is how you get fights.
- Remove `isAtBottom = true` from the button action: with a true edge landing, `onScrollGeometryChange` sets it; the manual write can only race it.
- **Restore the hysteresis lost in the rollback** (§0.1): enter < 50px, leave > 120px. This stops button flicker during streaming and height-settle, and pairs with the anchor-role fix below.
- macOS 14 fallback: none needed — the button never shows there (§0.3). Leave the existing `proxy.scrollTo` path as dead-code-tolerant or document 14 as no-jump-button.

### Fix 3 — resize white-space: a package of three (plus one flagged option)

**(a) Anchor roles, macOS 15+:** replace the single-arg anchor (under `#available`) with `defaultScrollAnchor(.bottom, for: .initialOffset)` **plus** `defaultScrollAnchor(.bottom, for: .sizeChanges)`. The `.sizeChanges` role explicitly pins the reading edge while content height thrashes — settle then happens *above* the viewport, invisible to a user at the bottom, which is where chat users live. On macOS 14 the single-arg form already approximates this when at-anchor; keep it as the fallback branch.

**(b) Kill the width churn:** in `onPreferenceChange(WidthPreferenceKey.self)`, round the incoming width to whole points and assign only when it actually changed by ≥1pt — sub-pixel FP deltas currently re-lay every bubble repeatedly during live resize. Wrap the assignment so the width change doesn't animate (`Transaction` with animations disabled): reflow should snap, not tween — tweened intermediate heights are visible as traveling gaps.

**(c) Calm the WebView settle (touches MessageContent.swift — outside MessageCanvas, flagged per constraints, but it is not bubble-*width* logic):** height-binding writes from `bcHeight` should be non-animated and coalesced — apply the same discipline commit `16b0130` gave StreamingBubble (monotonic growth during streaming) to settled messages: ignore sub-point deltas, snap without animation. Every async height write is a layout event under an anchored scroll view; halving their number roughly halves Bug 3's visible activity.

**(d) Optional, explicitly bending the "stay on LazyVStack" constraint — offered as a measured experiment, not a prescription:** swap `LazyVStack` → `VStack` for the message page. With load-earlier pagination the rendered set is bounded, and a non-lazy stack has **no estimated extents at all** — Bug 2's estimation term and Bug 3's stale-estimate gaps vanish categorically; only the WebView-settle term remains. The cost is real: every `needsWebView` bubble in the page holds a live WKWebView simultaneously. Decision procedure: measure a worst-case topic (page size × fraction of WebView bubbles × memory per web process); if typical pages are ≤ ~50 messages with few WebViews, this is the single highest-leverage change available. Try (a)–(c) first; reach for (d) with data.

### Landing order

1 (identity) → 2 (hysteresis + edge jump) → 3a/3b (canvas-local mitigations) → 3c (MessageContent) → optionally 3d with measurements. Each step is independently shippable and testable; 1 also reduces the *frequency* of 2 and 3 (every topic switch now starts at a clean bottom).

---

## 4. Risk Assessment

| Fix | Could break | Interacts with | Files touched | macOS 14 |
|---|---|---|---|---|
| 1 `.id(topicId)` | Per-topic scroll memory is lost (desired here — the product wants bottom). Lazy caches discarded per switch: one extra materialization pass, imperceptible against the bug. Stale `anchorMessageId` race — closed by nilling it in the same `onChange` | Makes Bugs 2/3 rarer; no conflict with load-earlier (anchor state survives in MessageCanvas) | MessageCanvas only | ✅ safe, no gates |
| 2 `ScrollPosition` edge jump | Coexistence bugs if a `scrollPosition(id:)` binding is *also* added — don't. Animation style of `position.scrollTo` should be verified once on macOS 26 (Tahoe) and 15 | Complements 3a (both consult live content size); ScrollViewReader retained for load-earlier only | MessageCanvas only | ✅ gated; button doesn't exist on 14 anyway |
| 2b hysteresis restore | UX-visible change in when the button appears (intended); thresholds may want tuning with 3a active | Reduces flicker that 3's height-settle currently causes | MessageCanvas only | ✅ (inert on 14) |
| 3a anchor roles | Behavior change while user is mid-scroll during resize (content pins to bottom only when at bottom — role applies at-anchor; verify feel) | Pairs with 2; supersedes part of what the single-arg anchor did | MessageCanvas only | ✅ gated, single-arg fallback |
| 3b width rounding + no-animate | A 1pt rounding is invisible at 0.66×; risk ≈ nil. If bubbles ever need sub-point precision, revisit | Reduces load feeding 3a | MessageCanvas only | ✅ |
| 3c WebView settle | Touches MessageContent.swift (outside MessageCanvas — flagged). Coalescing must never *drop* a final height (coalesce, don't debounce-forever) | Reduces the async term in Bugs 2 & 3 | MessageContent.swift | ✅ |
| 3d VStack swap | Memory/CPU with many live WKWebViews; startup cost on huge pages | Eliminates estimation everywhere; makes 2's macOS 14 story moot too | MessageCanvas only (one word) + perf validation | ✅ |

**Answers to the six key questions are embedded above:** Q1 → §1/Bug 1 (initial-per-identity). Q2 → Fix 1 discussion (usable but dominated by `.id`). Q3 → §1/Bug 2 (estimates + async heights; edge-targeting is the correct pattern). Q4 → §1/Bug 3 (stacked documented behaviors; scrollPosition doesn't help; anchor-roles + churn reduction do). Q5 → Fix 1 (same-transaction firing; make it a load, not a scroll). Q6 → §1/Bug 2 (anchor is fine; keep it; the coordinate is the problem).
