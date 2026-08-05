# G5 — Topic swap feasibility — evidence

**Date:** 2026-08-05T11:51:07.139Z (original run)
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Kieran (independent — assigned in WP-0 test-harness fix round to resolve E5; PENDING sign-off, see §E5 below)

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

**PASS** (subject to independent verifier sign-off — see §E5)

## §E5 — Independent verifier assignment (WP-0 test-harness fix round)

**Issue (Kieran WP-0 G2 adjudication follow-up):** The original G5 evidence
recorded `Operator: Q / Verifier: Q` — the implementer signing their own
gate. This violates E5 (implementer cannot sign their own gate). Fable
flagged this as C-10 in the original correction round and it was
preserved-as-is because G5 was not in the CORRECTIONS REQUIRED list
(methodology was sound; only the E5 sign-off was missing).

**Resolution (this round):**

- **Independent verifier: Kieran.** Topic-swap feasibility is a runtime
  performance test (20 swaps, < 100ms budget, rAF timing) and a
  methodology question (is JS-mutation-to-first-rAF an acceptable proxy
  for first composited frame? Is the white-flash interpretation
  appropriate?). Kieran is the right role for this — adversarial review
  + methodology adjudication. Adam is the final acceptance role, not the
  methodology role. Mel is the UI/visual role; the G5 evidence is
  numbers, not visual.
- **Sign-off status: PENDING.** This subagent run can identify the
  correct verifier and update the gate metadata, but cannot obtain
  Kieran's sign-off in-session. The previous PASS verdict holds
  provisionally; the final verdict is contingent on Kieran's review of
  the per-swap timings and methodology.
- **Re-run required? No.** The evidence is methodologically sound (timing
  data, white-flash samples, swap budget). Kieran should review the
  existing evidence file and either sign off or request a re-run. No
  re-run is needed at the subagent level; the file above is the
  authoritative artefact.
- **No re-run was performed in this round** because the WP-0 test-harness
  fix scope is G2 (stateAfterRepin / bounce probe / E8 audit) — G5 is
  resolved as an E5 sign-off change only, per the task description.

## Prior attempts

None.
