# Compact Pin Spec — Adversarial Review

**Reviewer:** Kieran  
**Date:** 2026-05-11  
**Documents reviewed:** SPEC-compact-pins.md, BeeBoardPinCard.swift, BeeBoardCanvasView.swift

---

## CONCERNS

### 1. Grid sort with mixed pin sizes will cause overlaps

**Severity: High**

The spec proposes changing `columnWidth: 260 → 200, rowHeight: 180 → 200`. But existing pins in the database retain their 220×132 dimensions. When `applyGridLayout` runs, it positions pins at uniform intervals — every pin gets slotted at `(col × 200, row × 200)`. An old 220pt-wide pin on a 200pt column grid will overlap the pin to its right by 20pt. Similarly, a 140pt-tall new pin on a 200pt row is fine, but a 132pt-tall old pin on 200pt rows is also fine — the problem is purely horizontal overlap with old pins.

The spec acknowledges "mixed sizes is intentional" but the grid sort does not account for varying pin widths. It uses a single `columnWidth` for all pins. Unless `applyGridLayout` is changed to use the maximum pin width on the board (or per-pin sizing), the sort function will produce overlapping pins whenever old and new pins coexist.

**Fix:** Either:
- Compute `columnWidth` as `max(pin widths on board) + padding` dynamically, or
- Include the "resize all pins" feature in the first pass, or
- Document that sort should only be used after all pins are compact, and add a guard/warning in the UI.

### 2. `.position()` centering + variable height = visual jump on selection

**Severity: High**

The canvas positions pins using `.position(x: CGFloat(pin.positionX), y: CGFloat(pin.positionY))`. SwiftUI's `.position()` modifier centers the view at that coordinate. Currently, with a fixed height, this is stable — the card always occupies the same vertical space.

The spec proposes switching to `.frame(width:) + minHeight` so the selected card can grow. When the card height increases on selection (edit fields, priority picker, tag editor all appear), the card expands both **upward and downward** from its center point. This means:
- The visible top of the card shifts upward (half the height delta)
- The visible bottom shifts downward (half the height delta)
- The card may clip off the bottom of the 1200pt canvas or overlap pins below

This is a layout bug that doesn't exist with fixed-height cards.

**Fix:** Either:
- Anchor the card to its top edge (use `offset` instead of `position`, or wrap in an alignment container that pins to top), or
- Use fixed `.frame(width:height:)` for the card container, and let only the inner content scroll/expand within that frame (the detail view already handles this), or
- Accept the visual shift and clamp `positionY` so the expanded card stays within canvas bounds.

### 3. Tag pill overflow on 160pt-wide cards

**Severity: Medium**

Internal card width after `.sm` (8pt) padding on each side: 160 − 16 = **144pt**.  
Each tag pill with `caption2` (~10pt font) + `.horizontal(4), .vertical(1)` padding: roughly 4-6 chars × 6pt + 8pt = ~36-44pt per pill.  
Four pills at 40pt average + 3 × `spacing(.xs)` (4pt) gaps = 172pt. **Doesn't fit in 144pt.**

Even three pills at 40pt + 2 × 4pt = 128pt — tight but possible for short tags. Four pills will either truncate, wrap to a second line, or overflow.

The spec claims "with smaller pill padding, a 4th tag fits on the narrower card" — the math doesn't support this for tags longer than 3-4 characters. Many real tags will be 5-8 chars.

**Fix:** Either:
- Keep `.prefix(3)` and skip the 4th tag (safest), or
- Use `.prefix(4)` but add `.lineLimit(1)` + `.truncationMode(.tail)` on the HStack, or
- Switch tag pills to a wrapping `FlowLayout` that handles overflow gracefully, or
- Reduce tag pill font further (but this conflicts with readability).

### 4. Selected card content overflows compact frame

**Severity: Medium**

When a pin is selected, the card shows: header + TextEditor + priorityPicker + tagEditor + date. Currently this fits in 220×132 (with scrolling inside TextEditor). At 160pt wide, the TextEditor and Picker become very cramped:
- TextEditor at 144pt internal width (minus border/padding) — barely usable for editing text
- Priority Picker at ~144pt wide — the `.menu` style will work but the text will be compressed
- Tag editor row (TextField + plus button) at 144pt — functional but tight

The spec says "the card height auto-grows via SwiftUI's intrinsic sizing within the fixed frame" but then also says switching to `minHeight`. These are contradictory — if the frame is fixed, content can't grow. If it uses `minHeight`, it grows. Need to pick one approach and be consistent.

### 5. Non-Retina legibility dismissed too quickly

**Severity: Low-Medium**

The spec says "macOS BeeChat targets Retina displays only" but there's no runtime enforcement. A user on a non-Retina external monitor (common with Mac mini setups — which is the target hardware per spec!) will see 11pt caption text at 1x resolution. That's genuinely hard to read for body text.

Adam's Mac mini could easily be connected to a 1080p non-Retina monitor. The spec should either enforce a minimum font scale based on display resolution, or acknowledge this as a known limitation.

---

## RISKS

### R1. Position data becomes meaningless after sort with mixed pins

When `applyGridLayout` repositions pins using the new 200×200 grid, but some pins are 220pt wide, the stored `positionX/Y` values will place old pins in positions where they overlap neighbors. There's no collision detection or avoidance in the sort logic. Users who hit "sort" will get a broken-looking board if they have any pre-existing pins.

### R2. Drag end + height change creates position drift

If the card height changes on selection (per concern #2), and the user drags a pin, the `dragGesture.onEnded` writes `CGPoint(x: start.x + translation.width, y: start.y + translation.height)` — this is the center point. But visually, the pin's top-left corner has shifted. After deselecting, the pin snaps back to a different visual position than where the user last saw it. This will feel broken.

### R3. Preview doesn't test compact sizing

The `#Preview` in BeeBoardPinCard.swift creates a `Pin` using memberwise init, which will pick up whatever the new default dimensions are. But there's no preview showing a mixed board with both old (220×132) and new (160×140) pins side by side. This should be added to catch layout regressions.

### R4. Shadow reduction makes selected state less distinct

Shadow radius goes from `8 → 5` on selection and y-offset from `4 → 2`. Combined with border width `2 → 1.5`, the visual distinction between selected and unselected states is reduced. On a busy board with many pins, this could make it harder to see which pin is active.

---

## RECOMMENDATIONS

1. **Don't change `applyGridLayout` column width in the first pass.** Keep it at 260 (or make it dynamic based on max pin width). The grid spacing should accommodate the largest pin on the board, not just the new default. Update the spec to make columnWidth/rowHeight computed values, not hardcoded.

2. **Don't switch to `minHeight` for selection.** Keep `.frame(width:height:)` fixed. When selected, the card should expand via the detail view (which already exists and is untouched by this spec), not by growing the inline card. This avoids the position-jump bug entirely. If inline editing must grow, anchor the card to its top-left corner, not its center.

3. **Keep tag pills at `.prefix(3)`.** The math doesn't support 4 pills at 160pt width with meaningful tag names. If you want to show more tags, use a "+N" overflow indicator instead: `.prefix(3) + Text("+\(remaining)")`.

4. **Add a minimum font scale check.** If `NSScreen.main?.backingScaleFactor == 1.0`, bump fonts by one token step (caption → body, body → subheading). This costs nothing at runtime and prevents the non-Retina readability problem.

5. **Test with a mixed-size board.** Before merging, create a preview/test with both 220×132 and 160×140 pins on the same canvas, then run sort. Document what happens. If it looks bad, the "resize all" button becomes a first-pass requirement, not an optional future feature.

6. **Increase shadow/border contrast on selection** rather than decreasing it. The current selection affordance (8pt shadow, 2pt border) is already subtle on macOS. Going to 5pt shadow and 1.5pt border makes it harder to see which pin is selected, especially with the priority tint overlay competing for visual attention.

7. **Clamp the card's Y position when selected** so it doesn't extend past the canvas bottom. If using `minHeight`, add: `pin.positionY = min(pin.positionY, canvasSize.height - expandedCardHeight / 2)`.

8. **Document the position model explicitly.** The current code stores positions as center points (`.position()` behavior) but the spec talks about pin placement as if positions are top-left corners. Clarify this in the spec to avoid future confusion.

---

## Summary Verdict

The compact pin direction is sound — smaller pins on a fixed canvas is clearly needed. But the spec has two real bugs (grid overlap with mixed sizes, and position jumping when card height changes on selection) that need fixing before implementation. The tag pill count claim doesn't hold up mathematically. I'd recommend:

- ✅ Font, padding, icon, shadow reductions — ship it
- ✅ Portrait orientation — ship it  
- ⚠️ Grid spacing — make dynamic, don't hardcode to 200
- ⛔ `minHeight` for selection — don't do it this way; use fixed frame + detail view for expansion
- ⚠️ Tag pills 3→4 — revert to 3, add "+N" overflow
- ⚠️ Selection affordance — increase contrast, don't decrease it