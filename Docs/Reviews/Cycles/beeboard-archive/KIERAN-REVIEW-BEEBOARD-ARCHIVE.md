# KIERAN-REVIEW-BEEBOARD-ARCHIVE.md

**Feature:** BeeBoard Archive Layer
**Commit:** 0582aac — `feat: add BeeBoard archive layer — completed pins disappear from active view`
**Reviewer:** Kieran
**Date:** 2026-06-16
**Verdict:** PASS

## Summary

Adds archive/restore functionality to BeeBoard pins. Right-click → "Archive Pin" moves pin to Archived view. Segmented picker (Active/Archived) in header. Undo toast with 3-second auto-dismiss. Restore with optional priority. Migration adds `isArchived` boolean column with idempotent column-exists check.

## MAJOR findings

None.

## MINOR findings

### M1. `matchingPinIds` is dead code
`BeeBoardViewModel.swift:72-74` — zero readers. The change to it in this diff is a no-op. Recommend deleting or documenting purpose.

### M2. Sort-snapshot scope mismatch when switching views
`applySort` captures snapshot from ALL pins but only sorts visible ones via `filteredPins`. Functionally correct (undo restores to pre-sort positions). Second sort in different view skips re-capture. Probably fine — user expectation is "go back to my manual layout" — but worth a comment.

### M3. Migration identifier ordering: "005" registered before "004"
GRDB orders by registration, not identifier name. Both are independent ALTER TABLE adds, so functionally fine. But the numeric suffix is misleading. Recommend renaming to maintain ordering convention.

## NITs

- N1: No tests for archive logic (consistent with no BeeBoard tests existing, but the feature is non-trivial)
- N2: No toast for restore operations (inconsistent with archive flow)
- N3: Undo timer not cancelled on `.onDisappear` (small leak, consistent with codebase pattern)
- N4: "Restore Pin" + "Restore to…" could be cleaner as single submenu
- N5: `restorePin(id:priority:)` re-assigns `colorHex` even when priority unchanged
- N6: `searchText` persists across Active/Archived view switches (UX choice, not bug)
- N7: Disabled `+` button tooltip still says "Create Pin" — could say "Switch to Active to create"
- N8: Mixed group (some archived, some active) renders partial in archive view — edge case, fine for v1

## Verified working

- ✅ Pin.init uses parameter (Q's stash bug fix landed correctly: `self.isArchived = isArchived`)
- ✅ CodingKeys includes `isArchived`
- ✅ `MutablePersistableRecord.update(db)` persists all encoded fields including `isArchived`
- ✅ Migration is idempotent
- ✅ Default value `false` consistent between Pin field and migration
- ✅ Undo toast cancels prior timer before scheduling new one
- ✅ Stale timer firing after Undo is a no-op (`archivedToastPinId == pinId` guard)
- ✅ Double-tap and `+` button disabled in archive view
- ✅ `archivePin` and `restorePin` are idempotent
- ✅ `filteredPins` correctly filters by archive state AND search text