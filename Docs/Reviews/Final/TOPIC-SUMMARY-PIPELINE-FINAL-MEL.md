# Final Verdict: Mel Review — Topic Summary Pipeline (Phase 2)

**Reviewed:** 2026-05-31T20:42:00+01:00  
**Reviewer:** Mel  
**Spec:** `Docs/Specs/Active/TOPIC-SUMMARY-PIPELINE.md` v2  
**Previous verdict:** APPROVE-WITH-CHANGES

## Verdict

**APPROVE-WITH-CHANGES**

The revised spec resolves the core UI/UX blockers from my initial review:

- Critical 1: Context menu placement, wording, and `doc.badge.plus` icon are now specified.
- Critical 2: Transient save states, timings, disabled state, tooltip, and VoiceOver announcements are defined.
- Critical 3: `EditTopicSheet` now extends the existing Context files section with a `Topic summary` row and found/missing/saving/error states.
- Critical 4: Persistent sidebar summary badges are explicitly avoided; the sidebar stays transient and uncluttered.
- Warning 1: iOS is deferred to Phase 2.5, which cleanly avoids misleading Mac-vs-phone save language in this phase.
- Warning 2: The visual language follows Phase 1 patterns: inline status, no toast system, no new badge vocabulary.
- Warning 3: The action name is now unambiguous: `Save Topic Summary`.
- Warning 4: Empty extraction now has a neutral `No changes to save` state plus the correct VoiceOver announcement.

## Remaining Change

Warning 5 is only partially addressed. A failed save currently shows `Could not save` for 4 seconds with an amber indicator and tooltip. That is acceptable as transient feedback, but the reason can disappear before Adam has time to inspect it.

Before build, add one recovery affordance:

- After a failed save, keep the failure reason available in row help/accessibility help until the next retry, successful save, topic selection change, or explicit dismissal.

No modal alert is needed. With that small addition, this is ready to implement.
