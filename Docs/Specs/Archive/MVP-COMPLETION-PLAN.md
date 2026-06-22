# BeeChat v5 — MVP Completion Plan

**Date:** 2026-04-23  
**Authors:** Bee (Coordinator), Kieran (Independent Review), Mel (Design Lead)  
**Baseline:** PHASE-4-UI-SPEC.md v1.0 + DESIGN-SYSTEM.md  
**Latest Commit:** `2c2c5bd` — Fix switchTheme bug  
**Status:** Core chat loop working — gaps identified, prioritised, ready for team deployment

---

## Current State

✅ **Working (9/15 spec items):**
- Send/receive text messages end-to-end
- Topic sidebar with create/delete
- Streaming indicator (typing dots + live text)
- GRDB persistence (messages survive app restart)
- Gateway connection with status bar
- Artisanal Tech theme (colours + typography correct)
- SyncBridge wiring (session list, message stream)

⚠️ **Decisions needed from Adam:**
1. **Sidebar vs Top-Bar** — Spec says single-canvas with horizontal TopicBar. We built NavigationSplitView sidebar. Recommendation: **keep sidebar** (more macOS-native, better for topic management). Update spec to match.
2. **StreamingBubble** — Spec says "NEVER show streaming text." We show live text with animated cursor. It works well. Recommendation: **keep it**, update spec.

---

## Gap Analysis & Plan

### P0 — Quick Wins (Done ✅)

| Item | Status | Notes |
|------|--------|-------|
| `switchTheme()` inverted logic bug | ✅ Fixed | `guard id == currentTheme.id` → `guard id != currentTheme.id` |
| `loadPersistedTheme()` no-op | ✅ Fixed | Now calls `switchTheme(to:)` with persisted value |
| `Theme.theme(for:)` lookup | ✅ Added | Required for theme switching |

---

### P1 — Foundation (Build a solid base)

| # | Item | Description | Effort | Owner |
|---|------|-------------|--------|-------|
| 1.1 | **Theme token system** | Build Spacing, Radius, Shadow, Animation tokens. Currently only Color + Typography exist. All other values are hardcoded throughout the codebase. | 2-3h | Mel + Q |
| 1.2 | **Replace hardcoded values** | Swap ~20 hardcoded padding/spacing/radius/shadow/animation values across 6 files to use the new tokens. | 1-2h | Q |
| 1.3 | **Theme switcher UI** | Build `ThemePicker` + `ThemePreviewCard` components. Wire to `ThemeManager.switchTheme()`. Place in a settings menu or popover. | 2-3h | Q + Mel |
| 1.4 | **7 additional theme definitions** | Define the remaining 7 themes from the spec (Dark, Light, Starfleet LCARS, Artisanal Tech ✅, Minimal, Holographic Imperial, Water Fluid UI, Living Crystal). | 2-3h | Mel |

**P1 Total:** ~8-11 hours

---

### P2 — Polish (Make it feel complete)

| # | Item | Description | Effort | Owner |
|---|------|-------------|--------|-------|
| 2.1 | **VoiceOver labels** | Add accessibility labels to all interactive elements. Currently only 2 of ~12+ are labelled. | 1h | Q |
| 2.2 | **GatewayStatusBar colour tokens** | Replace hardcoded `.green`/`.yellow`/`.red` with `themeManager.color(.success/.warning/.error)`. | 30m | Q |
| 2.3 | **Menu shortcuts** | Wire "New Topic" (Cmd+N), "Next Topic" (Cmd+→), "Previous Topic" (Cmd+←) menu items — currently stubs. | 1h | Q |
| 2.4 | **Minimum window size** | Enforce 500×400 minimum via `.frame(minWidth:minHeight:)` on MainWindow. | 30m | Q |

**P2 Total:** ~3 hours

---

### P3 — Features (Nice-to-have)

| # | Item | Description | Effort | Owner |
|---|------|-------------|--------|-------|
| 3.1 | **Emoji picker** | Add emoji button to composer toolbar, macOS native emoji picker (Cmd+Ctrl+Space) already works in NSTextView — just needs a visible button. | 1-2h | Q + Mel |
| 3.2 | **Voice recording** | Implement `startRecording()`/`stopRecording()` with AVAudioRecorder, M4A format, 30s max, save to `~/BeeChat/Media/`. Build `VoiceNotePlayer` component. | 4-6h | Q |
| 3.3 | **File/Image attachments** | Wire attachment picker buttons (currently `/* Phase 4B */` stubs) to open panel, save to media folder, display in message. | 3-4h | Q |

**P3 Total:** ~9-12 hours

---

## Team Deployment Plan

### Phase 1: Foundation (P1) — Parallel Work
```
Mel (Design):
  → Build SpacingToken, RadiusToken, ShadowToken, AnimationToken with values
  → Define remaining 7 themes (Dark, Light, Starfleet, Minimal, Holographic, Water, Crystal)
  → Review ThemePicker UI design

Q (Builder):
  → Build ThemePicker + ThemePreviewCard components
  → Replace hardcoded values with tokens across 6 files
  → Fix GatewayStatusBar colours, add VoiceOver labels
  → Wire menu shortcuts, enforce minimum window size
```

### Phase 2: Polish (P2) — Sequential
```
Q: Complete P2 items → Kieran reviews → Mel design-checks
```

### Phase 3: Features (P3) — As Needed
```
Q: Emoji picker → Voice recording → File attachments
Mel: Design review for each feature
Kieran: Code review for each feature
```

---

## Spec Updates Required

Regardless of implementation order, the Phase 4 spec needs two updates:

1. **Layout:** Update from "single-canvas, no sidebar" to "NavigationSplitView sidebar + message canvas"
2. **Streaming:** Update from "typing indicator only" to "typing indicator + live streaming bubble"

These are documentation updates, not code changes — the code already implements the better UX.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|-----------|
| Theme switching breaks UI if a theme has missing tokens | Token resolvers already have fallbacks (`?? .black`, `?? .body`) |
| Voice recording needs microphone permission | Add `NSMicrophoneUsageDescription` to Info.plist |
| 7 new themes could introduce visual regressions | Mel reviews each theme before merge |
| Token changes could shift layouts | Kieran verifies build + visual check after each token category |

---

## Success Criteria

- [ ] All 15 Phase 4A spec items marked DONE
- [ ] 8 themes defined and switchable via UI
- [ ] Zero hardcoded colour/font/padding values (all token-driven)
- [ ] VoiceOver on all interactive elements
- [ ] Menu shortcuts functional
- [ ] Emoji, voice recording, file attachments available in composer

---

**Next Step:** Adam reviews this plan, approves priorities, and we deploy the team.
