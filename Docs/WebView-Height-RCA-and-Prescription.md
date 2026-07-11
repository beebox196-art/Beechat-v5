# WebView Height Pipeline — RCA & Prescription (v0.9.5e residuals)

**Author:** Fable review · **Date:** 2026-07-11 · **Scope:** the four residual symptoms on WebView-heavy topics reported after the v0.9.5e manual pass. Builds on `Docs/Scroll-Baseline-RCA-and-Prescription.md` and `Docs/Scroll-Fixes-Implementation-Review.md`. Analysis + prescription only — no code changed.

---

## Verdict up front

**Bee's diagnostic frame (WebView-only cluster) is right. Bee's mechanism is half-right. Bee's proposed fix is wrong and should not be built.**

The disease is not that Swift's coalescing guard is too permissive — it's that **the JS reporter is dishonest**. `bcHeight` reports carry a bare number with no statement of *what* was measured: reports fire against an **empty content div** (spec-guaranteed, see R1), against layouts computed at a **width that no longer exists** (R2), and against **fresh empty documents after WebContent process kills** (R3). Swift cannot distinguish a garbage report from a real reflow, so *any* Swift-side acceptance policy — F1's band, monotonic-forever, Bee's `maxHeightSeen` + settle window — is guessing. Each policy choice just picks which garbage class gets through.

The fix is to make reports **self-describing and transactional at the source** (never report an empty document; tag every report with the width it was measured at and a content generation), and have Swift accept **only reports that match the layout it is currently sizing**. No timers, no settle windows, no height heuristics. Three focused changes: `MessageTemplate.html`, the `bcHeight` case in `MessageWebView.swift`, and a height-seed cache in `MessageContent.swift`. Fix 3c's 8pt band becomes unnecessary and is removed — replaced by a stronger invariant, not weakened.

**Why maxHeightSeen + settle window must not be built** (the adversarial answer Bee asked for):

1. **It locks garbage peaks.** If an interim-tall report exists (it does — R2's wrong-width layouts), `maxHeightSeen` *is* the garbage value. Rejecting downward moves during the window locks the bubble at a height that was never true. This is F1's permanent-whitespace bug wearing a new hat.
2. **A settle window is a timer race.** How long? Opening a Beelinks-sized topic spins up N WebContent processes; on a loaded machine that takes seconds, and it's variable. Any fixed window loses on some machine some day — the same class of async lottery the original RCA rejected for scroll timing (`DispatchQueue.main.async` deferred scrolls). We removed timing guesses from the scroll layer; do not reintroduce them one layer down.
3. **It punishes the streaming bubble.** During streaming, content legitimately reflows shorter (a code fence closes, a table completes). "Reject downward during settle" either freezes those or requires deciding when streaming counts as "settled" — more guessing.
4. **It leaves the reporter lying.** Every future consumer of `bcHeight` inherits the problem. Fix the reports and every consumer gets honest data forever.

---

## 1. Root cause analysis — the three dirty-report classes

The pipeline: ResizeObserver on `#content` (`MessageTemplate.html:149`) → `bcHeight` bare number → coordinator (`MessageWebView.swift:151`) → band guard → `parent.height` binding → `.frame(height:)` on a bubble inside the anchored LazyVStack. Three classes of report describe a layout that is *not* the one Swift is sizing:

### R1 — The empty-document report (spec-guaranteed, not speculative)

`MessageTemplate.html:149`: `new ResizeObserver(reportHeight).observe(content)` runs at script evaluation, when `#content` is **empty**. Per the ResizeObserver spec, observation fires immediately on `observe()` for a rendered element (and again as soon as the element first gains size). `reportHeight` dedups against `lastHeight = -1`, so **height 0 is reported** the moment the div has a measurable (empty) geometry — before `bcReady` → `setContent` has a chance to run, because that round-trips through Swift (`bcReady` → `evaluateJavaScript("setContent(...)")`, two async hops).

Swift side, at mount: `current == 40` (the `@State` seed), and the guard at `MessageWebView.swift:162` is `rounded < current, current > 40, ...` — `40 > 40` is **false**, so the 0 is **accepted**. Every WebView bubble goes `40pt → 0pt → true height`. On a topic open with a dozen WebView bubbles, the transcript's content size is built from a forest of zero-height bubbles, then everything grows over WebKit spin-up time.

### R2 — The wrong-width report

`content.getBoundingClientRect().height` is a function of the **viewport width** at measurement time. The WebView is created with `frame: .zero` (`MessageWebView.swift:60`) and `loadHTMLString` races SwiftUI's first layout pass. Any report measured while the viewport width is zero, default, or mid-resize-stale describes a layout that doesn't exist: at near-zero width with `word-break: break-word`, text lays out one word (or character) per line — heights in the *thousands* of points for a table-heavy message. The report is a bare `Double`; Swift has no way to know it was measured at the wrong width. Growth reports are always accepted, so a garbage tall is accepted; the corrective shrink (measured at the real width) then also passes the ≥8pt band. `40 → garbage-tall → true` is exactly Bee's "interim peak", with the actual mechanism identified: **it's width-dependence, not frame-height dependence** — the template already measures `#content` precisely to avoid frame-height feedback (`MessageTemplate.html:137–140`), which is why Bee's stated mechanism ("measured while the frame is still the 40pt seed") can't be right as written: frame *height* never enters the measurement. Frame *width* does.

### R3 — The post-kill collapse cycle (the likely engine behind symptoms 4 and much of 1)

Table-heavy topics are structurally WebView-dense — `HTMLMessageConverter.swift:42` deliberately excludes `<table>` from the native subset, and `maxTextLength` trips long agent reports too. W4 measured ~26 MB per WebContent process; a topic with dozens of WebView bubbles under LazyVStack (which never releases materialized views — W4 finding) invites memory-pressure kills. Sequence when a kill lands:

1. Content was rendered (**the "flash"**). Process dies → bubble paints blank, frame stays tall (blank space = **whitespace**).
2. Recovery (`MessageWebView.swift:193–198`) reloads the template → **fresh document, fresh script, fresh ResizeObserver on an empty `#content`** → R1 fires again — but now `current` is the settled tall height, and a shrink of hundreds of points sails through the 8pt band → **bubble collapses** (**the "disappear"**).
3. `bcReady` → content re-applied → grows back — unless memory pressure kills the new process too, in which case the cycle repeats: flash → blank → collapse → flash…

Every iteration is a multi-hundred-point content-size mutation under the anchored scroll view. This is symptom 4 verbatim, and a topic-open storm of it is a large chunk of symptom 1.

**This class is confirmable today, without a new build** — the terminate handler already logs at `.error`:

```bash
log show --last 3h --predicate 'subsystem == "com.beebox.beechat"' | grep -i "terminated"
```

Run that against the session where Adam saw symptom 4. Non-empty output confirms R3; empty output demotes it and leaves R1/R2 carrying the explanation.

### Mapping the four symptoms

| # | Symptom | Mechanism |
|---|---|---|
| 1 | Whitespace entering topic | Storm at mount: every WebView bubble runs `40 → 0 (R1) → [garbage-tall (R2)] → true height` while `initialOffset` resolved against the under-measured forest and `sizeChanges` re-pins per mutation. Plus R3 kills during the spin-up burst. |
| 2 | Whitespace on long streaming response | Streaming bubble is a WebView; `setContent` per ~200ms, each report an unqualified number; R2-stale reports and legitimate mid-stream reflows mix; every mutation is a layout event at the reading edge. R3 can hit the streaming WebView too. |
| 3 | Scrollbar shows phantom room below last line | Downstream damage from the same events, two candidate sub-mechanisms: (a) LazyVStack retains stale extent estimates from bubbles it measured during garbage states; (b) after a net shrink (collapse events), the content offset sits beyond the new max and isn't re-clamped until user interaction — knob drags in phantom range, content can't move. Both are consequences of dirty height events, not independent bugs; instrumentation (§4) distinguishes them if the symptom survives the fix. |
| 4 | Flash-then-disappear | R3 cycle, with R1-on-fresh-document as the collapse trigger. |

**Why only WebView topics (Q1 — yes, the frame is right):** plain-text/native-converted bubbles lay out synchronously inside SwiftUI — their heights are never wrong, never async, never mutated out-of-band. All four symptoms require out-of-band height mutation, and the `bcHeight` binding is the only such channel in the app. LazyVStack estimation exists on every topic but only becomes user-visible when items *lie about their size*; WebView bubbles are the only items that can lie. And R3 only exists where WebContent processes exist. No plain-text path contributes — nothing to find there.

---

## 2. Answers to the eight questions

**Q1 — Right diagnostic frame?** Yes (see mapping above). No plain-text or non-height path contributes; don't spend testing budget there.

**Q2 — Is "interim-peak collapse" the mechanism?** Directionally yes, mechanically corrected: the interim peak is real but comes from *width* (R2), not from measuring "while the frame is the 40pt seed" — the template measures `#content`, which is frame-height-independent by design. And the peak is only one of three dirty classes; R1 (empty-document zero) and R3 (kill cycle) are needed to explain symptoms 1 and 4. Sub-questions:
- *Scrollbar room from `ScrollPosition(edge:)` against stale content size?* No — edge positions are semantic, resolved by the scroll view at scroll time, and the one-shot jump doesn't persist a coordinate. A stale-size jump would land wrong *once* and self-correct as `sizeChanges` re-pins. The **persistent** phantom requires persistently wrong contentSize bookkeeping — stale lazy extents or unclamped offset (symptom-3 row above), both downstream of dirty heights.
- *Flash-disappear from WebView destroy/recreate?* Not via LazyVStack (it never releases views — W4 finding; recreation happens only on topic switch via `.id`). Via **process kill** — yes, that's R3, and it's the leading candidate. The `log show` one-liner above settles it with data Adam already generated today.
- *Topic-open whitespace from `initialOffset` firing against 40pt seeds?* Yes — and it's worse than the question implies: R1 collapses the 40pt seeds to **0** before content arrives, so the initial anchor resolves against an even-more-under-measured transcript. This is why Change 3 (height seeding) is in the prescription alongside the report fixes.

**Q3 — Correct shape of the guard?** None of the listed options. Evaluated:
- *maxHeightSeen + settle window* — no; locks garbage peaks, timer race, punishes streaming (see verdict).
- *Monotonic forever + reset on width/font-scale change* — closer, but "reset on width change" requires knowing the width a report was measured at, which **is** width-tagging — at which point monotonicity adds nothing and still freezes legitimate streaming reflow. Half of the right answer, wearing the wrong hat.
- *Ignore reports below N% of natural height* — circular: "natural height" is the unknown being measured.
- *Synchronous `WKWebView.pageHeight`* — doesn't exist. There is no synchronous content-height API on WKWebView; `evaluateJavaScript` is async, and a one-shot measure misses image loads and reflows. Dead end.
- **Correct shape: transactional, self-describing reports + width-matched acceptance + seeding** (§3). The Swift guard stops being a policy and becomes a validity check: "does this report describe the layout I'm currently sizing?" Deterministic, no tuning parameters except a 1.5pt width tolerance.

**Q4 — Chrome reset timing wrong?** No. Keep it synchronous; do not add `DispatchQueue.main.async` or a debounce — that is precisely the deferred-scroll lottery the original RCA §Fix 1 removed ("an unknowable number of lazy-materialization and WebView-height passes"). The premise of the question is off: `ScrollPosition(edge: .bottom)` is not a coordinate locked against today's content size; it's a semantic edge target, and `defaultScrollAnchor(.bottom, for: .sizeChanges)` is the standing mechanism that keeps the bottom pinned *as* content grows 5×. The reset isn't "locking to 80% up the eventual content" — it's re-arming bottom semantics; the whitespace during growth is the height storm, not the reset. Fix the storm (Changes 1–3), keep F3 exactly as shipped.

**Q5 — `overflow: hidden`?** Keep it. It is not the cause: the measurement is on `#content`, whose height grows regardless of body overflow, and clipping is only *visible* when the SwiftUI frame is smaller than the content — i.e., when the height pipeline lied. Removing it re-introduces the overscroll flash and adds a second scrolling context inside bubbles (fighting the vertical wheel-forwarding in `BubbleWebView.scrollWheel`). The clipping is the messenger; the report pipeline is the message.

**Q6 — Wholesale pattern change?** No. The ResizeObserver→bridge→binding architecture is the right one for async HTML content; it just lacks transactional semantics, which Change 1 adds. Alternatives evaluated: `intrinsicContentSize` + `invalidateIntrinsicContentSize` consumes the same JS-sourced number with an extra AppKit layout pass — no new information, more moving parts. CSS containment doesn't change measurement honesty. `UIViewRepresentable`/bounds-based reading measures the *frame we set*, which is circular. The one genuinely different lever is strategic, not tactical: **reduce the WebView population** (see §5) — that attacks R3 at the root and is the only thing that does.

**Q7 — Instrumentation?** Yes — §4. One part runs **today against the installed 0.9.5e** (the `log show` grep); the rest is ~15 lines landing in the same commit as the fix, so the next manual pass verifies mechanism, not just symptom.

**Q8 — Prescribed fix:** §3, file by file.

---

## 3. Prescription

Four changes. 1 and 2 are one mechanism split across the bridge (land together — the payload shape changes). 3 is independent. 4 is logging.

### Change 1 — `MessageTemplate.html`: honest, self-describing reports

Replace the height-reporting section (`MessageTemplate.html:136–149`) and `setContent` (`:196–199`):

```js
// ---- Height reporting ------------------------------------------------
// Measure #content, not documentElement/body: those can stretch to the
// current viewport height, creating a feedback loop once SwiftUI sizes the
// web view from our own report.
// Reports are transactional and self-describing:
//  - never report before the first setContent (the empty document's geometry
//    is not information — ResizeObserver fires on observe() and again on
//    every fresh document after a WebContent process reload);
//  - never report a zero-width layout (its height is garbage);
//  - tag every report with the width it was measured at and a content
//    generation, so Swift can reject reports describing layouts that no
//    longer exist.
let generation = 0;      // bumped by setContent
let hasContent = false;  // no report until real content exists
let lastReport = { h: -1, w: -1, gen: -1 };
const reportHeight = () => {
  if (!hasContent) return;
  const rect = content.getBoundingClientRect();
  const w = Math.round(rect.width);
  if (w <= 0) return;
  const h = Math.ceil(rect.height);
  if (h === lastReport.h && w === lastReport.w && generation === lastReport.gen) return;
  lastReport = { h, w, gen: generation };
  bridge('bcHeight', { h, w, gen: generation });
};
new ResizeObserver(reportHeight).observe(content);
```

```js
    setContent(html) {
      generation += 1;
      hasContent = true;
      content.innerHTML = html;
      hydrate();
    },
```

**Rationale:** kills R1 at the source (empty-doc and post-reload-doc reports never leave JS — after a process kill, the fresh script's `hasContent` is false until content is re-applied, so the bubble *keeps its last good height* through recovery instead of collapsing to 0); kills the zero-width half of R2; arms Swift against the rest. The image `load`/`error` re-reports in `hydrate` and the RO's width-change firing (live-resize honesty) all flow through the same gate unchanged. Note `lastReport` dedup now includes `w` and `gen` — a same-height report at a new width must still be sent, or Swift would never receive a width-matching report after resize.

### Change 2 — `MessageWebView.swift`: width-matched acceptance replaces the band

Replace the `bcHeight` case (`MessageWebView.swift:151–168`):

```swift
case "bcHeight":
    // Transactional report from the template: {h, w, gen} (Change 1).
    guard let body = message.body as? [String: Any],
          let h = body["h"] as? Double,
          let w = body["w"] as? Double else { return }
    let gen = body["gen"] as? Int ?? -1
    // Delivered on the main thread; capture the live layout width now.
    let viewWidth = message.webView?.bounds.width ?? 0
    let rounded = (h * 2).rounded() / 2
    Task { @MainActor [parent] in
        // Accept only reports that describe the layout we are currently
        // sizing. A mismatched width means the report is stale (measured
        // pre-first-layout or mid-resize); the ResizeObserver fires again
        // at the new width, so a matching report always follows — dropping
        // is safe, never lossy.
        guard abs(w - viewWidth) <= 1.5 else {
            MessageWebView.logger.debug("bcHeight REJECT stale-width h=\(h) w=\(w) viewW=\(viewWidth) gen=\(gen)")
            return
        }
        let current = parent.height
        if abs(rounded - current) < 0.5 { return }  // sub-point jitter
        MessageWebView.logger.debug("bcHeight ACCEPT h=\(rounded) (was \(current)) w=\(w) gen=\(gen)")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            parent.height = CGFloat(rounded)
        }
    }
```

**The 8pt shrink band is gone, and the 40pt floor logic with it.** With R1/R2 filtered, every surviving report is an honest measurement at the current width — a shrink that passes the width gate *is* real reflow (window widen, font-scale decrease, streaming re-parse) and must be applied. F1's original bug (permanent whitespace on widen) stays fixed by a strictly stronger invariant: widen → RO fires at new width → report tagged with new width → matches → accepted. No band tuning, no monotonic special cases, nothing keyed to the 40 seed.

**Regression note vs F1–F6 (for Bee's mapping):** this *supersedes* F1's band — deliberately, per the review's own framing ("the underlying disease is dishonest reports"). F2, F3, F4, F5 untouched. F6 (coordinator placement) is why one change covers all three consumers.

### Change 3 — Height seeding: kill the 40pt cold start for settled messages

Even with honest reports, a topic open starts every settled WebView bubble at 40pt and grows it after WebKit spin-up (hundreds of ms × N bubbles) — that residual growth storm is most of symptom 1's remaining budget, and it's eliminable for every message the app has measured before.

**New file `Sources/App/Rendering/WebViewHeightCache.swift`:**

```swift
import Foundation

/// Last accepted WebView content height per message, keyed by the layout
/// inputs that determine it. Lets settled bubbles mount at their true height
/// instead of the 40pt seed, so topic-open content size is approximately
/// right before any WebContent process has spun up.
/// In-memory only — heights are cheap to re-measure across launches.
final class WebViewHeightCache {
    static let shared = WebViewHeightCache()
    private struct Entry { var height: CGFloat; var width: CGFloat; var fontScale: CGFloat }
    private var store: [String: Entry] = [:]
    private let lock = NSLock()

    func seed(id: String, fontScale: CGFloat) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[id], e.fontScale == fontScale else { return nil }
        return e.height
    }
    func record(id: String, height: CGFloat, width: CGFloat, fontScale: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        if store.count > 2000 { store.removeAll() }  // crude cap; heights re-measure for free
        store[id] = Entry(height: height, width: width, fontScale: fontScale)
    }
}
```

**`MessageWebView.swift`:** add `var cacheKey: String? = nil` (default nil — StreamingBubble and CompletedBridgeBubble call sites unchanged). In the accept path of Change 2, after the height write:

```swift
if let key = parent.cacheKey {
    WebViewHeightCache.shared.record(id: key, height: CGFloat(rounded),
                                     width: viewWidth, fontScale: parent.fontScale)
}
```

**`MessageContent.swift`:** pass the key and seed the `@State` (explicit init):

```swift
let message: Message

init(message: Message) {
    self.message = message
    _settledWebViewHeight = State(initialValue:
        WebViewHeightCache.shared.seed(id: message.id, fontScale: 1.0) ?? 40)
}
```

…and pass `cacheKey: message.id` at the `MessageWebView(` call (`MessageContent.swift:51`). One honest imperfection, on purpose: the seed can't validate width/fontScale properly from `init` (no environment access there), so validate on `fontScale` recorded vs a caller-passed value where available, and otherwise accept an approximate seed — a stale-width seed is still an order of magnitude closer to truth than 40, and the first honest report corrects it within a frame of the WebView spinning up. If Bee prefers strictness, drop the fontScale check entirely rather than plumbing environment into init; approximate seeding is the point, correctness comes from Change 2. Deliberately **not** seeding the streaming bubble (content changes per tick; cache would be stale by construction).

### Change 4 — Instrumentation (same commit, ~15 lines)

1. The two `logger.debug` lines are already in Change 2's snippet (every accept/reject with h, w, viewW, gen).
2. **Live-WebView census** — tests the R3/memory hypothesis directly. In `MessageWebView`:

```swift
private static let liveCount = OSAllocatedUnfairLock(initialState: 0)
// in makeNSView:
let n = Self.liveCount.withLock { $0 += 1; return $0 }
Self.logger.info("BubbleWebView created — live count \(n)")
// in dismantleNSView:
let n = Self.liveCount.withLock { $0 -= 1; return $0 }
Self.logger.info("BubbleWebView dismantled — live count \(n)")
```

3. The process-terminate log already exists (`MessageWebView.swift:194`) — no change.
4. Capture during the manual pass: `log stream --predicate 'subsystem == "com.beebox.beechat"' --level debug > /tmp/beechat-heights.log`, reproduce, attach the file.

**And before any of this builds:** run the retroactive check against today's 0.9.5e session — `log show --last 3h --predicate 'subsystem == "com.beebox.beechat"' | grep -i terminated`. If it's full of terminations on Beelinks, R3 is confirmed *before* writing a line of code, and §5 moves up the priority list.

### What I can't determine without the logs (stated per the constraint)

- The actual bcHeight sequences (whether R2 garbage-talls occur in practice, or only R1 zeros) — Change 4's accept/reject logs settle it either way, and the fix is correct in both worlds.
- Whether symptom 3's phantom room is stale lazy extents (a) or unclamped offset (b) — if it survives Changes 1–3 (I expect it won't), the geometry logs distinguish: (b) shows `contentOffset > contentSize − containerSize` in the scroll geometry; (a) doesn't.
- The WebContent kill rate on Adam's machine — the retroactive `log show` answers it today.

---

## 4. Test matrix for the 0.9.5f pass

1. **Retroactive (before building):** `log show` grep for terminations on today's session — confirms/demotes R3.
2. Beelinks + Beechat-mobile: enter topic → no whitespace after settle; re-enter (cache warm) → near-instant correct layout at bottom. Watch census in log stream.
3. AgentDrop: trigger a long table-heavy streaming response → bubble grows without collapse cycles; no whitespace at reading edge beyond transient settle.
4. Scrollbar: after (2) and (3), knob proportion matches content; drag-to-bottom shows last line flush with no phantom room.
5. Window widen with settled table bubble (F1's original case) → whitespace inside bubble clears (now via width-matched shrink acceptance).
6. Font-scale change → all WebView bubbles re-settle to correct heights (shrinks accepted).
7. Regressions: topic switch still lands at bottom (F3), jump button still one-click (Fix 2), plain-text topics unchanged (no code path touched — nothing WebView-side executes for them).
8. `Tests/BeeChatAppTests/MessageTemplateTests.swift` — payload shape changed (`Double` → `{h, w, gen}` dict); update expectations accordingly.

---

## Addendum — 2026-07-11 evening: R3 status downgrade after the 0.9.5e log audit

Bee ran the retroactive diagnostic (§3 Change 4) against the live 0.9.5e session (PID 91961, 26 min): 79 WebContent spawns, 44 XPC connection invalidations, **zero** `webViewWebContentProcessDidTerminate` delegate fires, 78 converter nodes/depth-cap bail-outs.

**Corrected reading — the data is cleaner than "kills the delegate missed":** `webViewWebContentProcessDidTerminate` fires only when a *live* webview's process dies unexpectedly. When *we* destroy a webview (every `.id(topicId)` topic switch dismantles every WebView bubble in the outgoing topic; re-entry recreates them), the process exit that follows is orderly — an XPC invalidation with no delegate fire, because nothing crashed. The numbers corroborate this precisely: 78 cap bail-outs ≈ 79 spawns (each WebView-bubble mount runs one fresh conversion, because `.id(topicId)` resets `MessageContent`'s `@State converted` cache, and spawns one process). The session's process churn is **bubble lifecycle, not memory pressure**. Bee's explanation #3 is ruled out (same-subsystem logs land at full fidelity); #2 has the right ingredient inverted — teardown isn't masking death callbacks, teardown *is* the exit; #1 (which XPC variant) remains open but no longer determines R3's status.

**R3 is reclassified: latent, not active.** The collapse *mechanism* is real (it's R1 physics on a fresh document) but no unexpected termination occurred in the observed session, so it is not the engine behind symptom 4. Change 1's `hasContent` gate still neutralizes R3 for free whenever a real kill does arrive — keep it, but the v0.9.5f commit text must not claim R3 as the thing being fixed (see commit-text note below).

**Symptom 2/4 re-attribution — the handoff chain (new, name it R4):** with R3 demoted, note what happens when a long WebView-class response finishes: the transcript renders the same content in **three consecutive webviews** — StreamingBubble (`id "streaming-bubble"`) → CompletedBridgeBubble (`id "completed-bridge"`) → settled `MessageContent` (`id message.id`). Two identity handoffs, each destroying a live webview that was displaying the text and mounting a cold one at the 40pt seed (WebKit spin-up ~200–500 ms). At the reading edge that is: text visible → collapses/blanks → reappears — symptom 2 ("white space when a long response arrives") and a strong candidate for symptom 4's flash-then-disappear, alongside R2 stale-width collapses at topic entry. Both candidates are addressed by the amended prescription below; the accept/reject + census logs discriminate post-hoc.

**Amendment to Change 3 — key the cache by content hash, not message id.** Keying by `message.id` can't warm the handoff chain (the bridge doesn't know the settled message's id, and the settled bubble has never been measured under its own id). Key by the *content* instead: all three consumers hold the raw content string (`streamingContent` / `completedContent` / `message.content`), and identical content is exactly the case where a cached height is valid. `cacheKey = String(content.hashValue)` is sufficient for an in-memory, per-process cache (Hasher's per-launch seed is irrelevant within one process). All three consumers pass a cacheKey and **record**; StreamingBubble's rolling records are cheap and its final record (full content) is what warms the bridge; the bridge's record warms the settled bubble. Result: each handoff mounts at the true height — no collapse, no layout shift, just a sub-second repaint. Seeding stays approximate by design; Change 2's width-matched acceptance corrects any staleness within a frame of spin-up.

**Amendment to Change 2 — the bcReady tripwire (hardening Bee's "Option B", done deterministically):** if a WebContent process is ever replaced *without* the delegate firing, the current coordinator leaves the bubble **permanently blank**: the fresh document's `bcReady` calls `apply()`, which skips re-injection because `html == appliedHTML` (only the terminate handler nils `appliedHTML`, and it didn't run). A second `bcReady` with applied state is itself the deterministic "new document exists" signal — no height heuristics needed:

```swift
case "bcReady":
    if appliedHTML != nil {
        // A fresh document exists but we never saw the process die — the
        // WebContent process was replaced without the delegate firing.
        // Reset applied state so apply() re-injects instead of skipping.
        MessageWebView.logger.fault("bcReady with content already applied — WebContent replaced without didTerminate")
        appliedHTML = nil; appliedTokens = nil; appliedScale = nil
    }
    templateReady = true
    if let webView = message.webView {
        apply(html: parent.html, tokens: parent.themeTokens,
              fontScale: parent.fontScale, to: webView)
    }
```

This self-heals and simultaneously *is* the R3-detection instrumentation: if silent kills ever occur, the `.fault` line proves it. Prefer this over Option A (KVO/polling — heavyweight, and neither `title` KVO nor bounds polling reliably signals process death) and over height-pattern heuristics (guessing again).

**Q1 (XPC variant) resolution path:** `makeNSView` uses a plain `WKWebViewConfiguration()` — no custom `WKProcessPool` (and modern WebKit largely ignores the pool for process routing anyway; the WebContent variant is chosen per-load by OS policy). Which variant macOS 26 picks for local JITless `loadHTMLString` content is not determinable from code or documentation I trust — settle it empirically in 2 minutes: open a plain-text-only topic (zero webviews), count both variants under the app (`ps` filtered by responsible process); open Beelinks; count again. The delta is MessageWebView's service. Thirteen `EnhancedSecurity` processes ≈ a plausible Beelinks bubble count, so my lean is that EnhancedSecurity *is* MessageWebView's variant on this OS — but nothing in the prescription depends on the answer.

**Commit-text note for v0.9.5f (per Adam's "supersedes, not modified" rule):**

> Fixes R1+R2 — the bcHeight report classes that fire on every WebView mount — and deliberately supersedes F1's 8pt shrink band with width-matched acceptance (the band is removed, not tuned). R3 reclassified latent-not-active per the 0.9.5e log audit: zero unexpected WebContent terminations; the 44 XPC exits are orderly `.id(topicId)` teardown churn. Change 1's hasContent gate keeps any future kill benign; the bcReady tripwire detects and heals it.

---

## 5. The strategic note (flagged, not headlined, Adam's call)

If the census shows Beelinks holding tens of live WebViews, R3 is structural: `HTMLMessageConverter` sends every table and every >maxTextLength message to a permanent WKWebView, LazyVStack never releases them, and W4's arithmetic (~26 MB/process) does the rest. Changes 1–3 make the *symptoms* of process churn benign (no more collapse cycles — bubbles hold their last good height through recovery), but the churn itself — blank flashes while a bubble's process respawns — only goes away by **reducing the WebView population**: native table rendering in the converter (SwiftUI `Grid` — the single biggest lever, since tables are why these topics are WebView-dense), and/or the bounded-webviews compromise from the original architecture review (live WebViews for recent/visible messages, converted-or-snapshot for older ones). That's a spec-pack conversation, not a patch; raise it with Adam if the census numbers are big.

---

## Note — 2026-07-11 evening: instrumentation guidance (received via Adam #14743)

Fable's stance on extra instrumentation beyond Changes 1–4: nothing heavier needed. The existing observation surface already answers the right questions.

- **Census counter (Change 4)** will show R4 directly as two create/dismantle pairs right at stream-end. No additional logging needed for the handoff chain.
- **Accept/reject logs (Change 4)** will show whether symptom 4's remaining incidents are R2 (rejected stale-width lines clustered at topic entry). If the rejection lines cluster at topic entry, R2 is the residual mechanism after R4 is addressed; otherwise a deeper look.
- **Converter bail-out warning** gains the trigger + a short content hash so expected re-entry reconversion (cheap, by-design) can be distinguished from identity churn without topic switches (the symptom).
- **Fault tripwire (Change 2 amendment)** automatically escalates R3 if it ever reappears — and the code self-heals in the same commit, so silent kills become visible-and-recovered.

Net: the four changes + the tripwire plus a small converter-warning enrichment is the full instrumentation set. No KVO, no polling, no extra processes, no per-bubble timers.

