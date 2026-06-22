# Mel's Final UX Sign-Off — Session Reset Hybrid Spec

**Reviewer:** Mel (UI/UX)  
**Date:** 2026-05-14  
**Spec:** SPEC-session-reset-hybrid-final.md  

---

## 1. Checklist: Are All My UX Concerns Addressed?

| Concern | Status | Notes |
|---|---|---|
| Amber dot instead of red | ✅ Resolved | `Color.orange` with `Color.orange.opacity(0.3)` shadow. Correct semantic. |
| Confirmation alert with "what's preserved" messaging | ✅ Resolved | Alert says *"The last 30 messages will be carried forward as context for the next reply."* — exactly the framing I wanted. |
| Context menu divider between Reset and Delete | ✅ Resolved | `Divider()` between the two items. Clear visual separation. |
| Reset not styled as destructive | ✅ Resolved | `role: .none` on the Reset button in the alert. Normal text in context menu, not red. |
| Disabled when under 50% | ✅ Resolved | `.disabled(sessionUsage == nil \|\| sessionUsage! < 0.50)` on the context menu item. |
| Hit target 24×24 | ✅ Resolved | `.contentShape(Rectangle()).frame(width: 24, height: 24)` on the amber dot. |
| Unread dot accessibility label | ✅ Resolved | `.accessibilityLabel("Unread messages")` added. |
| WCAG contrast for amber on sidebar | ⚠️ Needs verification | The spec says "verify amber dot on sidebar background meets 3:1 minimum for non-text elements." This is correctly flagged but not resolved — it needs testing in Accessibility Inspector during implementation. Amber/orange on dark sidebar backgrounds can be borderline. **Action:** Q should verify this during implementation with Accessibility Inspector. |
| VoiceOver announcement when dot appears | ✅ Resolved | Listed in accessibility section: announce `"Session approaching capacity"` when the amber dot first appears. |

**Verdict:** 8/9 fully resolved, 1 (WCAG contrast) correctly deferred to implementation testing. Acceptable.

---

## 2. Auto-Reset Toast: "Session refreshed" — Wording & Duration

### Wording
**"Session refreshed" is good but could be slightly better.**

The word "refreshed" is passive and doesn't tell the user *what* happened or *why*. Since this fires automatically at 80%, the user didn't initiate it — a brief explanation reduces the "wait, what just happened?" moment.

**Suggested alternatives:**
- `"Context refreshed automatically"` — clarifies both what and why.
- `"Session context refreshed"` — more specific than just "Session refreshed."

That said, "Session refreshed" is fine for v1. It's short and non-alarming. If we get user feedback that it's confusing, we can iterate. **Not blocking.**

### Duration
**3 seconds is right.** Toasts for informational, non-actionable events should be brief. 3 seconds is long enough to read two words, short enough to not be annoying. No change needed.

---

## 3. Combined Accessibility Label Review

The spec proposes:
```
"Project Q, Getting large, 87 messages, unread, session at 58% — reset available"
```

**This reads well.** It flows logically: topic name → health → count → unread state → session state → available action. The dash before "reset available" creates a natural pause that separates status from action.

**One minor improvement:** "reset available" could be clearer for VoiceOver users who don't know what "reset" means in this context. Consider:
```
"Project Q, Getting large, 87 messages, unread, session at 58% — reset available to free up space"
```

This adds purpose to the action label. But it's a nice-to-have, not a blocker. The current format is already much better than the original separate-element approach.

**Verdict:** Acceptable as-is. Optional improvement noted above.

---

## 4. UX Gaps in the Flow

### Gap: User sends a message while manual reset confirmation alert is showing

The spec says the compose field is disabled during the reset operation (via `manualResetting` state). But the confirmation alert is a *separate* phase — the alert shows *before* the reset starts. So the sequence is:

1. User taps amber dot → confirmation alert appears
2. User has NOT yet confirmed → compose field is still active
3. User could type and send a message while the alert is showing

**Is this a problem?** Not really. The alert is modal on macOS — it blocks interaction with the main window. SwiftUI `.alert` as a sheet prevents interaction with the underlying view. The user literally *can't* send a message while the alert is displayed.

✅ **No gap here.** SwiftUI modal alerts prevent interaction. Just make sure the alert is presented as a proper `.alert` modifier, not a custom overlay.

### Minor note: Double-tap guard on the amber dot

The spec has a guard in `manualReset()` checking `pendingResetContext[sessionKey] != nil`. Good — this prevents double-taps. But there's a timing gap: the user could tap the amber dot, the confirmation alert appears, and while they're reading it, tap the dot again (the alert would block the tap on macOS, but on iOS this could be an issue if ported). The guard handles this anyway, so it's fine.

### Minor note: Topic name in confirmation alert

The spec shows the alert message as:
> "The last 30 messages will be carried forward as context for the next reply."

My original review suggested including the topic name:
> "This will clear the conversation context for '[topic title]'. The last 30 messages will be carried forward as context for the next reply."

The final spec simplified this. I understand why — shorter is better for an alert. But including the topic name helps the user confirm they're resetting the *right* session, especially if they have many topics. **Recommendation:** Add the topic name back if it's easy to thread through. If not, the current wording is acceptable.

---

## Final Verdict

**✅ Sign-off with minor notes.**

The hybrid spec addresses all of my original concerns. The remaining items are:

1. **WCAG contrast verification** — must be tested during implementation, not a spec issue.
2. **Toast wording** — "Session refreshed" is fine for v1, consider "Context refreshed automatically" as a future improvement.
3. **Accessibility label** — current format is good, optional improvement to add purpose ("to free up space").
4. **Topic name in alert** — nice to have, not blocking.

None of these are blockers. The spec is ready for implementation.

---

*Mel — UX sign-off complete.* 🐝