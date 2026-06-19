# Mel's Consensus — Compact Pin Spec v2

**Reviewer:** Mel (UI Design)  
**Date:** 2026-05-11  
**Verdict:** ✅ Conditionally Agree

---

## Response to Flagged Concerns

### 1. Title/Body Hierarchy — ✅ Adequately Addressed

v2 keeps title at `subheading` (15pt) while dropping body to `caption` (11pt). The 4pt gap (15 vs 11) is a clear, readable hierarchy at small card sizes. This was my strongest objection to v1 and it's been resolved correctly.

### 2. Tag Pill Wrapping — ✅ Acceptable

v2 stops pretending 4 pills fit on one line and explicitly designs for wrapping. Using `fixedSize(horizontal: false, vertical: true)` or a wrap-aware `FlowLayout` is the right call. The 140pt card height can absorb a second tag row. Honest math > wishful math.

One minor note: if most pins have short tags (1-2 per pin), the wrapped row will be rare and this works fine. If most pins have 3-4 long tags, the card will routinely show two rows and feel dense. Worth watching in real usage.

### 3. Inner Spacing at 4pt — ⚠️ Conditionally Acceptable

4pt is aggressive and I remain sceptical it'll feel right in the worst case (long title + 3-line body + wrapped tags). But v2 explicitly commits to bumping to 6pt if cramped — that's the right safety valve. **I'll agree on the condition that the 4pt→6pt bump is tested early and acted on without another review cycle.** Don't ship 4pt if the worst case looks cramped and then debate it.

### 4. Accent Bar — ✅ Appropriate as Follow-up

Not a blocker. The 3pt top accent bar is a good polish item. Including it in the spec as optional follow-up is fine — it doesn't need to gate v1.

### 5. Aspect Ratio (1.14:1) — ⚠️ Minor Residual Concern

At 160×140pt, the card is "portrait-ish" but only barely — it's nearly square. This isn't a blocker, but it means the card won't read as clearly portrait in the way a 1:1.3+ ratio would. The visual identity is "smaller square-ish card" more than "compact portrait card." That's fine functionally, just be aware the portrait framing in the spec's language is aspirational rather than strongly perceptual.

---

## Additional Visual Notes

- **Selection shadow kept at 8pt/4pt offset:** Good decision. Smaller cards need more visual pop when selected, not less. The contrast between unselected (3/1) and selected (8/4) will read clearly.
- **Fixed frame approach:** Correct call. Variable height + `.position()` was a real bug, and containing inline editing within the fixed 160×140 frame is pragmatic. PinDetailView handles the overflow case.
- **Dynamic grid spacing:** Smart. Hardcoded 200pt columns would have caused overlap with existing 220pt pins.
- **Colour dot at 8×8:** Fine at this size. The accent bar follow-up would make this less critical anyway.

---

## Blockers

**None.** All five original concerns have been addressed to a degree I can ship with.

---

## Conditions

1. **Test 4pt inner spacing early.** If worst-case content (long title + 3 body lines + 2 rows of tags) looks cramped, bump to 6pt without re-review.
2. **Tag wrapping is the expected behaviour**, not an edge case. Design and QA should validate that a two-row tag layout reads cleanly, not just the single-row happy path.

---

*Mel — UI Design*