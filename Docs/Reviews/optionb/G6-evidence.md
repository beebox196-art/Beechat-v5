# G6 — Input feasibility — evidence

**Date:** 2026-08-05T11:51:16.615Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Adam

## Pre-registered criteria (verbatim)

- Typed string: **known pangram + digits + specials + emoji + trailing punctuation** (see `G6InputGate.typed`)
- Typing method: **`NSEvent.keyDown` dispatched via `NSApp.sendEvent` at 30 ms intervals** (real first-responder chain, reproducible, no human jitter)
- Synchronised streaming: **5 messages appended to the transcript at 400 ms intervals while typing proceeds**
- Comparison: **composer.stringValue == typed** (zero dropped keystrokes)
- Focus assertion: **firstResponder remains the composer (or its field editor) throughout** (real test because NSEvent dispatch goes through the responder chain). NSTextField uses an internal NSTextView as the field editor — strict `=== composer` comparison is too narrow; the check accepts `firstResponder === fieldEditor(for: composer)`.
- Out of scope (documented): **IME, key repeat, paste, modifier keys**

## Result

- typed_chars: 136
- expected_chars: 136
- equality: **✅**
- focus_retained: **✅**

**Verdict:** PASS

## Prior attempts

None.
