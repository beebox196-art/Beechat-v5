# BeeBoard Compact Pin Spec v2

**Date:** 2026-05-11  
**Author:** Bee (with Kieran & Mel review input)  
**Status:** v2 — incorporating team review feedback  

---

## Problem

Current pin cards are too large for the restricted BeeBoard canvas space, especially when multiple pins are added. The landscape aspect ratio and generous font sizes mean the board fills up fast and pins overlap.

## Current Dimensions

| Property | Current Value |
|---|---|
| **Pin width** | 220pt |
| **Pin height** | 132pt |
| **Aspect ratio** | ~1.67:1 (landscape) |
| **Card padding** | `themeManager.spacing(.md)` (~16pt) |
| **Inner spacing** | `themeManager.spacing(.sm)` (~8pt) |
| **Title font** | `subheading` (~15pt) |
| **Body font** | `body` (~13pt) |
| **Date font** | `caption2` (~10pt) |
| **Tag pill font** | `caption2` (~10pt) |
| **Tag pill padding** | `.horizontal(6), .vertical(2)` |
| **Colour dot** | 10×10pt |
| **Expand icon** | 10pt system |
| **Priority icon** | 9pt system |
| **Selection shadow** | radius 8, y-offset 4 |
| **Unselected shadow** | radius 4, y-offset 2 |
| **Selection border** | 2pt |

## Proposed Changes (v2)

### 1. Smaller Pin Box — Portrait Orientation

| Property | Current | Proposed | Change |
|---|---|---|---|
| **Width** | 220pt | 160pt | −60pt (27% narrower) |
| **Height** | 132pt | 140pt | +8pt (taller for portrait) |
| **Aspect ratio** | 1.67:1 (landscape) | ~1.14:1 (portrait-ish) | Taller than wide |

### 2. Font Size Changes

| Element | Current Token | Current ~Size | Proposed Token | Proposed ~Size | Rationale |
|---|---|---|---|---|---|
| **Title** | `subheading` | ~15pt | `subheading` | ~15pt | **Kept at 15pt** — preserves hierarchy against 11pt body |
| **Body** | `body` | ~13pt | `caption` | ~11pt | −2pt, more compact, still legible on Retina |
| **Date** | `caption2` | ~10pt | `caption2` | ~10pt | Unchanged |
| **Tag pills** | `caption2` | ~10pt | `caption2` | ~10pt | Unchanged |

**v1 had title dropping to 13pt — both reviewers flagged that a 2pt gap (13 vs 11) is too weak. Keeping title at 15pt gives a clear 4pt hierarchy (15 vs 11) that reads well at small sizes.**

### 3. Padding & Spacing Reduction

| Property | Current | Proposed |
|---|---|---|
| **Card padding** | `.md` (~16pt) | `.sm` (~8pt) |
| **Inner spacing** | `.sm` (~8pt) | `.xs` (~4pt) |
| **Tag pill padding** | `h:6, v:2` | `h:4, v:1` |

**Note:** Inner spacing at 4pt is aggressive. If worst-case testing (long title + 3-line body + wrapped tags) feels cramped, bump to 6pt (halfway between `.xs` and `.sm`).

### 4. Smaller UI Elements

| Property | Current | Proposed |
|---|---|---|
| **Colour dot** | 10×10pt | 8×8pt |
| **Expand icon** | 10pt | 8pt |
| **Paperclip icon** | 9pt | 8pt |
| **Unselected shadow** | radius 4, y-offset 2 | radius 3, y-offset 1 |
| **Selection shadow** | radius 8, y-offset 4 | **KEPT at 8, y-offset 4** |
| **Selection border** | 2pt | **KEPT at 2pt** |
| **Unselected border** | 1pt | 1pt (unchanged) |

**v1 reduced selection shadow/border. Both reviewers flagged that smaller cards need *stronger* selection affordance, not weaker. Unselected shadow is reduced (lighter resting state); selection shadow and border stay at current values for clear contrast.**

### 5. Read-Only Body — 3 Lines

Current: `.lineLimit(2)` on body text.  
Proposed: `.lineLimit(3)` — with 11pt font and portrait card, 3 lines fit in similar vertical space as 2 lines at 13pt did before. More info visible per pin.

### 6. Tag Pills — 4 with Wrapping

Current: `.prefix(3)` tags shown.  
Proposed: `.prefix(4)` with explicit wrapping support.

**v1 claimed "4 tags fit on the narrower card." Both reviewers proved this mathematically incorrect — 4 pills at ~48pt each need ~204pt but content width is only 144pt. Tags will wrap to a second row on longer names. This is acceptable and explicitly designed for:**

- Use `.fixedSize(horizontal: false, vertical: true)` on the tag HStack to allow natural wrapping
- Or use a wrap-aware `FlowLayout` for pills
- Card height (140pt) accommodates 2 rows of tags comfortably

### 7. Card Height — Fixed Frame (NOT minHeight)

**v1 proposed switching to `.frame(width:) + minHeight` for card expansion on selection. Kieran identified a critical bug: `.position()` centres the view at the coordinate, so variable height causes the card to shift both up and down, creating a visual jump and potential off-canvas clipping.**

**Fixed approach:** Keep `.frame(width: 160, height: 140)` for the card container. When selected, inline editing (TextEditor, priority picker, tag editor) stays within the fixed frame. Full editing uses the existing PinDetailView sheet, which is already built for this purpose.

This means:
- Unselected: 160×140 fixed frame, read-only content
- Selected: 160×140 fixed frame, inline edit fields replace read-only content (same as current behaviour)
- Full edit: PinDetailView sheet (600×400+ modal)

### 8. Grid Sort — Dynamic Spacing

**v1 proposed hardcoded `columnWidth: 200, rowHeight: 200`. Kieran flagged that existing 220pt-wide pins on a 200pt column grid overlap their neighbour by 20pt.**

**New approach:** `applyGridLayout` computes column width and row height dynamically based on the actual pins on the board:

```swift
let maxPinWidth = pins.map(\.width).max() ?? 160
let maxPinHeight = pins.map(\.height).max() ?? 140
let columnWidth = maxPinWidth + 40  // 20pt padding each side
let rowHeight = maxPinHeight + 40  // 20pt padding each side
```

This accommodates mixed-size boards (old landscape + new compact pins) without overlap.

### 9. Optional: Top Accent Bar

Mel suggested adding a 3pt coloured accent bar at the top of each card, matching the pin's `colorHex`. Benefits:
- Makes pin colour immediately visible from a distance (the 8pt dot is subtle)
- Adds visual personality / signature element
- Costs negligible vertical space in a 140pt card

```swift
// In cardBackground, layer above content:
.overlay(alignment: .top) {
    Rectangle()
        .fill(Color(hex: pin.colorHex) ?? themeManager.color(.accentPrimary))
        .frame(height: 3)
}
```

**Not required for v1, but recommended as a follow-up polish.**

### 10. Optional: Non-Retina Font Scaling

If `NSScreen.main?.backingScaleFactor == 1.0`, bump all font tokens up one step (caption → body, body → subheading). This prevents readability issues on non-Retina external monitors (common with Mac mini setups).

**Not required for v1 — note as a known limitation.**

---

## What Does NOT Change

- **Pin data model** — `width` and `height` fields remain `Double`. New defaults only.
- **Database schema** — no migrations. Existing pins keep stored dimensions.
- **Pin detail view** — full-size editing/viewing stays the same.
- **Canvas size** — 1800×1200 stays the same.
- **Drag behaviour** — offset-based, model commit on end. Unchanged.
- **Group frames** — calculated dynamically from pin positions. Auto-adjust.
- **Touch targets / accessibility** — `contentShape` already covers the card. 160pt width exceeds macOS 24pt minimum.

---

## Impact on Existing Pins

Existing pins keep their 220×132 stored dimensions. New pins default to 160×140.

The two sizes coexist on the same board. Mixed sizes are normal on freeform canvases (Freeform, Miro both support this). Grid sort uses dynamic spacing to prevent overlap.

**Future optional:** A "Resize all pins to compact" button in the header. Not in v1 scope.

---

## Files to Change

| File | Change |
|---|---|
| `BeeBoardPinCard.swift` | Font tokens (body only), padding/spacing tokens, element sizes, tag pill count + wrapping, shadow/border adjustments |
| `BeeBoardViewModel.swift` | `createPin(at:)` default width/height, `createPinAtCenter()` same, `applyGridLayout` dynamic spacing |
| `Pin.swift` | Default `width: 220, height: 132` → `width: 160, height: 140` |

**3 files, ~25 line changes.** No structural changes, no new dependencies, no migrations.

---

## Review Changes from v1 → v2

| Item | v1 | v2 | Reason |
|---|---|---|---|
| Title font | Drop to `body` (13pt) | **Keep at `subheading` (15pt)** | Mel: 2pt gap too weak at small sizes |
| Tag pills | 4 fits on one line | **4 with explicit wrapping** | Kieran + Mel: math proves 4 don't fit on 144pt |
| Card height | `minHeight` on selection | **Fixed `frame(width:height:)`** | Kieran: variable height + `.position()` causes jump |
| Selection shadow | Reduce to 5pt/2pt | **Keep at 8pt/4pt** | Kieran: smaller cards need stronger selection affordance |
| Selection border | Reduce to 1.5pt | **Keep at 2pt** | Same rationale |
| Grid spacing | Hardcoded 200×200 | **Dynamic, based on max pin dims** | Kieran: mixed sizes cause overlap on fixed grid |
| Tag pill layout | HStack | **Wrap-aware layout** | Accommodates overflow gracefully |

---

## Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Mixed pin sizes on same board | Expected | Dynamic grid spacing; sizes coexist naturally on freeform canvas |
| Inner spacing at 4pt feels cramped | Medium | Test worst case; bump to 6pt if needed |
| Long titles truncate at 144pt content width | Low | 20-25 char limit is reasonable for pin titles; detail view shows full text |
| Tag wrapping adds vertical height | Low | 140pt card height has room for 2 rows of tags |
| Non-Retina readability at 11pt body | Low | Note as known limitation; optional font scaling as future enhancement |

---

*Spec v2 updated following review by Kieran (adversarial) and Mel (UI design).*