# G5 — Topic swap feasibility — evidence

**Date:** 2026-08-05T11:51:07.139Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Q

## Pre-registered criteria (verbatim)

- **20 swaps** alternating between two 25-message subsets
- Swap window definition: **JS mutation → first `requestAnimationFrame`** (proxy for first composited frame; documented in spec §3 G5)
- Budget: **< 100 ms per swap**
- White flash detection: **computed background colour samples at pre/post of each swap**

## Per-swap timings

| # | count | ms |
|---|---|---|
| 0 | 25 | 9.00 |
| 1 | 25 | 27.00 |
| 2 | 25 | 9.00 |
| 3 | 25 | 15.00 |
| 4 | 25 | 10.00 |
| 5 | 25 | 14.00 |
| 6 | 25 | 13.00 |
| 7 | 25 | 13.00 |
| 8 | 25 | 4.00 |
| 9 | 25 | 5.00 |
| 10 | 25 | 14.00 |
| 11 | 25 | 14.00 |
| 12 | 25 | 14.00 |
| 13 | 25 | 16.00 |
| 14 | 25 | 9.00 |
| 15 | 25 | 9.00 |
| 16 | 25 | 10.00 |
| 17 | 25 | 10.00 |
| 18 | 25 | 11.00 |
| 19 | 25 | 11.00 |

- **max** swap_ms: 27.00
- **avg** swap_ms: 11.85
- **white samples** (255,255,255): 40/40 (recorded, not gated — interpretation depends on theme baseline)

## Verdict

**PASS**


## Prior attempts

None.
