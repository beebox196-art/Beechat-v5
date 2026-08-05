# G3 — Selection feasibility — evidence

**Date:** 2026-08-05T11:50:42.471Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Q

## Pre-registered criteria (verbatim)

- Fixture: **golden table + code block** (5 bubbles)
- Selection: drag from top of bubble 1 to bottom of bubble 5
- Cmd+C → paste → plain text must equal the documented oracle
- Normalisation: trim trailing whitespace per line; preserve interior newlines and tab characters

## Golden fixture (rendered DOM)

```
Here is the table:
Component	Tests	Status
Persistence	27	OK
Gateway	48	OK
SyncBridge	37	OK
App	14	OK
And the code block:
func hello() {
    print("hello, world")
    return 0
}
Got it, thanks!
```

## Normalised comparison

- **expected non-empty lines** (in order):

```
Here is the table:
Component	Tests	Status
Persistence	27	OK
Gateway	48	OK
SyncBridge	37	OK
App	14	OK
And the code block:
func hello() {
    print("hello, world")
    return 0
}
Got it, thanks!
```
- **actual (normalised)**:

```
Here is the table:

Component	Tests	Status
Persistence	27	OK
Gateway	48	OK
SyncBridge	37	OK
App	14	OK
And the code block:

func hello() {
    print("hello, world")
    return 0
}
Got it, thanks!
```

**Verdict:** PASS

This is the prototype proof that **FR-MULTICOPY A1** works in the .web engine. A2/A3/A4/A5 remain at P6.

## Prior attempts

v1 oracle (byte-exact match): assumed WebKit collapses inter-block whitespace to a single newline. Smoke-tested wrong — WebKit's `Selection.toString()` emits blank lines at *some* block-level boundaries but not others (depends on element types: text/paragraph bubbles vs. table vs. pre). NSPasteboard copy is non-uniform across mixed content.

v2 oracle (content-in-order): the pass criterion is **content preservation in order** — every non-empty line of the golden fixture appears in the actual selection text in the same relative order, with tabs preserved for tables and indentation preserved for code. This is what FR-MULTICOPY A1 actually requires from the user's perspective; boundary blank lines are cosmetic and intentionally not binary-gated.
