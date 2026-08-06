# Option B — Prior Art Register ("steal more, invent less")

**Author:** Fable
**Date:** 2026-08-05
**Status:** ACTIVE — decisions needed **before WP-2 writes `TranscriptTemplate.html`**
**Directive:** Adam, 2026-08-05 — *"I am tired of us inventing aspects that have already been developed and proven."*
**Companions:** `single-webview-transcript-plan.md` (route), `single-webview-transcript-scope.md` (governance), `Docs/Reviews/optionb/FABLE-SUPERCHECK-WP0.md` (WP-0 verdict)

---

## 0. Why this document exists now, not at the next review

WP-2 writes the transcript document. Every item below is a decision about **what not to write**. Delivered after WP-2, this register is a refactoring backlog; delivered before, it is a deletion of work that never happens. That is the whole value — so it lands now, and I carry a standing "Steal Check" section into every review from here.

The WP-0 spike is the cautionary case: the route plan specified a 15-line scroll engine built from two standard browser APIs, and the spike shipped without either of them while reporting the gate PASS. The failure wasn't ambition — it was that nobody was accountable for *using the platform*. This register makes that accountable.

---

## 1. The floor — RAISED 2026-08-05 (Adam)

**Deployment target is now `.macOS(.v26)`** (`Package.swift`, `swift-tools-version: 6.2`). Verified empirically, not from the manifest: `otool -l` on the built `BeeChatApp` reports `minos 26.0 / sdk 26.5`. Full suite green (380 tests, 0 failures).

**Rationale.** BeeChat has exactly one deployment target: Adam's Mac mini, running macOS 26.5. No commercialisation is planned. The previous `.v14` floor was **speculative generality** — building for a requirement that does not exist — and it was actively costing us: it constrained the transcript document to Safari 17 WebKit, which is what blocked S9 below and forced "progressive enhancement only" caveats onto S1 and S5. This is the same failure mode as hand-rolling a component that already exists in `Package.swift`; it just wears different clothes.

**Consequences, now live:**

- Modern WebKit is **load-bearing-eligible**. `@supports` fallbacks are no longer required for features shipped in Safari 18–26.
- **P11 (macOS 14 parity run) is deleted** from the WP-4 matrix — see `single-webview-transcript-scope.md` §9.1.
- The five `@available(macOS 15.0, *)` forks (`MainWindow.swift:973`, `MessageCanvas.swift:333/339/419/440`) are now dead branches. **Left in place deliberately** — all five live in files scheduled for deletion at WP-6, and both files are under active review on `fix/whitespace-phase1-clamp`. Editing them now buys nothing and creates merge conflict. The compiler raises no warnings for them (verified).
- `.iOS(.v17)` **unchanged** — BeeChat-Mobile's platform question is decision D4 and is still open.
- `Vendors/ChatField` **unchanged** at `.macOS(.v13)`. A dependency floor below the consumer's is valid; raising a vendored package adds risk for no gain.

**The discipline that survives the change.** "It's in the docs" is still not evidence that WebKit implements it — Safari's support for CSS specifications is uneven, and S5 below is a live example. **Verify each feature empirically in the target WebKit before it becomes load-bearing.** The floor moved; the requirement to test rather than assume did not.

---

## 2. Tier 1 — adopt now, decide before WP-2 code

| # | We were going to hand-roll | Proven thing to use instead | Payoff | Verify |
|---|---|---|---|---|
| **S1** | Bottom-pin maintained by our own observer + repin calls | **`flex-direction: column-reverse`** on the scroller — the long-standing chat-window idiom. In a reversed flex column, `scrollTop = 0` *is* the bottom, and content appended at the visual bottom does not move the viewport. Bottom-pinning becomes the browser's default rather than something we maintain. | Deletes the repin path for the common case (append while pinned) — the single most-exercised code path in the app | **Needs a real gate.** Known costs: DOM order vs visual order (VoiceOver + selection direction), Home/End and PageUp/PageDown inversion, and WebKit quirks. Do not adopt on reputation — measure it. Single-WebKit-version testing is now sufficient (floor raise, §1) |
| **S2** | — | **`ResizeObserver` + scroll listener with 50/120 hysteresis** — already specified in route plan §4.4, simply never built | Is the fix. Correction C-2 | C-3 re-run of G2 with all manual `pinToBottom()` calls removed |
| **S3** | Load-earlier button plus our own "am I near the top" detection | **`IntersectionObserver`** on a top sentinel — the standard infinite-scroll pattern | Deletes scroll-position arithmetic; also the right primitive for unread markers and read receipts later | Trivial; Safari 12.1+, well inside the floor |
| **S4** | Nothing — this failure mode simply wasn't considered | **`overscroll-behavior: contain`** on the scroller | One line. Stops scroll chaining and rubber-band propagation to the window — directly on the "bouncing" symptom | Safari 16+, inside the floor |
| **S5** | `prependEarlier`'s manual `scrollTop += (newHeight − oldHeight)` arithmetic (route plan §4.3) | **CSS scroll anchoring (`overflow-anchor`)** — the browser feature built for exactly this | If supported, deletes the arithmetic and the class of off-by-one bugs that comes with it | **Assume unsupported until proven.** WebKit has historically not shipped scroll anchoring. A 10-minute empirical test settles it. If unsupported, keep the manual path — and record *that* as the justification, replacing the route plan's bare assertion "no reliance on `overflow-anchor`" |
| **S6** | Any custom code-block colouring | **highlight.js or Prism**, self-hosted in the document | Both are drop-in, maintained, and theme-able from our `--bc-*` tokens | Confirm nothing custom exists today; if it does, delete it |
| **S7** | — | **ARIA APG `log` pattern** (`role="log"`, `aria-live="polite"`) — already in route plan §4.1 | Noted as *correct existing practice*. Do not re-open at review | P10 |

**S1 is the item to argue about.** It is the one place where a decision taken in the next few days either removes a whole category of future maintenance or locks us into maintaining it ourselves. It deserves a gate of its own, not a paragraph in a spec.

---

## 3. Tier 2 — evaluate with a named owner

| # | Current hand-rolled | Alternative | Assessment | Owner |
|---|---|---|---|---|
| **S8** | `HTMLSanitizer.swift` — **312 lines** of custom allowlist DOM walk | **SwiftSoup's `Cleaner` + `Safelist`** — a port of jsoup's, one of the most widely deployed sanitizers in existence. **The dependency is already in `Package.swift:26`** | Fair to the existing code: it is parser-based (not regex), has a documented threat model, and is decent work — this is not a red flag. But it is 312 lines of security-critical code we maintain when a configured `Safelist` expresses the same policy. **Option B strengthens the case**: the allowlist's main carve-out (keep `<table>` because the native converter routes it to `needsWebView`) becomes meaningless once the converter is deleted, so the policy simplifies at exactly the moment we're touching it | **Mel** |
| **S9** | Nothing yet | **`content-visibility: auto` + `contain-intrinsic-size`** — browser-native skipping of off-screen layout/paint | **UNBLOCKED 2026-08-05** by the floor raise (§1) — promote to Tier 1 candidate. Now load-bearing-eligible with no `@supports` fallback required. Confirm the WebKit build honours it, then apply to settled (non-streaming) messages. Interacts with S1: measure them together, since `content-visibility` changes how the browser computes scroll height for off-screen nodes | Kieran |
| **S10** | Native composer alongside web transcript | **Composer inside the document** (the Slack/Teams arrangement) | Not now. This is the one seam where our design still differs from the model we're copying, and G6 exists to watch it. If focus or keystroke problems appear in P-series, this is the answer — moving the composer in, not patching the seam | Adam (if triggered) |
| **S11** | `MarkdownToHTML.swift` (124 lines) | — | **No change. This is already correct stealing** — it wraps `swift-cmark` (gfm branch, `Package.swift:27`), Apple's binding to the reference CommonMark implementation. Recorded here so nobody re-opens it at review | — |
| **S12** | — | **`WKWebView.find(_:)`** for Cmd+F rather than a DOM search | Already in the post-default-on backlog. Confirm the native API is used, not a hand-rolled `window.find` wrapper | Kieran |

---

## 4. Tier 3 — deliberately not stealing (recorded so it isn't re-litigated)

| Considered | Rejected because |
|---|---|
| Virtual-scroll library (react-window and equivalents) | `MessageListObserver`'s 25-message window already bounds the DOM upstream. A virtualiser would add a dependency to solve a problem we don't have |
| Electron / Tauri rewrite | Would deliver the Slack model everywhere, at the cost of the gateway client, persistence, sync bridge, and theming. Not proportionate to one window |
| Off-the-shelf chat UI kit | None map onto our gateway/persistence/streaming model. Integration would exceed the ~350-line document it replaces |
| Transplanting `tomdai/markdown-webview` wholesale | Evaluated in Round 1–3; it is a per-message renderer, which is the architecture Option B is leaving |

---

## 5. Standing rule proposed for the evidence standard

The scope document's E-rules force *runtime evidence over code inspection*. The WP-0 review added **E8** (verdict-logic audit). This directive needs its own:

> **E9 — Prior art declaration.** Any spec introducing a new component must state, per component: the platform feature, library, or documented pattern that was evaluated, and the specific reason it was not used. *"We didn't look"* is not a reason and fails review. The reviewer checks the declaration before approving the spec — not after the code exists.

Cheap to comply with, and it moves the question from after implementation (where it becomes a rewrite nobody funds) to before (where it is a deletion).

Recommend Adam ratifies E8 and E9 together.

---

## 6. What I carry into every future review

A standing **Steal Check** section, asking three questions of whatever is under review:

1. Which platform features does this code reimplement, and were they evaluated against the **macOS 14 floor**?
2. Which hand-rolled component has a maintained, audited equivalent already in `Package.swift`?
3. Does every new component carry an E9 declaration?

---

*Decisions on S1, S5, and S8 are needed before WP-2 writes template code. — Fable, 2026-08-05*
