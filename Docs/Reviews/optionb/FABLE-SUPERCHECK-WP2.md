# WP-2 Transcript Document — External Super-Checker Review

**Reviewer:** Fable (external, impartial)
**Date:** 2026-08-06
**Branch:** `feat/transcript-document` @ `08aa1c0`
**Method:** Source read line-by-line; every claim checked against implementation; two claims settled by running code

---

## VERDICT: REQUEST CHANGES

One blocker, one false-provenance blocker, two carry-forwards. The rest of WP-2 is good work and verifies cleanly.

**The blocker is not a logic error — it is a wiring error, and it means the engine's user-scroll-up protection does not work at all for a real user.** It has been masked at every gate because both WP-0's G2 and WP-2's T2 synthesise the scroll event and aim it directly at the listener node. The internal chain could not have caught it by reading; I only caught it by running a probe.

---

## BLOCKER B-1 — The scroll listener is attached to a node that never receives viewport scroll events

**File:** `Sources/App/Resources/TranscriptTemplate.html:415, :449`

```js
const $scroller = document.scrollingElement || document.documentElement;   // :415
$scroller.addEventListener('scroll', () => { … userScrolledUp = true … }); // :449
```

Per CSSOM-View, when the **viewport** scrolls the `scroll` event is fired **at the `Document`** and bubbles to `window`. `document.scrollingElement` is `<html>` — a *child* of the Document node. Bubbling travels upward from the target, so an event fired at Document never traverses `<html>`. The listener is on a node that is not in the propagation path.

### Empirical proof

I instrumented every candidate target in a real `WKWebView` running the real `TranscriptTemplate.html`, performed **real** scrolls (`window.scrollTo`, and a direct `scrollTop =` assignment — no `dispatchEvent` anywhere), and included an overflow `<div>` as a control:

```
FABLE-PROBE hits={"document":2,"scrollingElement":0,"documentElement":0,
                  "body":0,"window":2,"controlDiv":1}
FABLE-PROBE maxScroll=8388 finalScrollTop=600
FABLE-PROBE engine userScrolledUp after real scrolls = false
```

- Both real viewport scrolls fired — **2 hits on `document`, 2 on `window`**.
- **Zero hits on `scrollingElement` / `documentElement`** — the node the engine listens on.
- The control div received its event (1 hit), proving scroll events work normally in this harness. This rules out "headless WebView doesn't process scrolling."
- After two genuine scrolls (300 px, then 600 px), the engine's `userScrolledUp` is still **`false`**.

Probe source preserved for reproduction at the end of this document.

### Consequences

1. **Fix 2 is entirely non-functional in production.** `userScrolledUp` can never become true from a real user scroll. The engine therefore treats every user as pinned and re-pins them on every content arrival — **the exact bounce-probe defect from the WP-0 re-check, live in the shipped template.**
2. **The Fix-4 conclusion is wrong.** `G2-evidence.md:197` states *"`window.scrollTo` does NOT fire a scroll event in WebKit."* It does. The events fire; they are delivered to `document` and `window`, not to `documentElement`. The team diagnosed a WebKit quirk where there was a listener-target bug, and built a workaround around the wrong cause.
3. **Both gates that "prove" this mechanism are compromised.** WP-0's bounce probe dispatches the event at the listener node (`Experiments/.../main.swift:1074` — `scroller.dispatchEvent(new Event('scroll'))`), and T2 does the same (`Tests/BeeChatAppTests/TranscriptTemplateTests.swift:286`). Both validate the *logic* correctly and mask the *wiring* completely.

### Answer to your review question 5

You asked whether the `document.scrollingElement` dispatch is "a legitimate correction or a test-only cheat." **Neither.** It is a workaround for a misdiagnosis, and it is what concealed a production defect through two gates. The dispatch must be removed from T2, not kept.

### Fix

One line — attach the listener to the node that actually receives the event:

```js
document.addEventListener('scroll', () => { … }, { passive: true });
```

`$scroller` stays exactly as it is for *reading and writing* `scrollTop` / `scrollHeight` / `clientHeight`; only the event target is wrong. Alternatively, adopt the route plan's `#scroller` div (see C-2), which makes the original `elem.addEventListener('scroll')` form correct as written.

**Then remove the synthetic dispatch from T2 and re-run it.** T2 must fail before the fix and pass after — that is the only thing that proves both the fix and the test.

---

## BLOCKER B-2 — The "50/120 hysteresis" claim is false, and is asserted as G2-validated

**File:** `TranscriptTemplate.html:406, :420`

```
 * (WP-0 G2 PASS, 100/100 assertions including 50/120 hysteresis + bounce probe).   :406
 *   - hysteresis enter 50 / leave 120 (route plan §4.4)                             :420
```

`grep -n '120'` over the whole template returns **only these two comments** plus three unrelated `setTimeout(…, 1200)` calls. There is no 120 px threshold in the code. `_updatePinned` has a single `d < 50` test (`:436`) plus the `userScrolledUp` latch.

Worse, the spike's own source says the mechanism was **deliberately rejected**:

> `Experiments/.../transcript.html:216–217` — *"The hysteresis in route plan §4.4 (enter 50/leave 120) is incompatible with high-rate streaming…"*

So the production template's header asserts, as proven provenance, a mechanism the spike explicitly removed — and attributes its validation to a G2 run that could not have tested it.

This is the **same defect class as the `bcPinned` doc-comment you just cleaned**: a comment asserting a contract the code does not implement. It has already propagated into `TranscriptTemplateTests.swift:17` (*"T2 — pin hysteresis across scripted scrolls (50/120)"*), into the B2 evidence, and into this review prompt. Left alone, WP-3 inherits it as fact.

I am ranking a comment as a blocker deliberately. This programme's recurring failure mode is documents that describe intentions rather than implementations, and the cost has been three lost review cycles. The comment is cheap to fix and expensive to leave.

**Fix:** state what the engine does — single 50 px re-pin band plus a user-intent latch — and record *why* the route plan's 50/120 was rejected, so nobody re-adds it later.

---

## CARRY-FORWARD C-1 — Fix 2's stated contract is stronger than its implementation

**File:** `TranscriptTemplate.html:408, :424, :439`

The comments say *"userScrolledUp persists until explicit re-pin."* The code clears it inside `_updatePinned` whenever `d < 50`, **from any cause** — including a `deferredRepin`-driven evaluation:

```js
if (userScrolledUp) {
  if (d < 50) { pinned = true; userScrolledUp = false; }   // :439 — not an "explicit re-pin"
```

My WP-0 recommendation was to distinguish engine-driven from user-driven `_updatePinned` calls. That was not implemented; the function still takes only `d`.

With Fix 1 correct this is mostly benign, because the engine no longer manufactures spurious detections. But a concrete failure remains: **user scrolls up 60 px, then the window is resized taller — or a streaming bubble settles shorter, or a message is edited shorter — `d` drops below 50, the user's intent is silently discarded and they are re-pinned.** Narrow, but it is the same defect reached by a different route.

Honest wording today: *"persists until the viewport is within 50 px of the bottom, by any cause."* Better: add the engine/user provenance flag and make the comment true.

---

## CARRY-FORWARD C-2 — Undisclosed DOM deviation from route plan §4.1

Route plan `:154` specifies `<div id="scroller">` — *"the ONE scroll surface; overflow-y:auto"*. The production template has no such element: `body { overflow-y: auto }` (`:98`) with `<main id="transcript">` directly under `<body>` (`:383–385`), so scrolling happens at the viewport.

This is not disclosed in the B2 evidence, and it is **the direct cause of B-1** — with a real scroll container, `elem.addEventListener('scroll', …)` is correct as written, because element scrolling targets the element. Adopting the spec'd DOM is therefore a legitimate alternative fix for B-1, and it additionally isolates the transcript from body/viewport scroll quirks. Worth deciding explicitly rather than by omission, since WP-3 builds on this DOM.

---

## Verified good (checked, not taken on trust)

| Item | Evidence |
|---|---|
| **Fix 1 preserved correctly** | `:466`, `:471` — `engineScrollTop = scrollHeight − clientHeight`. Tolerance raised 2 → 4 px (`:454`), sensible for sub-pixel/zoom. `setTopic` (`:705`) assigns the already-clamped `scrollTop`; `scrollToBottom` (`:810`) assigns the clamped value. All three write paths correct. |
| **Bridge contract now truthful** | Exactly 5 `bridge(` call sites — `:556` `bcCopyMessage`, `:846` `bcLink`, `:850` `bcImage`, `:854` `bcLoadEarlier`, `:857` `bcReady`. `bcPinned` / `bcSelectionCopied` absent from **both** `.html` and the generated `.swift`. Contract is honest. **WP-3: do not register a `bcPinned` handler — `state().pinned` is the source of truth.** |
| **`--check` drift detection is real** | Verified by running it, not reading it: appended one comment line → `exit=1` with a regenerate instruction; `git checkout` → `exit=0`. Not a no-op. |
| **CSP substance** | `:22` carries `form-action 'none'` as Mel required. `frame-ancestors` correctly absent and documented as unenforceable from meta CSP — not implied as protected. `testEmbeddedTemplateHasCSPMeta` asserts each directive, so a future edit dropping one fails the suite. |
| **FR-MULTICOPY A4 not broken** | `user-select: text` on message bodies (`:131`, `:172`); `none` on sender labels, badges, and copy buttons (`:148`, `:343–344`). Affordances are non-selectable, so selection stays on content. |
| **T2 exercises Fix 2's logic genuinely** | The sequence is real: `setTopic` → pinned; scroll up → `pinned=false`, `userScrolledUp=true`; `upsertMessages` → does **not** re-pin (asserts `dfb > 100`); `scrollToBottom` → clears the flag. The logic is correctly tested. Only the *input* is synthetic — which is B-1. |
| **Suite** | `swift test` → **396 / 0 / 0**, matching the claim. |

---

## Required before B2 sign-off

1. **B-1** — move the scroll listener to `document` (or adopt the `#scroller` div). Remove the synthetic dispatch from T2; confirm T2 **fails before** and **passes after**.
2. **B-1a** — re-run WP-0 G2's bounce probe without `dispatchEvent` (`main.swift:1074`). G2's PASS on that criterion is currently unproven.
3. **B-2** — correct the hysteresis claim in `TranscriptTemplate.html`, `TranscriptTemplateTests.swift:17`, and the B2 evidence. Regenerate the constant and re-run `--check`.
4. **C-1** — either implement the engine/user provenance flag or restate the Fix 2 comment truthfully.
5. **C-2** — record the `#scroller` deviation as a decision, whichever way it goes.

Items 1–3 are cheap. My estimate is well under a day including the re-runs.

---

## Carry into WP-3

1. **Add a permanent event-wiring test**, not just a logic test. Assert the listener receives an event produced by a real scroll, with no `dispatchEvent`. B-1 is the second defect in this programme that lived specifically in the gap between "the logic is right" and "the logic is connected."
2. **`state().pinned` is the pin contract.** No `bcPinned` handler in WP-3.
3. **Sanitizer must run before every payload path** — `setTopic`, `upsertMessages`, `prependEarlier`, `setStreaming`. This is the binding half of the CSP hand-off; the template cannot enforce it.
4. **E9 declaration for the scroll engine** would have caught B-2 at spec time: the route plan named an idiom, the implementation replaced it, and the comment kept claiming the idiom.

---

## Confidence

**On B-1: very high.** It is a measured result with a working control, reproduced against the real template in a real WKWebView, with no synthetic events involved.

**On B-2: certain.** It is a grep.

**On C-1 / C-2: high** — both read directly from source.

**One thing I did not verify:** the 8-theme fixture corpus and screenshot-diff claims in `B2-evidence.md`, and G4's deferred visual parity. Those remain Mel's, and G4's parity gap from WP-0 is still open.

---

## Appendix — probe source (for reproduction)

Place in `Tests/BeeChatAppTests/`, run `swift test --filter ZZFableScrollEventProbe`, then delete. Full source retained by the reviewer; the essential part:

```swift
// After setTopic with ~30 tall messages:
window.__hits = { document:0, scrollingElement:0, documentElement:0, body:0, window:0, controlDiv:0 };
document.addEventListener('scroll', () => { window.__hits.document++; });
(document.scrollingElement||document.documentElement)
  .addEventListener('scroll', () => { window.__hits.scrollingElement++; });
document.documentElement.addEventListener('scroll', () => { window.__hits.documentElement++; });
document.body.addEventListener('scroll', () => { window.__hits.body++; });
window.addEventListener('scroll', () => { window.__hits.window++; });
// control: a fixed 50px div with overflow-y:auto and 2000px of content
// then: window.scrollTo(0,300); scrollingElement.scrollTop = 600; controlDiv.scrollTop = 400;
// read window.__hits and window.bc.state().userScrolledUp
```

No `dispatchEvent` anywhere — that is the point.

---

*Review complete. Verdict: REQUEST CHANGES — B-1 (listener wiring) and B-2 (false hysteresis provenance) block B2 sign-off. — Fable, 2026-08-06*
