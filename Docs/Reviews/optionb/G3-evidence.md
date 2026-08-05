# G3 — Selection feasibility (paste-verified, FR-MULTICOPY A5) — evidence

**Date:** 2026-08-05T16:16:22.135Z
**Build:** TranscriptSpike WP-0 2026-08-05 (post-Fable C-5 correction)
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Adam (pending)

## Pre-registered criteria (verbatim, timestamped by the spike at run start)

```
G3 criterion fixture=golden_table_and_code (5 bubbles)
G3 criterion drag_select_from=bubble1_top to=bubble5_bottom (programmatic Range as closest headless proxy)
G3 criterion paste_target=NSPasteboard_readback via public.utf8-plain-text (FR-MULTICOPY A5 — paste-verified)
G3 criterion paste_consumer=TextEdit via Cmd+V — confirms pasteboard flavour matches what TextEdit receives
G3 criterion content_in_order_match — every non-empty line of expected appears in actual in order (FR-MULTICOPY A1 semantics)
G3 criterion verdict_logic_evaluates_each_criterion_above_explicitly (E8 compliance)
```

## Verdict-logic evaluation (E8 — every pre-registered criterion explicitly evaluated)

| # | Criterion | OK | Detail |
|---|---|---|---|
| 1 | fixture=golden_table_and_code (5 bubbles) | ✅ | 5 bubbles rendered; hasTable=true; hasCode=true (logged at fixture_loaded_check) |
| 2 | drag_select_from=bubble1_top to=bubble5_bottom (programmatic Range) | ✅ | Range.setStartBefore(root.firstElementChild) / Range.setEndAfter(root.lastElementChild); pasteboard received text (194 bytes) |
| 3 | paste_target=NSPasteboard_readback via public.utf8-plain-text | ✅ | NSPasteboard.general.string(forType: .string)=194 bytes; rtf=6205; html=5671 |
| 4 | paste_consumer=TextEdit via Cmd+V | ✅ | TextEdit pasteboard read: 194 bytes (consumer-side verification of pasteboard flavour) |
| 5 | content_in_order_match (pasteboard) | ✅ | contentMatch() over NSPasteboard plain-text: true |
| 6 | content_in_order_match (TextEdit consumer) | ✅ | contentMatch() over TextEdit pasteback: true |
| 7 | verdict_logic_evaluates_each_criterion_above_explicitly (E8) | ✅ | all 6 pre-registered criteria evaluated; none silently skipped |

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

## Pasteboard-side plain-text (normalised)

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

## TextEdit consumer-side plain-text (normalised)

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

## Verdict

**PASS** (FR-MULTICOPY A5 = ✅ paste-verified)

This is the prototype proof that **FR-MULTICOPY A5** works in the .web engine: the pasteboard round-trip (WebKit writes on Cmd+C, NSPasteboard carries `public.utf8-plain-text`, TextEdit receives on Cmd+V) preserves content in order. A1–A4 remain at P6.

## What changed vs the original G3 (Fable 3.3)

- **Real Cmd+C dispatch** via NSEvent.keyDown with `.command` modifier and `kVK_ANSI_C` (keyCode 8). WKWebView's editor commands handler routes this to its copy handler which writes RTF + HTML + `public.utf8-plain-text` flavours to NSPasteboard.
- **NSPasteboard readback** of `public.utf8-plain-text` (the flavour every text consumer reads first). The original G3 only read `window.getSelection().toString()` — a different code path that does NOT exercise WebKit's pasteboard serialisation (table→tab conversion, `<pre>` indentation, inter-block newlines).
- **TextEdit consumer check**: the pasteboard plain-text is also dropped into a fresh TextEdit document via Cmd+V, then read back to confirm the same content. This is the round-trip the spec asks for.
- **Verdict-logic audit (E8).** Every pre-registered criterion appears in `verdictLog` and is evaluated; none are silently skipped.
- **Raw artefacts committed**: `G3-pasteboard-plain-*.txt` (NSPasteboard readback) and `G3-textedit-consumer-*.txt` (TextEdit readback) for durable inspection.

## Prior attempts

v1 oracle (byte-exact match): assumed WebKit collapses inter-block whitespace to a single newline. Smoke-tested wrong — WebKit's `Selection.toString()` emits blank lines at *some* block-level boundaries but not others (depends on element types: text/paragraph bubbles vs. table vs. pre). NSPasteboard copy is non-uniform across mixed content.

v2 oracle (content-in-order): the pass criterion is **content preservation in order** — every non-empty line of the golden fixture appears in the actual selection text in the same relative order, with tabs preserved for tables and indentation preserved for code. This is what FR-MULTICOPY A1 actually requires from the user's perspective; boundary blank lines are cosmetic and intentionally not binary-gated. Deviation 1 in the Fable super-check stands.

v3 (this run, post-Fable): the oracle is preserved (content-in-order) but the **measurement** is changed from `Selection.toString()` to NSPasteboard readback + TextEdit consumer check. This is what FR-MULTICOPY A5 actually requires — "paste-verified" means the user can paste into another app and get the same content.
