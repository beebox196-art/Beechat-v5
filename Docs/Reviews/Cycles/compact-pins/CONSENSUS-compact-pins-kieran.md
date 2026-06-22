# Consensus Statement — Compact Pin Spec v2

**Reviewer:** Kieran (Adversarial Review)  
**Date:** 2026-05-11  
**Verdict:** **Conditionally Agree**

---

## Previous Concerns — Resolved?

| # | Concern | v2 Response | Assessment |
|---|---|---|---|
| 1 | Grid sort overlap with mixed sizes | Dynamic spacing based on `maxPinWidth/Height + 40pt` | ✅ **Resolved.** Sound approach — adapts to actual board contents, handles legacy+compact coexistence. The 40pt gutter (20pt each side) is sufficient. |
| 2 | Position jumping with minHeight | Fixed frame, no minHeight; full edit via PinDetailView sheet | ✅ **Resolved.** This is the correct fix. `.position()` centres at the coordinate, so variable height was always going to jump. Keeping the frame fixed and routing full editing to the existing sheet is clean. |
| 3 | Tag pill overflow | 4 tags with explicit wrapping + wrap-aware layout | ✅ **Resolved.** The spec now admits the math reality and designs for wrapping instead of pretending 4 pills fit on 144pt. Good. |
| 4 | Selection affordance weakened | Selection shadow/border kept at current values (8pt/4pt, 2pt border); only *unselected* shadow reduced | ✅ **Resolved.** This was the right call. The contrast between a lighter resting state and a strong selected state actually improves affordance. |
| 5 | Non-Retina legibility | Noted as known limitation; optional future scaling | ⚠️ **Accepted with caveat.** The mitigation (runtime `backingScaleFactor` check) is documented and low-effort. Fine to defer, but don't forget — Mac mini + non-Retina external monitor is a real deployment scenario. |

All five original concerns are adequately addressed.

---

## New Issues Introduced by v2?

| Concern | Severity | Notes |
|---|---|---|
| Dynamic grid spacing depends on `pins.map(\.width).max()` | Low | If a single legacy 220pt pin exists, *all* grid columns widen to 260pt, wasting space for compact pins. This is acceptable for a freeform canvas but worth noting — the grid becomes sparse when mixing sizes. Not a blocker. |
| 4pt inner spacing | Low | The spec already flags this and provides the escape hatch (bump to 6pt). That's the right process — ship at 4pt, test worst case, adjust if needed. |
| Title at 15pt in 144pt content width | Low | ~20-25 chars visible before truncation. Reasonable for pin titles. Detail view is the safety net. |
| Top accent bar (optional §9) | None | Nice polish, not blocking. No concern. |

No blocking issues introduced by v2.

---

## Specific Questions

**Is the dynamic grid spacing approach sound?**  
Yes. Computing column/row size from the actual max dimensions of pins on the board is robust. The 40pt gutter is reasonable. One observation: if the board has *only* compact pins, the grid will be 200×180 — significantly tighter than the old 260×260, which is exactly the space win we want. If mixing legacy + compact, columns widen to accommodate legacy. This is correct behaviour.

**Is the fixed frame + detail view approach for selection correct?**  
Yes. This was the critical bug I flagged in v1, and the fixed-frame approach eliminates it entirely. Inline editing within the 160×140 frame keeps the card stable; PinDetailView sheet handles anything that doesn't fit. No jumping, no off-canvas clipping.

**Any remaining blockers?**  
No.

---

## Final Caveats

1. **Inner spacing at 4pt** — Test the worst case (long title + 3-line body + 2 rows of tags) before shipping. If cramped, bump to 6pt. The spec already says this; I'm reinforcing it.
2. **Non-Retina font scaling** — Don't let this slip indefinitely. It's a 10-line optional guard that prevents a real usability regression on external monitors. Schedule it for the first polish pass after v1 ships.
3. **Dynamic grid with single legacy outlier** — If one 220pt pin is on a board of otherwise compact pins, the grid widens for all columns. This is fine, but users might wonder why their compact board has wide spacing. Not worth solving now; just be aware.

---

**Consensus: Conditionally Agree.**  
All prior concerns resolved. No new blockers. Conditions are the 4pt spacing worst-case test and scheduling non-Retina scaling promptly after v1.