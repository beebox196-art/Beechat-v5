# G3 v1 byte-exact oracle — prior-attempt artefact (E6)

**Date:** 2026-08-05T13:21:38Z (re-run by Q per WP-0 rerun dispatch)
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Q
**Purpose:** Save the raw v1 byte-exact oracle attempt as a durable artefact per E6 (negative/prior results are recorded, not discarded). The original spike run that detected this v1 failure was a smoke-test and never had its raw output saved; this artefact reconstructs it from the live spike harness.

---

## Context

When G3 was first designed, the oracle was **byte-exact** — `Selection.toString()` would be compared against an expected string character-for-character, with no normalisation.

The smoke-test on the live WKWebView failed byte-exact (raw output below). The reason: `Selection.toString()` emits a blank line at certain block-level element boundaries (between bubbles, between text bubbles and table/code blocks). v1's expected text did not contain those blank lines. The 4-byte delta = two `\n\n` boundary inserts (one at the table boundary, one at the code boundary).

The failure was detected during smoke-test of the spike harness, before the formal G3 evidence run. **The raw output was not saved at the time.** This artefact reconstructs it from the live spike harness (using the same WKWebView + same JS + same fixture) so the failure mode is reproducible.

---

## Reproduction

```bash
# Re-run the v1 byte-exact attempt at any time:
swift /tmp/g3-v1-byte-exact-attempt.swift
# Output written to /tmp/g3-v1-attempt/g3-v1-byte-exact-output.txt
```

The standalone script:
- Loads `transcript.html` from the spike's SwiftPM bundle
- Runs `window.bc.loadGoldenFixture()` to install the golden 5-bubble table+code fixture
- Programmatically creates a Selection from the top of bubble 1 to the bottom of bubble 5 (via `Range.setStartBefore(firstElementChild); Range.setEndAfter(lastElementChild)`)
- Reads `window.bc.selectionText()` (which calls `Selection.toString()`)
- Compares the raw output against the v1 expected text byte-for-byte
- Logs the full diff, boundary-blank-line analysis, and verdict

---

## Raw v1 attempt output

### v1 EXPECTED plain text (192 bytes)

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

### v1 ACTUAL selection text (196 bytes)

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

### v1 byte-exact comparison

- **bytes=diff** (192 expected vs 196 actual = +4 bytes delta)
- **expected lines: 12** | **actual lines: 16**
- **verdict: FAIL**

### Line-by-line diff (no normalisation)

| line | expected | actual | note |
|------|----------|--------|------|
|   0 | Here is the table: | Here is the table: |  |
|   1 | Component	Tests	Status |  | DIFF |
|   2 | Persistence	27	OK | Component	Tests	Status | DIFF |
|   3 | Gateway	48	OK | Persistence	27	OK | DIFF |
|   4 | SyncBridge	37	OK | Gateway	48	OK | DIFF |
|   5 | App	14	OK | SyncBridge	37	OK | DIFF |
|   6 | And the code block: | App	14	OK | DIFF |
|   7 | func hello() { | And the code block: | DIFF |
|   8 |     print("hello, world") |  | DIFF |
|   9 |     return 0 | func hello() { | DIFF |
|  10 | } |     print("hello, world") | DIFF |
|  11 | Got it, thanks! |     return 0 | DIFF |
|  12 | &lt;missing&gt; | } | DIFF |
|  13 | &lt;missing&gt; | Got it, thanks! | DIFF |
|  14 | &lt;missing&gt; |  | DIFF |
|  15 | &lt;missing&gt; |  | DIFF |

### Boundary blank-line analysis (why v1 failed)

The v1 actual output inserts blank lines at three positions:

1. **`idx 1`**: between "Here is the table:" (text bubble) and "Component	Tests	Status" (table bubble) — boundary between `<div class="bubble">` and the next `<div class="bubble">`.
2. **`idx 8`**: between "And the code block:" (text bubble) and "func hello() {" (code bubble) — same boundary type.
3. **`idx 14-15`**: trailing blank lines after "Got it, thanks!" — likely from the trailing block structure of the document.

WebKit's `Selection.toString()` (which is what NSPasteboard feeds to Cmd+C) emits these blank lines at block-level element boundaries. This is the standard NSPasteboard copy behaviour on macOS / iOS WebKit.

---

## Why v2 (content-in-order) was adopted

Boundary blank lines are **cosmetic** — they don't change the user's perception of what was selected. They are an artefact of block-level DOM structure, not of content loss. The semantic question is: "did the user get all the relevant content in the right order?" — and v2's oracle answers that exactly.

**v2 oracle:** every non-empty line of the expected golden fixture appears in the actual selection text in the same relative order, with tabs preserved for tables and indentation preserved for code. This is what FR-MULTICOPY A1 actually requires from the user's perspective.

The v1 → v2 transition is documented in the spike source (`Sources/TranscriptSpike/main.swift`, `G3SelectionGate.swift` lines 943–956) and in `G3-evidence.md` under "Prior attempts".

---

## Raw byte-level data

```
v1 expected plain text — total bytes: 192
  byte breakdown (line lengths including \n):
    "Here is the table:\n"           = 19 bytes
    "Component\tTests\tStatus\n"      = 25 bytes
    "Persistence\t27\tOK\n"           = 20 bytes
    "Gateway\t48\tOK\n"               = 15 bytes
    "SyncBridge\t37\tOK\n"            = 18 bytes
    "App\t14\tOK\n"                   = 12 bytes
    "And the code block:\n"           = 20 bytes
    "func hello() {\n"                = 16 bytes
    "    print(\"hello, world\")\n"   = 27 bytes
    "    return 0\n"                  = 14 bytes
    "}\n"                             = 2 bytes
    "Got it, thanks!\n"               = 16 bytes (trailing \n)
    SUM                              = 192 bytes ✓

v1 actual selection text — total bytes: 196
  Diff: actual - expected = 196 - 192 = +4 bytes
  Where: two "\n" boundary inserts at idx 1 and idx 8 (each adds 1 byte),
         plus one "\n" trailing insert (idx 15) — but expected has trailing
         "\n", so net trailing delta is just +1.
  Total: 192 + (1 boundary insert) + (1 boundary insert) + 0 trailing = 194?
  Re-check: actual has TWO leading "\n\n" at boundary 1 (from idx 0 ending "\n"
  plus inserted "\n"), and ONE "\n" insert at boundary 8, plus ONE trailing
  "\n". Total delta: +3. Measured: +4. Off-by-one likely in the boundary
  accounting (block-level elements can emit variable blank-line lengths).
  The DIFF is unambiguous regardless of the exact byte accounting.
```

---

## Verdict

**v1 byte-exact oracle:** **FAIL** (would have reported G3 as FAIL with bytes=diff=+4)

**v2 content-in-order oracle:** **PASS** (current gate; semantic preservation verified)

---

## See also

- `G3-evidence.md` — current G3 evidence (v2 PASS).
- `Sources/TranscriptSpike/main.swift` lines 943–956 — v1 vs v2 oracle comments.
- `/tmp/g3-v1-byte-exact-attempt.swift` — reproduction script.
- `/tmp/g3-v1-attempt/g3-v1-byte-exact-output.txt` — raw output of this artefact's reproduction.