# Mel's UI/UX Review — Session Reset Options

**Reviewer:** Mel (UI/UX)  
**Date:** 2026-05-14  
**Spec:** SPEC-session-reset-options.md  

---

## 1. Red Dot vs Amber Dot vs No Dot

### Option A (Auto-reset): Remove the red dot entirely

If the session auto-resets, the red dot signals a problem that already solved itself — that's confusing. The spec suggests keeping it as an "amber informational dot" instead, but I think that's still wrong. A persistent amber dot saying "this session was auto-compacted" is visual noise. The user can't act on it. What are they supposed to *do* with that information?

**My recommendation for Option A:** Remove the dot. Show a brief inline toast ("Session refreshed") when `didStopAutoReset` fires, then dismiss it after ~3 seconds. No persistent indicator.

### Option B (Manual trigger): Keep the dot, but change the color

The current red dot with a red glow (`Color.red.opacity(0.4)` shadow) is visually alarming. Red = danger in every design system. A session at 50% usage isn't dangerous yet — it's a heads-up. And it's sitting right next to the blue unread dot, which creates a confusing dual-dot situation.

**My recommendation for Option B:**
- Change the reset-indicator dot from **red** to **amber/orange** (`Color.orange` or a custom warm amber like `Color(red: 0.91, green: 0.72, blue: 0.29)` — the same honey colour already used for topic health). This aligns with the existing health colour system (green → honey → rose) and signals "attention, action available" rather than "DANGER."
- Keep the glow but make it amber: `.shadow(color: Color.orange.opacity(0.3), radius: 3)`.
- The dot should only appear at ≥50%. It should disappear immediately after a successful reset.

This gives a clear visual hierarchy: **blue = unread**, **amber = reset available**, **green/honey/rose = topic health**. Three different semantics, three different colours. No confusion.

---

## 2. Confirmation Alert for Manual Reset (Option B)

**Yes, absolutely show a confirmation alert.** Here's why:

- **Reset is destructive-adjacent.** It clears the session context. Even though recent messages are preserved in the `[SESSION-CONTEXT]` block, the user needs to understand what they're about to do. A one-tap action with no confirmation is a trap for accidental taps on a small target.
- The red dot is only 10×10 points. Fat fingers on a touch device (or a misclick on trackpad) could easily trigger it.
- macOS context menus are easy to misfire on — right-click, slight mouse movement, and you've hit "Reset Session" instead of "Delete Topic" or whatever else is nearby.

**Recommended alert:**

```
Title: "Reset Session?"
Message: "This will clear the conversation context for "[topic title]". 
The last 30 messages will be preserved as context for the next reply.
Buttons: [Cancel]  [Reset]
```

The key UX detail: **explain what's preserved**, not just what's lost. This reduces anxiety and helps the user make an informed decision. The current spec's `[SESSION-CONTEXT]` mechanism means they're not losing everything — tell them that.

**Also:** Disable the composer during the reset operation. The spec mentions this but I want to emphasise it — if the user can type and send during a reset, that's a race condition that produces confusing results. Show the same "Refreshing context..." indicator that `autoResetting` already shows.

---

## 3. Context Menu UX — "Reset Session" Next to "Delete Topic"

This is the most dangerous UX issue in the spec. Currently the context menu only has "Delete Topic" with `.destructive` role. Adding "Reset Session" next to it without differentiation is a problem:

- Both sound like "end this thing." A user scanning quickly could hit "Reset Session" when they meant "Delete Topic" or vice versa.
- "Delete Topic" has `role: .destructive` (red text in macOS). "Reset Session" should NOT be destructive — it's a recoverable action. But if it appears in plain text next to a red destructive item, it looks like the "safe" option, which could lead to accidental resets.

**My recommendation:**

```
.contextMenu {
    Button("Reset Session") {
        showResetConfirmation = true
    }
    .disabled(sessionUsage == nil || sessionUsage! < 0.50)  // Only enabled when dot would show
    
    Divider()  // ← Visual separator
    
    Button("Delete Topic", role: .destructive) {
        deleteTopic(topic.id)
    }
}
```

Key design decisions:
1. **Divider between them.** This is a strong visual signal that these are different categories of action.
2. **"Reset Session" is not destructive.** It shows in normal (black) text, not red. This makes it clearly different from "Delete Topic."
3. **Disabled when under 50% usage.** If there's nothing to reset, the option is greyed out. This reinforces the "you only need this when the dot appears" mental model.
4. **The label "Reset Session" is clear.** Don't soften it to "Refresh" or "Compact" — the user needs to know this is a significant action. But don't make it sound catastrophic either.

**Alternative naming consideration:** "Compact Session" or "Refresh Context" might be less scary than "Reset." But "Reset" is what the codebase calls it and what the user will see in error messages. Consistency matters. Stick with "Reset Session."

---

## 4. Accessibility Concerns

### Current state (both options)

The `SessionRow` accessibility is decent but has gaps:

**Good:**
- Health dot has `.accessibilityLabel("Topic health: \(healthDescription)")` and `.accessibilityValue`.
- Combined accessibility label includes topic title, health, and message count.
- The red dot button has `.accessibilityLabel("Reset session: \(topic.title) is at X% context usage")`.

**Problems:**

1. **Red dot accessibility label says "Reset session" as an action label on what's currently an inert indicator.** If Option A (auto-reset) is chosen, this label becomes misleading — there's nothing to reset. Remove it entirely.

2. **The unread blue dot has no accessibility label.** A VoiceOver user won't know what the blue dot means. Fix:
   ```swift
   Circle()
       .fill(themeManager.color(.accentPrimary))
       .frame(width: 8, height: 8)
       .accessibilityLabel("Unread messages")
   ```

3. **Three visual dots in a row is hard to parse for VoiceOver users.** Health dot + unread dot + reset dot = three status indicators with no grouping. The combined `accessibilityLabel` on the row should narrate all three states:
   ```
   "Project Q, Getting large, 87 messages, unread, session at 58% usage, reset available"
   ```
   Currently the label only includes title + health + count + unread. The reset state is announced separately via the button, which means VoiceOver reads it as two separate elements. This should be unified.

4. **Dynamic state changes need announcements.** When the amber/reset dot appears, VoiceOver should announce it. Use `@A11yVoiceOver` announcements or `UIAccessibility.post(notification: .announcement, argument:)` to say "Session approaching capacity" when the dot first appears.

5. **The confirmation alert for Option B needs keyboard navigation.** The [Reset] button should be the default button (reachable via Enter), and [Cancel] should be reachable via Escape. SwiftUI `.alert` handles this automatically, but if we use a custom sheet, we need to wire `.keyboardShortcut(.defaultAction)` and `.keyboardShortcut(.cancelAction)`.

6. **Colour contrast.** The current red dot (`Color.red`) on a sidebar background needs to meet WCAG 2.1 minimum contrast. A 10px dot on a potentially dark sidebar — let's verify this meets the 3:1 minimum for non-text elements. `Color.red` on typical macOS sidebar backgrounds should be fine, but amber might be borderline. Test with Accessibility Inspector.

### Specific to Option B

- The reset button dot (10×10) is small for motor-impaired users. Consider making the hit target larger: `.frame(width: 10, height: 10)` with `.contentShape(Rectangle()).frame(width: 24, height: 24)` to give a larger tap target while keeping the visual dot small.
- The confirmation alert is an accessibility win — it prevents accidental activation. Keep it.

---

## Summary of Recommendations

| Issue | Recommendation |
|---|---|
| Dot colour (Option A) | Remove entirely. Toast on auto-reset. |
| Dot colour (Option B) | Change red → amber/orange. Aligns with existing health colours. |
| Confirmation (Option B) | **Yes.** Required. Explain what's preserved, not just what's lost. |
| Context menu | Add divider between Reset and Delete. Disable Reset when under 50%. |
| Accessibility — unread dot | Add `.accessibilityLabel("Unread messages")`. |
| Accessibility — combined label | Include reset state in the row's combined accessibility label. |
| Accessibility — announcements | Announce dot appearance via VoiceOver. |
| Accessibility — hit target | Enlarge reset dot tap target to 24×24 with `contentShape`. |
| Accessibility — contrast | Verify amber dot meets WCAG 3:1 on sidebar background. |

---

## On the Hybrid Option (Question 4 from the spec)

I like the hybrid idea — auto-reset at 80% as a hard ceiling, amber dot at 50% for optional early reset. This is actually the best UX:

- Most users never need to think about it. Auto-reset handles the ceiling.
- Power users (like Adam) who want control get the amber dot for early resets.
- The amber dot is optional and informational, not alarming.
- No data loss risk because the ceiling always catches it.

If we go hybrid, the visual treatment is:
- **50-79%:** Amber dot, tappable, triggers confirmation alert.
- **≥80%:** Auto-reset fires. No dot needed (or briefly show an "auto-refreshed" toast).

This is more code but the best user experience. From a UI perspective, it's the cleanest story.