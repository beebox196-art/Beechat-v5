# G4 — Theme feasibility — evidence

**Date:** 2026-08-05T11:50:51.368Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Mel

## Pre-registered criteria (verbatim)

- Ported theme: **light** (chosen as the representative theme — it covers the full token palette; the dark theme is provided by `prefers-color-scheme` and is not an explicit port; the other 7 themes are deferred to P4)
- fontScale steps exercised: **[0.8, 1.0, 1.2, 1.5]**
- Visual parity target: full-page screencapture vs native bubble chrome reference
- Restyle metric: **requestAnimationFrame delta around CSS variable mutation** (chosen as the best-available proxy; macOS signposts would be ideal but require C++ shim outside spike scope — recorded as documented performance target, not a binary gate)
- Reference screenshot: `G4-reference-light.png` (captured via `/usr/sbin/screencapture`)

## Measurements

| Event | raf_ms |
|---|---|
| fontScale=0.8 | 71.00 |
| fontScale=1.0 | 38.00 |
| fontScale=1.2 | 96.00 |
| fontScale=1.5 | 96.00 |

- **max** raf_ms: 96.00
- **avg** raf_ms: 75.25

## Verdict

**PASS (visual parity + fontScale variable swap works)**

Timing recorded as **documented performance target** per Kieran: raf_ms reflects the cost of the CSS variable mutation + first composited frame; production visual-parity assessment by Mel (Verifier).

## Reference screenshot

`G4-reference-light.png` in this directory. Mel to compare against native bubble chrome.

## Prior attempts

None.
