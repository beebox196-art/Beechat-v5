# BeeChat v5 — Message Display & Management UX

**Created:** 2026-04-26  
**Source:** Adam's observations on message management and display behavior  
**Priority:** P2 (important UX improvements, not blocking)

---

## Problem Statement

1. **Message overload:** Loading all history into the message view causes performance issues and unnecessary memory usage. Need a smarter windowing approach.

2. **Scroll-to-latest fight:** When messages load oldest-first, the view starts at the top and the user (or the app) has to fight its way down to the latest message. This is janky and frustrating.

3. **No quick navigation:** Once scrolled up in history, there's no easy way to jump back to the latest message.

---

## Solutions (Priority Order)

### 1. Auto-Scroll to Bottom on Load [Small Effort]

**Behaviour:** When messages load (initial load or new message arrives while at bottom), the view automatically scrolls to show the latest message.

**Implementation:**
- Use `ScrollViewReader` with `scrollTo()` on message IDs
- Trigger scroll on initial load and on new incoming messages
- Only auto-scroll if user is already near the bottom (don't hijack if they're reading old messages)

**Pattern:** Every mature chat app (iMessage, WhatsApp, Slack) does this.

---

### 2. Jump to Bottom Button [Small Effort]

**Behaviour:** A floating button (↓ chevron) appears when the user has scrolled up away from the latest message. Tapping it scrolls instantly to the bottom.

**Implementation:**
- Track scroll position relative to content bottom
- Show overlay button when `isVisibleBottom == false`
- Tap → `scrollTo("bottom-anchor")` with animation
- Button fades out when user is already at bottom

**Reference:** iMessage, WhatsApp, Discord all use this pattern.

---

### 3. 50-Message Window + Load More [Medium Effort]

**Behaviour:** On opening a topic/chat, BeeChat fetches and displays only the last 50 messages. When the user scrolls to the top, a "load older messages" trigger fetches 50 more.

**Implementation:**
- Gateway call: `chat.history` with `limit=50` and `before=<oldest_message_id>`
- UI shows a loading indicator at the top while fetching
- Messages are prepended to the view (not replacing)
- Smooth scroll position preservation (don't jump when older messages load in above)

**Data flow:**
```
Open chat → fetch last 50 messages → display
User scrolls to top → show loading spinner → fetch 50 more → prepend
User scrolls to top again → repeat
```

---

### 4. Auto-Archive Older Messages [Medium Effort]

**Behaviour:** Messages older than the current 200-message window get auto-archived to a local archive store. They remain searchable and retrievable but aren't in the active display list.

**Implementation:**
- Archive store: Separate SQLite table or flat JSON files (per-topic, per-day)
- Threshold: When active messages exceed 200, archive the oldest batch
- Archive is accessible via "load more" (same as #3 — just fetches from local archive instead of gateway)
- Memory systems continue to feed from gateway side regardless

**Why flat files could work:**
- Simple to implement
- Easy to browse/debug
- No database migration complexity
- Messages beyond 200 are rarely needed in the UI
- Gateway holds the canonical history anyway

---

## Architecture Notes

- **UI display layer ≠ persistence layer.** The database can hold everything; the UI shows a window.
- **Gateway is the source of truth.** BeeChat's local DB is a cache, not the canonical store.
- **Memory systems (LCM, etc.)** feed from the gateway side. The UI archive is for user convenience only.

---

## Acceptance Criteria

- [ ] Opening a chat auto-scrolls to the latest message
- [ ] New incoming messages auto-scroll when user is at bottom
- [ ] Jump to bottom button appears when scrolled up
- [ ] Initial load shows last 50 messages (not entire history)
- [ ] Scrolling to top triggers load of 50 older messages
- [ ] No visible jank when older messages load in above current position
- [ ] Messages beyond 200 are auto-archived locally
- [ ] Archived messages are retrievable via "load more"

---

## Related Files

- `BeeChatUI/Views/MessageListView.swift` — main message scroll view
- `BeeChatUI/Views/MessageBubbleView.swift` — individual message rendering
- `BeeChatSyncBridge/` — event routing and message persistence
- `BeeChatPersistence/Repositories/MessageRepository.swift` — message data access