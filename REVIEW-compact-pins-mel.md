# Compact Pin Review — Mel (UI Design)

**Date:** 2026-05-11  
**Reviewer:** Mel 🎨  
**Spec:** `/SPEC-compact-pins.md`  
**Status:** Approved with concerns and suggestions  

---

## VISUAL ASSESSMENT

### 1. Portrait Pin Shape on Freeform Canvas

**Verdict: Works, but with a caveat.**

The shift from 220×132 (landscape, 1.67:1) to 160×140 (portrait-ish, 1.14:1) is a meaningful visual change. The 1.14:1 ratio is *almost* square — it reads as a soft portrait card rather than a true tall rectangle. On a freeform canvas, this actually works in our favour:

- **Vertical stacking:** Portrait pins naturally suggest vertical reading order. When pins cluster in columns, the eye flows top-to-bottom, which is the natural reading direction.
- **Canvas density:** At 160pt wide, you can fit ~11 pins across the 1800pt canvas (vs ~8 at 220pt). That's a ~37% increase in horizontal capacity. Combined with the slightly taller height, the net area per pin drops from 29,040 sq pt to 22,400 sq pt — a **23% area reduction**. That's meaningful.
- **Mixed-size coexistence:** Existing landscape pins sitting next to new portrait pins will look intentionally asymmetrical, not broken. Apple Freeform and Miro both mix card sizes. It reads as "organic" rather than "broken layout."

**Caveat:** The 1.14:1 ratio is in an awkward middle ground — not clearly portrait, not clearly landscape. If you're going portrait, commit to it. I'd push to **150×160** (1.07:1, more clearly tall) or keep 160×140 but accept that it reads as "nearly square." The current spec is fine — just be aware it won't *feel* dramatically different from the landscape shape at a glance.

### 2. Font Size Reductions

**Verdict: Acceptable on Retina, but the title/body hierarchy gets weak.**

| Element | Old | New | Delta |
|---|---|---|---|
| Title | 15pt (`subheading`) | 13pt (`body`) | −2pt |
| Body | 13pt (`body`) | 11pt (`caption`) | −2pt |

The problem: **title and body are now only 2pt apart** (13 vs 11). In the current design they're also 2pt apart (15 vs 13), so the *relative* hierarchy is preserved — but at smaller absolute sizes, that 2pt gap feels less distinct. At 15→13, the title still clearly leads. At 13→11, both feel like "body text" and the title loses its authority.

**Recommendation:** Keep the title at `subheading` (15pt) and only reduce the body to `caption` (11pt). This gives a 4pt gap (15 vs 11) which is a much clearer hierarchy at small sizes. The title is the most important information on the card — it should still *look* like a title.

On Retina: 11pt caption is perfectly readable. 13pt body is fine. No concerns there.

### 3. Padding & Spacing Reduction

**Verdict: Borderline cramped. Needs careful testing.**

Card padding drops from 16pt to 8pt. On a 160pt-wide card, that leaves **144pt of content width** (160 − 16). Compare to the current card: 220 − 32 = **188pt of content width**. That's a 23% reduction in available horizontal space.

With the header containing: colour dot (8pt) + paperclip icon (8pt, conditional) + title text + expand icon (8pt) + spacing (~12pt total), the title text area in a rich pin shrinks from ~150pt to ~106pt. For long titles, this means more truncation with ellipsis.

**Specific concern:** The inner spacing dropping from 8pt to 4pt (`.sm` → `.xs`) is aggressive. 4pt between the title row, body text, and tag pills is visually tight. It will work, but the card will feel *dense* rather than *airy*. This is actually appropriate for a "compact" pin — dense is the goal — but test with:
- A pin with a long title (30+ chars)
- A pin with 4 tags
- A pin with 3 lines of body text
- All of the above combined

If the combined worst-case feels unreadable, bump inner spacing back to 6pt (halfway between `.xs` and `.sm`).

### 4. Shadow Reduction

**Verdict: Good. Maintains hierarchy.**

| State | Old | New | Ratio |
|---|---|---|---|
| Unselected | radius 4, y-offset 2 | radius 3, y-offset 1 | 25% reduction |
| Selected | radius 8, y-offset 4 | radius 5, y-offset 2 | 37.5% reduction |

The selected shadow drops more aggressively, which is correct — on a smaller card, an 8pt radius shadow looks bloated. The 5pt selected radius still provides clear visual distinction from the 3pt unselected state. The y-offset halving (4→2) also feels right for a smaller element.

**No concerns here.** This is well-calibrated.

### 5. Tag Pills on 160pt Card

**Verdict: 4 pills will overflow. The spec is optimistic.**

Let's do the math:
- Content width: 144pt (160 − 16pt padding)
- Tag pill at `caption2` (~10pt font) with `h:4, v:1` padding
- Average tag name: 6-8 characters → pill width ~40-55pt
- 4 pills × ~48pt average + 3 gaps × 4pt spacing = **204pt**

**204pt > 144pt.** Four tag pills will not fit on one line. They will wrap to a second row.

This isn't necessarily bad — wrapped tag pills look fine — but the spec says "a 4th tag fits on the narrower card" which is incorrect. It fits *if* the tags are short (3-4 chars) or if wrapping is acceptable.

**Recommendation:** 
- Keep `.prefix(4)` — showing more tags is better than fewer
- Accept that tags will wrap to 2 rows on longer tag names
- Ensure the card height (140pt) accommodates a wrapped tag row. With 8pt padding + header (~20pt) + 4pt gap + body 3 lines (~36pt at 11pt/line with tight leading) + 4pt gap + tags 2 rows (~16pt) + 4pt gap + date (~12pt) = ~96pt minimum. That fits in 140pt with room to spare.
- If you want single-row tags, cap at 3 pills OR use shorter tag abbreviations

### 6. Line Limit Change (2 → 3)

**Verdict: Smart move.**

With 11pt caption font and tighter line height, 3 lines of body text in the compact card occupy roughly the same vertical space as 2 lines of 13pt body text did before. This is a genuine information-density win — users see more content without expanding.

**One concern:** The "No notes yet" italic placeholder also uses the body font. If someone creates a pin without adding content, the card shows "No notes yet" in 11pt italic — which is fine, but the empty state feels slightly more prominent on a smaller card because there's less other content to balance it. Not a blocker, just an observation.

---

## CONCERNS

### 🔶 Medium Priority

1. **Title/body hierarchy too weak at 13pt/11pt.** Recommend keeping title at 15pt (`subheading`). The 2pt gap at small sizes doesn't create enough visual distinction.

2. **4 tag pills don't fit on one line.** The spec's claim that they do is mathematically incorrect. Wrapping is acceptable but should be explicitly planned for, not treated as a happy accident.

3. **Inner spacing at 4pt is aggressive.** Test the worst-case pin (long title + 3-line body + 4 tags). If it feels cramped, bump to 6pt.

### 🔷 Low Priority

4. **1.14:1 aspect ratio is ambiguous.** It's not clearly portrait. If the goal is "portrait pins," push to something more clearly tall (e.g., 140×160). If the goal is just "smaller pins that happen to be slightly taller," 160×140 is fine — just don't call them "portrait" in user-facing copy.

5. **Long title truncation.** With 144pt of content width and a 13pt+ font, titles longer than ~20-25 characters will get truncated. This is probably fine (titles *should* be concise), but worth noting.

---

## SUGGESTIONS

### S1: Keep Title at 15pt, Only Shrink Body

```
Title:   subheading (15pt)  ← KEEP
Body:    caption (11pt)     ← REDUCE from body (13pt)
Date:    caption2 (10pt)    ← KEEP
Tags:    caption2 (10pt)    ← KEEP
```

This gives a 4pt hierarchy gap (15 vs 11) which reads clearly at small sizes. The title still *looks* like a title.

### S2: Add Subtle Top Accent Bar for Visual Identity

The current cards rely on the colour dot + priority tint for visual differentiation. On a smaller card, the colour dot (8pt) is barely noticeable. Consider adding a **3pt accent bar** at the top of the card (full width, matching the pin's colour hex) that sits above the content area. This:
- Makes the pin's colour immediately visible from a distance
- Adds a signature design element (our pins feel different from generic cards)
- Costs almost no vertical space (3pt is negligible in a 140pt card)
- Works especially well with the priority tint overlay

```swift
// In cardBackground, layer a thin coloured rect at the top:
.overlay(alignment: .top) {
    Rectangle()
        .fill(Color(hex: pin.colorHex) ?? themeManager.color(.accentPrimary))
        .frame(height: 3)
}
```

This is optional but would give the compact pins a more distinctive look.

### S3: Tag Pill Wrapping — Explicit Layout

Instead of hoping tags fit, explicitly design for wrapping:

```swift
// Use a LazyVStack or wrap-aware layout instead of HStack
LazyVStack(alignment: .leading, spacing: themeManager.spacing(.xs)) {
    ForEach(tags.prefix(4), id: \.self) { tag in
        // pill
    }
}
```

Actually, for true wrapping in SwiftUI, consider using a custom `FlowLayout` or the `.lineLimit` + `.fixedSize(horizontal: false, vertical: true)` approach on the HStack. The tags should wrap naturally without clipping.

### S4: Selected State — minHeight Instead of Fixed Height

The spec mentions this briefly but it's important enough to call out explicitly:

```swift
// Current:
.frame(width: 160, height: 140)

// Selected should be:
.frame(width: 160)
.minHeight(140)
```

When the card is selected and shows the TextEditor, priority picker, and tag editor, it needs to grow. The fixed 140pt height will clip the editor. Using `minHeight` lets it expand naturally while keeping 140pt as the collapsed default.

### S5: Add a "Compact Pin" Visual Indicator in the UI

Since existing pins will be landscape (220×132) and new pins will be compact (160×140), users might be confused about why pins look different. Consider:
- A subtle badge or tooltip on first compact pin creation: "New compact pin format"
- Or just let it be — mixing sizes is normal on freeform boards and users adapt quickly

I'd lean toward **not** adding any indicator. The size difference is obvious and users will figure it out. Over-explaining is worse than under-explaining here.

---

## SUMMARY

| Area | Rating | Notes |
|---|---|---|
| Portrait shape | ✅ Good | 1.14:1 is subtle but functional |
| Font sizes | ⚠️ Concern | Title/body hierarchy too weak — keep title at 15pt |
| Padding/spacing | ⚠️ Concern | 4pt inner spacing is tight — test worst case |
| Shadows | ✅ Good | Well-calibrated reductions |
| Tag pills (4) | ⚠️ Concern | Won't fit on one line — plan for wrapping |
| Line limit (3) | ✅ Good | Smart density win |
| Overall spec | ✅ Approved | Solid, well-thought-out. 2-3 tweaks needed. |

**Bottom line:** The spec is fundamentally sound. The 23% area reduction will meaningfully improve canvas density. The main issues are the font hierarchy (keep title at 15pt) and the tag pill overflow (plan for wrapping). Fix those two things and this is ready to implement.

The accent bar suggestion (S2) is nice-to-have — it would give the pins more visual personality but isn't required for the spec to work.

— Mel 🎨
