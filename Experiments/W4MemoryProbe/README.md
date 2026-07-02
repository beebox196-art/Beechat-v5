# W4 Memory Probe

Quantifies the central risk-analysis claim: `ScrollView + LazyVStack` (MessageCanvas's
container shape) never releases instantiated views, so per-bubble web views accumulate
without bound. 500 mixed messages (prose, code blocks, tables, lists) rendered either
via **tomdai/markdown-webview** (per-bubble WKWebView) or **native Text** (baseline) in
the same harness.

Also reusable for **W1**: with the webview renderer active and 30+ bubbles instantiated,
drag-resize the probe window continuously for ~5 s.

## Run

```
cd Experiments/W4MemoryProbe
swift run                                        # interactive
swift run W4MemoryProbe --auto --renderer webview   # unattended: scrolls, prints, exits
swift run W4MemoryProbe --auto --renderer native    # baseline run
```

(Verified building 2026-07-02, macOS 14 SDK. Note: markdown-webview loads its JS/CSS
assets over the network — the "Outgoing Connections" caveat from the research doc.)

## Protocol

1. Start with **native Text (baseline)** renderer. Click "Auto-scroll all 500" (~25 s).
   Record app footprint from the toolbar readout once it settles. Expected: ≤ ~300 MB.
2. Relaunch (fresh process). Switch to **markdown-webview**. Auto-scroll all 500.
3. Record: toolbar footprint (app process, peak + settled), plus in Activity Monitor:
   every process named "Web Content" attributable to the probe, and their total.
4. Leave idle 2 minutes; record footprint drift.
5. Scroll manually top↔bottom; note hitches/beachballs.
6. (W1) Drag-resize the window 700→1200→700 pt over ~5 s; observe bubble reflow.

## Provisional pass/fail thresholds (macOS — for team consensus, argue with them)

**W4 — per-bubble webviews are viable only if ALL hold after step 3:**

| Metric | Threshold |
|---|---|
| App process footprint (settled) | ≤ 400 MB |
| App + all Web Content processes combined | ≤ 1.2 GB |
| Idle drift after scroll (2 min) | < 5% growth (plateau, not climb) |
| Interactive scroll | no hang ≥ 100 ms, no beachball |
| Web Content process count | stable small number, not scaling with bubble count |
| vs baseline | ≤ 4× native footprint |

**W1 — resize behavior passes if:**

- No overlapping/clipped/stale-height bubbles visible after drag ends
- All heights settle ≤ 200 ms after release
- No main-thread hang ≥ 100 ms during the drag (Instruments "Hangs" template if in doubt)
- Web Content CPU returns to idle ≤ 2 s after release

**Scope note:** thresholds are for BeeChat-v5 (macOS). Bee's brief mentioned a 4 GB
iPhone SE ceiling — that's the BeeChat-Mobile cycle (see its own spec pack in that
repo); iOS limits would be far stricter (app footprint ≲ 200 MB before jetsam risk) and
should not be settled by this macOS probe.

**Caveat:** the probe measures markdown-webview as-shipped — no shared template, no
wheel forwarding, no theme plumbing. It answers the *memory/accumulation* question, not
whether markdown-webview is integration-ready (see `Docs/Specs/html-rendering/01-risk-analysis.md`
§2–3 for what integration adds).
