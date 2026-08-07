# WP-2I Day-Boundary Date Headers

**Status:** SPEC (drafted 2026-08-07, Adam's choice uplift after foundation sign-off).
**Branch:** `feat/transcript-integration` (will be folded into the foundation cut).
**Scope:** Message window only. No bridge contract change beyond adding `timestamp`
to the payload.

---

## What it is

Insert a centred, dim-text separator between messages when the calendar date
rolls over. iMessage / WhatsApp / Slack convention. Closes a long-standing
visual gap in the transcript: right now a conversation that spans yesterday
and today reads as one undifferentiated block.

## DOM contract

Headers are direct children of `#transcript`, positioned between `.msg`
elements. Same selector pattern as the existing `.msg` / `.bubble` /
`.sender` / `.badge` chain — single source of truth for layout.

```html
<article class="msg" data-id="m1" data-role="user">…</article>
<div class="day-header" data-date="2026-08-06">Yesterday</div>
<article class="msg" data-id="m2" data-role="assistant">…</article>
<article class="msg" data-id="m3" data-role="user">…</article>
<div class="day-header" data-date="2026-08-07">Today</div>
<article class="msg" data-id="m4" data-role="assistant">…</article>
```

`data-date` is the local-time `YYYY-MM-DD` key. The visible label follows
the rule below.

## Label rule (local time)

| Condition                                  | Label                |
|--------------------------------------------|----------------------|
| Same calendar day as today                 | `"Today"`            |
| One calendar day before today              | `"Yesterday"`        |
| 2 – 6 calendar days before today           | weekday long, e.g. `"Tuesday"` |
| 7+ days before today, same calendar year   | `"Tue 6 Aug"`        |
| 7+ days before today, different year       | `"Tue 6 Aug 2025"`   |

Computed in JS from `new Date(timestamp)`. Uses `Intl.DateTimeFormat` for
the weekday/month names so the strings stay locale-correct (we don't ship
strings ourselves).

## Invariants after every DOM-mutating bridge call

For the full DOM in `#transcript`:

1. **Adjacent pair rule.** For each adjacent pair of `.msg` elements
   `M1, M2`: if `dateKey(M1.timestamp) != dateKey(M2.timestamp)`,
   exactly one `.day-header` between them; if equal, none.
2. **Header labels its successor.** For each `.day-header` `H`, the
   next `.msg` after `H` has timestamp on the date in `H.dataset.date`.
3. **No header before the first message.** The first `.msg` in
   `#transcript` has no `.day-header` immediately before it (the
   conversation just starts — iMessage convention).
4. **Headers never sit between headers.** Always `… .msg, .day-header,
   .msg, .msg, .day-header, .msg …` pattern.

## Per-call insertion logic

### `setTopic({topicId, messages, canLoadEarlier})`

Clear all `.msg` and `.day-header` from `#transcript` (preserving
`#load-earlier`, `#thinking`, `#jump`). Then walk the new messages from
the start; for each message `m`:

- If `i == 0` OR `dateKey(P[i-1].timestamp) != dateKey(m.timestamp)`:
  insert a `.day-header` for `dateKey(m.timestamp)` before `m`'s node.
- Insert `m`'s node.

### `upsertMessages(messages, canLoadEarlier)`

For each upserted message `m` (in order):

- If `m` is being inserted (not updating existing) AND its `dateKey`
  differs from the previous adjacent `.msg`'s `dateKey` (or there is
  no previous message), insert a `.day-header` for `dateKey(m)` before
  `m`'s node.
- For updates, no header logic — the message was already there, the
  header already exists or doesn't, and the invariant is already held.

### `prependEarlier(messages)`

Walk the prepended block `P` from the start; for each `P[i]`:

- If `i == 0` OR `dateKey(P[i-1].timestamp) != dateKey(P[i].timestamp)`:
  insert a `.day-header` for `dateKey(P[i].timestamp)` before
  `P[i]`'s node.

After walking `P`, check the **boundary** between the last prepended
message and the first existing message. If
`dateKey(P[-1].timestamp) != dateKey(E.timestamp)`, insert a
`.day-header` for `dateKey(E.timestamp)` between them.

Insert the resulting sequence at the top of `#transcript` (after
`#load-earlier` if present), preserving the existing
`scrollTop += (newScrollHeight − oldScrollHeight)` invariant from T3.

### `setStreaming`, `setThinking`

No header logic. The streaming/thinking indicator sits at the bottom
and does not affect header placement.

## Bridge payload change

`MessagePayload` gains one optional field:

```swift
dict["timestamp"] = msg.timestamp.timeIntervalSince1970 * 1000  // epoch ms (JS Date)
```

Existing tests don't assert the absence of `timestamp`, so they pass
unchanged. The field is consumed only by the day-header logic in the
template.

## CSS

`.day-header` is full-width, centred, small dim text, with margins
above and below. Uses existing theme tokens:

```css
.day-header {
  text-align: center;
  font-size: 0.78em;
  color: var(--bc-text-dim);
  margin: var(--bc-gap-msg) 0;  /* match the inter-message gap rhythm */
  -webkit-user-select: none;
  letter-spacing: 0.02em;
}
```

Margins above and below use `--bc-gap-msg` so the header reads as
"breathing room" between the messages rather than as part of either
side. This composes correctly with the spacing system Adam signed off
in `7a165db`.

## Tests (must-have per Kieran's brainstorm)

In `TranscriptSeamTests.swift`:

1. `testDayHeaderInsertedOnSetTopicAcrossBoundary` — setTopic with
   two messages on different dates; assert exactly one `.day-header`
   between them, labelled with the second message's date, and the
   label matches the label rule for that date relative to "now".

2. `testDayHeaderInsertedOnUpsertMessagesAcrossBoundary` — setTopic
   with one date, then upsertMessages with a message on a different
   date; assert header inserted before the upserted message.

3. `testDayHeaderCorrectnessWhenPrependEarlierSpansBoundary` —
   setTopic with messages on date B, then prependEarlier with messages
   on dates A and B; assert:
   - One `.day-header` between the A and B prepended messages (labelled B).
   - One `.day-header` between the last prepended (B) and the first
     existing (B) — wait, that's the same date, so NO header.
   - Actually: assert the boundary case correctly. Construct so the
     prepended block ends on date A and the first existing message is
     on date B; assert one `.day-header` between them labelled B.

   The exact test shape will be: setTopic on date B + 1 message,
   prependEarlier with [date A msg1, date A msg2] (so the prepended
   block ends on date A and existing starts on date B). Assert:
   - One `.day-header` for date A at the top (before the first
     prepended message).
   - One `.day-header` for date B between the last prepended message
     and the first existing message.
   - Total: 2 headers, in correct positions.

The `testEverySeamStatementIsExecutable` E10 backstop is unchanged —
no new bridge calls are emitted by header logic, so the `covered` set
stays the same and the backstop continues to hold.

## Test fixture change

`message(id:role:content:)` helper in `TranscriptSeamTests.swift` gains
a `timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)`
parameter so day-boundary tests can construct messages at specific
times.

## What this spec does NOT do

- No timezone picker. Local time only. (Future: WP-3 maybe.)
- No relative-time formatting for recent messages ("2 min ago"). That's
  the wildcard from the brainstorm; defer.
- No animation / fade-in for headers. Static DOM only.
- No header on the first message of the conversation (iMessage
  convention).
- No header between the load-earlier button and the first prepended
  message. The button itself is the separator.

## Out-of-scope follow-ups (Adam's deferred items)

- Strip `webView.isInspectable = true` (Sources/App/UI/Transcript/
  WebTranscriptView.swift:83). Diagnostic only — enable during dev, off
  for release. Final step after this uplift lands.

## Risk summary

- **Sanitizer:** no change. Headers are plain DOM elements built in JS,
  not parsed HTML. Zero sanitizer surface.
- **Bridge contract:** additive only (new `timestamp` field). Existing
  payload consumers ignore unknown fields. Existing seam tests hold.
- **CSS:** pure addition. New selector `.day-header`. No interaction
  with bubble / time / sender / badge styles.
- **Streaming indicator:** untouched (lives at the bottom, doesn't
  affect headers).
- **T1–T4 scroll invariants:** must re-verify. T3 (prependEarlier
  scroll anchor) is the load-bearing one — header insertion must not
  break the scrollHeight before/after arithmetic. The new seam test
  `testDayHeaderCorrectnessWhenPrependEarlierSpansBoundary` exercises
  this end-to-end via the live WKWebView.

## Effort estimate

- Spec: ~30 min (this doc).
- Bridge payload change: ~5 min (one line in `TranscriptPayloadBuilder`).
- Template JS: ~80 LOC (3 helpers + insertion in 3 functions).
- Template CSS: ~10 LOC.
- Seam tests: ~150 LOC (3 tests + fixture extension).
- Total: S-M. Mostly the JS seam test debugging (WebKit timing).