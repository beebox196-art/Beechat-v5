# WP-2I White-Screen Diagnosis — CRITICAL

**Investigator:** Q (subagent) · **Date:** 2026-08-06 17:45 BST (diagnosis) · 18:30 BST (logging fix + reinstall)
**Status:** Logging instrumentation shipped. **JS exception capture BLOCKED — Adam interaction required (see §0.5).**
**Scope:** BeeChat white-screen regression on `.web` transcript engine after WP-2I merge.

---

## 0.5 Update 2026-08-06 18:30 BST — Logging fix shipped, reinstalled, exception capture blocked

**TL;DR:** One-line `privacy: .public` logging patch applied to `WebTranscriptView.swift:256`, binary rebuilt and reinstalled at `/Applications/BeeChatApp.app`. Feature flag preserved (`transcriptEngine = web`, `htmlRendering = 1`). All 308 BeeChatAppTests pass. **The new binary contains the un-redacted logger** (verified via `strings`). The JS exception message itself could NOT be captured from this session — see §0.5.4 below.

### §0.5.1 Logging fix applied

**File:** `Sources/App/UI/Transcript/WebTranscriptView.swift` · **line 256** (was line 270 in the original file).

```diff
         private func evaluate(_ webView: WKWebView, _ js: String) {
             webView.evaluateJavaScript(js) { result, error in
                 if let error = error {
-                    TranscriptHost.logger.error("JS eval error: \(error.localizedDescription) for: \(js.prefix(120))")
+                    TranscriptHost.logger.error("JS eval error: \(error.localizedDescription, privacy: .public) for: \(js.prefix(120), privacy: .public)")
                 }
             }
         }
```

Both `error.localizedDescription` and `js.prefix(120)` are now logged with `privacy: .public`. The os_log format string in the rebuilt binary is `JS eval error: %{public}s for: %{public}s` (verified via `strings /Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp`).

### §0.5.2 Build + test results

| Step | Result |
|---|---|
| `swift test --filter BeeChatAppTests` | **308 tests, 0 failures, 0 unexpected** · EXIT=0 · 1.78s |
| `swift build` | Build complete (incremental, 0.22s) |
| `scripts/build-and-install.sh` | ✅ Installed. Version 0.9.5f, Build 2026.07.13, binary 22M, path /Applications/BeeChatApp.app |
| Binary mtime | Aug 6 18:20 BST (was 17:22) |
| Feature flags preserved | `BeeChat.feature.transcriptEngine = web` ✓ · `BeeChat.feature.htmlRendering = 1` ✓ |
| New logger in binary | `JS eval error: %{public}s for: %{public}s` (verified via `strings`) |

### §0.5.3 Bounded window contract — VERIFIED RESPECTED at data-path level

Adam's binding constraint was honoured: the bounded window IS active and the web engine receives only the bounded slice. Traced the full path:

| File:line | What it does |
|---|---|
| `Sources/App/UI/Observers/MessageListObserver.swift:14` | `messageLimit = 25` (private) |
| `MessageListObserver.swift:48` | `messages = Array(allMessages.suffix(messageLimit))` — capped at 25 |
| `MessageListObserver.swift:50` | `canLoadEarlier = allMessages.count > messageLimit` |
| `MessageListObserver.swift:54-57` | `loadEarlierMessages()` bumps limit by 25 |
| `MessageListObserver.swift:35-39` | `setAllMessages()` always calls `applyWindow()` — no path bypasses the cap |
| `Sources/App/UI/ViewModels/MessageViewModel.swift:27-29` | `var messages: [Message] { messageListObserver.messages }` — exposed slice is the bounded one |
| `Sources/App/UI/MainWindow.swift:245` | `messages: messageViewModel.messages` — passed into `TranscriptState` |
| `WebTranscriptView.Coordinator.applyStateIfReady` (line ~157) | `messagesToPayload(state.messages)` — only the bounded `state.messages` is encoded into `setTopic` |

**Conclusion: no code path leaks `allMessages` (which may be up to 500 from the local observation `ValueObservation`) into the web engine.** Q's earlier 128-message / 224KB estimate was incorrect: that figure represented the DB-side raw content size, not the payload sent to JS. The bounded window caps `setTopic` to ~25 messages — confirmed at the source-code level. **Payload size is NOT the root cause.**

### §0.5.4 JS exception capture — BLOCKED (Adam interaction required)

**Adam must run the app once and open any topic with messages.** The next `setTopic`/`setStreaming`/etc. JS eval call will throw; the now-public log line will reveal the exception body and the first ~120 chars of the failing JS call.

**Why I couldn't capture it from this session:**
- This is a headless sandboxed session (no display server, no Accessibility permission, no AppleEvent sending rights).
- Verified: `peekaboo permissions` reports Accessibility = "Not Granted" — `peekaboo see`/`click` time out; `osascript` returns `Connection is invalid (-609)`.
- App launches successfully (PID confirmed via `lsappinfo`) but does not progress to SwiftUI rendering / topic load / WebKit mount in this headless context — no `WebTranscriptView` category logs emitted after 7+ minutes.
- Prior session (PID 14462, 17:23) produced `JS eval error` events starting ~24s after launch — that delay was topic-list fetch from gateway + topic auto-selection (`MessageViewModel.updateTopics` defaults `selectedTopicId = topics.first?.id` on line 81). The same delay requires interactive UI in this session.

**To capture the exception, Adam needs to:**
1. Launch the freshly-installed `/Applications/BeeChatApp.app` (mtime Aug 6 18:20).
2. Open any topic (the first topic auto-loads; click in sidebar for any other).
3. Capture logs: `/usr/bin/log show --predicate 'process == "BeeChatApp" AND subsystem == "com.beebox.beechat" AND category == "WebTranscriptView"' --info --debug --last 2m`
4. The exception message + first 120 chars of the failing JS call will now appear in cleartext.

### §0.5.5 What the revealed exception will tell us

The exception body + 120-char JS prefix should pinpoint one of:

| Likely cause | Expected exception signature | Fix |
|---|---|---|
| Specific message content breaks template (e.g., HTML in attribute, malformed after sanitization) | `TypeError: Cannot read properties of null (reading '...')` at `TranscriptTemplate.html:XXX` | Identify the message + template line, fix template or sanitizer. |
| JSON encoding edge case in `JSONStringEncoder` (e.g., NSNumber from a Bool arriving as Int via objCType mismatch) | `SyntaxError: Unexpected token` at the JS parser | Fix encoder. (Validated with 5 unit cases — see Appendix E — encoder produces parseable JSON for empty, normal, special-char, 25-message, and emoji payloads. Less likely.) |
| `data:` URL inside `<img src>` reaches WebKit and trips CSP-equivalent | `Refused to load` or template-side `TypeError` | Already handled by `HTMLSanitizer.dataSchemeOnlyAllowedOnSrcNotOnHref`; confirm at runtime. |
| `loadHTMLString` baseURL:nil causes WKWebView to resolve URLs relative to `about:blank` in an unexpected way | Likely a `bcImage`/`bcLink` bridge call firing before listeners attach | Out of scope for now — only happens on click. |
| Something else entirely | Unknown | Escalate to Kieran / Bee. |

### §0.5.6 Risk

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Privacy-public logging reveals user message content in OSLog (JS eval calls contain sanitized HTML of messages) | LOW | LOW | The HTML is locally-generated, not user-private beyond what Adam types. Acceptable for a diagnostic build. Strip in the production build before B2I sign-off — line 256 reverted to original before merge to `main`. |
| Bounded window contract still breaks at runtime even though the source code respects it | LOW | MEDIUM | Tested statically only. Add a runtime guard: assert in DEBUG that `state.messages.count <= 25` after `applyWindow`. Not done in this iteration (scope was logging fix only). |
| The revealed exception reveals the bug is NOT in the web engine — it's elsewhere | MEDIUM | LOW | The fix path is unaffected — once we know the exception, we know where to look. |
| Adam has already moved on to other work and won't repro | LOW | MEDIUM | This document is the hand-off — Adam (or whoever picks up) can repro from §0.5.4 in <2 min. |

---

## 0. TL;DR (original — preserved for context)

---

## 0. TL;DR

**The parent's working hypothesis (H1 — "rebuild with `ca122a3`") is REJECTED by binary forensics.**
The binary Adam is running already contains the `ca122a3` fix (verified by `otool -tV` disassembly of `TranscriptPayloadBuilder.messagePayload` — it calls `HTMLSanitizer.sanitize` at `0x10025cfc8`).

The actual root cause is a **live-WKWebView JS exception** that fires on every `window.bc.setTopic(...)` and `window.bc.upsertMessages(...)` call. The exception body is privacy-redacted in `os_log` (`<private>`), so the exact line in the JS template that throws cannot be determined from logs alone — but the **pattern** (every JS eval throws, `setTopic` payload with 128 messages at ~600KB-1MB JSON, sandboxed `loadHTMLString` doc, no crash reports) is consistent with **payload size + a content-specific JS failure** that needs a live debug session to localise.

**Recommended remediation path:**
1. **Stop here on diagnosis.** Do NOT rebuild + reinstall — the rebuilt binary will fail identically.
2. **Get the JS exception message.** Two options:
   - (preferred) Quick instrumentation patch: log the full `js.prefix(120)` and `error.localizedDescription` WITHOUT privacy redaction in `WebTranscriptView.swift` `evaluate(...)` (line ~270). One-line `Logger(subsystem:category:).error("\(js, privacy: .public) error=\(error, privacy: .public)")`.
   - (fallback) Run the `.web` engine headlessly via `xcuitest` with `console.log` injection so the template's exceptions print to stdout instead of `os_log`.
3. **After we know the JS exception**, the fix will be one of:
   - JSON payload too large for `evaluateJavaScript` → paginate `setTopic` (send messages in chunks, e.g. last 50 first, then prependEarlier for the rest).
   - Specific message content (e.g. truncation at `maxTextLength=200000` produces broken HTML that throws on parse) → reproduce with a fixture, fix the template.
   - Something else entirely → escalate.

**Risk:** LOW for diagnosis accuracy (evidence is solid); MEDIUM for "what's next" (depends on what the JS exception actually says).

---

## TASK

Diagnose the BeeChat white-screen regression in the `.web` transcript engine (`transcriptEngine = web`). Symptoms: no existing conversation bubbles/threads in any topic, and sending a message shows "B thinking" then flashes a response and goes to a WHITE screen.

Per Adam-mandated process: critical-tier (working-app regression). Must investigate carefully and fully; must NOT jump to a quick patch.

## CHANGED

- **2026-08-06 18:30 BST:** `Sources/App/UI/Transcript/WebTranscriptView.swift:256` — added `privacy: .public` to both `error.localizedDescription` and `js.prefix(120)` in the `evaluate(...)` logger. Single-line diff. (Logging fix per parent's approved remediation path.)
- **2026-08-06 17:45 BST (initial):** Nothing. Diagnosis-only, no code modified.

## VALIDATED

Evidence gathered from six independent sources. All checks pass:

| Source | What it confirmed |
|---|---|
| `/Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp` mtime | Aug 6 17:22:52 BST |
| Git commit timestamps | `ad5fa58` (initial WP-2I host): 14:21:54 BST; `ca122a3` (the fix): 17:23:07 BST |
| `WebTranscriptView.swift` source mtime | Aug 6 17:21:31 BST — **before** the build, **before** the commit |
| `git status --short` | Empty — working tree matches HEAD (`ec1e9be`) |
| `git diff ad5fa58 ca122a3 -- WebTranscriptView.swift` | Fix added `TranscriptPayloadBuilder` with `HTMLSanitizer.sanitize(MarkdownToHTML.convert(content))` pipeline |
| `otool -tV` on binary | `messagePayload` at `0x10025cdc4` calls `HTMLSanitizer.sanitize` at `0x10025cfc8` — **fix IS in binary** |
| `defaults read com.beebox.beechat` | `BeeChat.feature.transcriptEngine = web`, `BeeChat.feature.htmlRendering = 1` |
| `~/Library/Application Support/BeeChat/BeeChat.sqlite` | 17 topics, 25,328 messages, 1,820 sessions. Adam's most recent topic has 128 messages totaling 224KB raw content. |
| `os_log` (BeeChatApp PID 14462) | Multiple `JS eval error: A JavaScript exception occurred for: <private>` errors after app launch at 17:23:01 BST |
| `swift test --filter TranscriptHostPayloadTests` | 6/6 pass — sanitizer pipeline works correctly in isolation |
| `embed-template.swift --check TranscriptTemplate` | OK — embedded constant is in sync with source |

## RESULT

### Timeline reconstruction (verified)

| Time | Event |
|---|---|
| 14:12:55 | Merge WP-1 (`12c5360`) — TranscriptBoundary, FeatureFlags.transcriptEngine |
| 14:12:59 | Merge WP-2 (`1c9524e`) — TranscriptTemplate.html, TranscriptTemplate.swift |
| 14:21:54 | Q commit `ad5fa58` — Swift host (`WebTranscriptView.swift`) + data: sanitizer fix |
| 17:12:11 | Adam first launches the binary (PID 12679) — flag flipped to `web`, blank-transcript regression visible |
| 17:12:18 | First `TranscriptTemplate: No resource bundle or flat file found` warning (embedded fallback used) |
| 17:12:35+ | First `JS eval error: A JavaScript exception occurred` — **same pattern in current PID** |
| 17:21:31 | Source file `WebTranscriptView.swift` modified locally (the fix being prepared) |
| 17:22:52 | Binary built (`Aug 6 17:22:52 2026`) — built from source that already had `TranscriptPayloadBuilder` with sanitize |
| 17:23:01 | Adam relaunches binary (PID 14462, current process) |
| 17:23:07 | Q commit `ca122a3` — `TranscriptPayloadBuilder` formalised with markdown→sanitize pipeline + 6 regression tests |
| 17:23:25+ | Same `JS eval error` pattern continues — **fix is in binary, JS still throws** |

The parent's working assumption ("binary built before fix, therefore fix is missing") was based on commit-vs-binary timestamps alone. The source file mtime (17:21:31) is the missing piece: Q modified the file 88 seconds before the build, so the build captured the fix's code even though the commit happened 15 seconds after the build finished.

### Hypotheses tested

| # | Hypothesis | Evidence for | Evidence against | Verdict |
|---|---|---|---|---|
| H1 | Running binary predates `ca122a3` fix → blank-transcript is the KNOWN bug | Binary mtime (17:22:52) < commit mtime (17:23:07) | Source mtime (17:21:31) < binary mtime (17:22:52). `otool -tV` shows `messagePayload` calls `HTMLSanitizer.sanitize` at `0x10025cfc8`. The fix IS in the binary. | **REJECTED** — the fix is compiled in. A rebuild would produce an identical binary. |
| H2 | `.web` engine fails to render existing messages on topic load (`setTopic` payload empty or malformed) | `os_log` shows `JS eval error: A JavaScript exception occurred` on every call. Swift encodes messages correctly per unit tests. | `TranscriptHostPayloadTests` confirms payload structure. The `applyStateIfReady` path correctly puts messages into the `setTopic` payload. | **PARTIALLY CONFIRMED** — rendering does fail (JS throws), but the payload itself is structurally correct. The throw is downstream. |
| H3 | `bcReady` never fires → `applyStateIfReady` never runs → blank transcript | `applyStateIfReady` has `guard templateReady, let state = pendingState else { return }` — if `bcReady` never fires, no state is applied. | The `bridge('bcReady', true)` call at line 880 of the template fires immediately on `<script>` execution. The `WKUserContentController.add(proxy, name: "bcReady")` is wired in `makeNSView`. There is no evidence the handler is unregistered. | **REJECTED** — `bcReady` almost certainly fires (otherwise the JS eval errors wouldn't happen — they happen on `setTopic` calls AFTER `bcReady`). |
| H4 | A crash or exception in the WKWebView path on message send | `os_log` shows `JS eval error` on `setStreaming`, `upsertMessages`, `setThinking`, `setTheme`, `setFontScale` calls — every JS eval throws. No crash reports in `~/Library/Logs/DiagnosticReports/`. | No `BeeChatApp` entries in crash reports. The app stays alive (PID 14462 still active at 17:45). | **PARTIALLY CONFIRMED** — every `evaluateJavaScript` call returns an error. The WKWebView is alive but unresponsive (every eval fails). The "white screen on send" is exactly what this produces: state changes, JS eval fails, no DOM mutation, screen stays white. |

### Root cause (with file:line evidence)

**Primary root cause: Every `webView.evaluateJavaScript(...)` call from `WebTranscriptView.Coordinator` throws a JS exception, leaving the WKWebView's DOM empty (just the initial `#transcript` element with no message children).**

Evidence:
- `WebTranscriptView.swift:268-273` — the `evaluate(...)` function:
  ```swift
  private func evaluate(_ webView: WKWebView, _ js: String) {
      webView.evaluateJavaScript(js) { result, error in
          if let error = error {
              TranscriptHost.logger.error("JS eval error: \(error.localizedDescription) for: \(js.prefix(120))")
          }
      }
  }
  ```
- `os_log` lines from PID 14462 (current session, 17:23:01 onwards):
  ```
  17:23:25.138339  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
  17:23:26.142744  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
  17:23:28.458058  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
  17:23:51.862658  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
  17:23:55.126166  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
  ```
- The error body `<private>` is `os_log` default privacy (`error.localizedDescription` interpolation is private). We cannot determine the exact JS exception from logs alone.

**Secondary finding: The JS exception body is privacy-redacted, so we cannot pinpoint which line in `TranscriptTemplate.html` throws without re-running the app with public-privacy logging.**

**Tertiary finding (DB health):** The DB is healthy and has all the data. 17 topics, 25,328 messages, including Adam's recent session `agent:main:telegram:group:-1003830552971:topic:1` with 128 messages totalling 224KB raw content. The largest single message in this session is 13.3KB raw, which after markdown→HTML conversion + JSON wrapping could be 25-50KB per message × 128 messages = **3-6MB of JSON for a single `setTopic` call**. This is at the upper limit of what `evaluateJavaScript` can handle synchronously and is the most likely trigger for the exception.

**The "white screen" symptom exactly matches:** The template's CSS has `--bc-bg: #FFFFFF` (light mode). The initial DOM is just `<main id="transcript">` with a `#load-earlier` button (hidden) and a `#thinking` div (hidden). When `setTopic` throws, no messages get inserted. The empty `#transcript` shows the white background → "white screen". On send, the same exception happens, screen stays white.

### What is NOT the bug

- **The DB is fine.** 17 topics, 25K messages, all reachable.
- **The sanitize fix is fine.** `TranscriptHostPayloadTests` all pass; the binary contains the sanitize call.
- **The `TranscriptTemplate.html` template is in sync.** `embed-template.swift --check` passes.
- **The bridge handlers are wired.** `bcReady`/`bcLink`/`bcImage`/`bcLoadEarlier`/`bcCopyMessage` registered in `makeNSView` (`WebTranscriptView.swift:62-66`). No `.fault` tripwire replicated from `MessageWebView.swift:157` (per WP-2I spec §3.1 inverse invariant).
- **The flag is correctly set to `web`.** `defaults read` confirms.
- **No crash.** No entries in `~/Library/Logs/DiagnosticReports/`. PID 14462 is alive.
- **The `data:` sanitizer fix from `ad5fa58` is in.** `HTMLSanitizer.swift` has the per-attribute scheme lists per spec §3.2.

### What needs to happen before Adam can test again

1. **Add privacy-public logging to `WebTranscriptView.swift:268-273`** to capture the JS exception body. One-line change:
   ```swift
   private func evaluate(_ webView: WKWebView, _ js: String) {
       webView.evaluateJavaScript(js) { result, error in
           if let error = error {
               TranscriptHost.logger.error("JS eval error: \(error.localizedDescription, privacy: .public) for: \(js.prefix(120), privacy: .public)")
           }
       }
   }
   ```
   Then rebuild + reinstall. Adam re-flips flag to `web` and reproduces. The OSLog will then show the actual JS exception message and the first ~120 chars of the failing JS call, pinpointing the failure.

2. **Based on the revealed exception**, the fix will be one of:
   - **(most likely) Payload too large.** The `setTopic` call with 128 messages at ~600KB-1MB JSON is at the edge of `evaluateJavaScript`'s practical limit. Fix: paginate `setTopic` — send the latest N messages first (e.g. last 50), then `prependEarlier` for older messages. The template already has a `prependEarlier` method (`TranscriptTemplate.html:768`).
   - **(possible) Sanitizer truncation produces malformed HTML.** When a message exceeds `maxTextLength=200000`, `HTMLSanitizer.sanitize` truncates the output. If the truncation point is mid-tag (e.g. mid-`<a href=`), the resulting HTML throws a parser exception when assigned to `innerHTML`. Fix: sanitize-aware truncation that snaps to the nearest tag boundary.
   - **(possible) Some other content-specific trigger.** Once we see the exception, the fix will be obvious.

3. **After the fix is identified and applied**: rebuild, reinstall, Adam smoke-tests the `.web` engine.

## RISK

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Diagnosis is wrong — actual cause is something else | LOW | MEDIUM | The privacy-public logging patch will reveal the actual JS exception, which will either confirm or refute this diagnosis. Cost of the patch is one line + one rebuild. |
| Privacy-public logging reveals user content in OSLog (the JS eval calls contain message HTML) | LOW | LOW | The HTML is already locally-generated and not user-private beyond what Adam types into the chat. Acceptable for a diagnostic build. Strip in the production build before B2I sign-off. |
| Rebuild + reinstall takes longer than expected | LOW | LOW | Build is incremental (~5 min based on `.build/build.db` mtime 17:22 and prior build duration). |
| The real fix requires a template change (not just Swift) | MEDIUM | LOW | The template (`TranscriptTemplate.html`) and the embedded constant (`TranscriptTemplate.swift`) are in sync. A template change means regenerating the embedded constant via `embed-template.swift TranscriptTemplate` (verified in sync). |
| Recurrence after fix — the `.web` engine has more issues at scale | MEDIUM | HIGH | The WP-2I spec is explicit that this is a "minimal slice" for smoke testing. WP-3 (process-death polish, context-menu filtering, content-prep memoization, parity matrix P1–P16) is the hardening gate. If we hit more issues during smoke testing, escalate to Bee/Kieran — do NOT silently absorb scope into WP-2I. |

---

## Appendix A: Source files inspected

- `Docs/Specs/Active/WP-2-integration.md` (full read)
- `Sources/App/UI/Transcript/WebTranscriptView.swift` (full read)
- `Sources/App/UI/Transcript/TranscriptBoundary.swift` (full read)
- `Sources/App/UI/MainWindow.swift:232-265` (transcriptView wiring)
- `Sources/App/Utils/FeatureFlags.swift` (full read)
- `Sources/App/Resources/TranscriptTemplate.html:380-880` (CSS, body, buildMessage, setTopic, upsertMessages, attachCopyButton, attachMessageCopyButton, bcReady)
- `Sources/BeeChatPersistence/Models/Message.swift` (Message struct)
- `Sources/App/Rendering/TranscriptTemplate.swift` (embedded constant check)
- `Tests/BeeChatAppTests/TranscriptHostPayloadTests.swift` (regression tests)
- `git log --oneline -20`, `git diff ad5fa58 ca122a3`, `git status`

## Appendix B: Binary forensics

```
$ otool -tV /Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp | \
    sed -n '/^_$s10BeeChatApp24TranscriptPayloadBuilderO07messageE0/,/^$/p' | head -120

000000010025cdc4	stp	x20, x19, [sp, #-0x20]!
000000010025cdc8	stp	x29, x30, [sp, #0x10]
...
000000010025cfc8	bl	_$s10BeeChatApp13HTMLSanitizerO8sanitizeyS2SFZ   ← THE FIX IS HERE
000000010025cfcc	mov	x8, x0
...
```

The `bl` (branch-with-link) at `0x10025cfc8` calls `HTMLSanitizer.sanitize(String) -> String` directly from `TranscriptPayloadBuilder.messagePayload`. This is the exact line the fix introduced — the old `ad5fa58` code did `"html": msg.content ?? ""` (raw markdown). The binary is post-fix.

## Appendix C: Database health snapshot

```sql
sqlite> SELECT COUNT(*) FROM topics;       -- 17
sqlite> SELECT COUNT(*) FROM messages;     -- 25,328
sqlite> SELECT COUNT(*) FROM sessions;     -- 1,820
sqlite> SELECT COUNT(*) FROM messages WHERE sessionId = 'agent:main:telegram:group:-1003830552971:topic:1';
-- 128 messages, 224KB raw content total
sqlite> SELECT MAX(LENGTH(content)) FROM messages;
-- 94,786 bytes (largest single message)
```

## Appendix D: Live error pattern (from `os_log`)

```
PID 14462 (current session, started 17:23:01):
17:23:01.450  [com.beebox.beechat:TranscriptTemplate] No resource bundle or flat file found for TranscriptTemplate.html — using embedded fallback
17:23:25.138  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
17:23:26.142  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
17:23:28.458  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
17:23:51.862  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
17:23:55.126  [com.beebox.beechat:WebTranscriptView] JS eval error: A JavaScript exception occurred for: <private>
```

5+ errors in 30 seconds of activity. Every `evaluateJavaScript` call (setTopic, setStreaming, setThinking, setTheme, setFontScale, upsertMessages) throws. The exception body is privacy-redacted.

## Appendix E: JSONStringEncoder validation (added 18:30 BST)

Ran an out-of-tree Swift harness mirroring the `JSONStringEncoder` enum from `WebTranscriptView.swift`. Five test cases:

| # | Payload | Result |
|---|---|---|
| 1 | `{topicId, canLoadEarlier:false, messages:[]}` | `{"topicId":"abc-123","messages":[],"canLoadEarlier":false}` ✓ |
| 2 | Single message with simple HTML `<p>Hello <b>world</b></p>` | Valid JSON, parses ✓ |
| 3 | HTML with `"`/`\\`/unicode escapes `Quote: \"hello\" backslash: \\ unicode: \u00e9 \u4e2d\u6587` | Valid JSON, parses ✓ |
| 4 | 25 messages (matches `messageLimit`) — 3,492 chars total | Valid JSON via `JSONSerialization.jsonObject` ✓ |
| 5 | HTML with emoji `🐝 BeeChat — runs fine with emoji 🦾` | Valid JSON, parses, topicId extracted ✓ |

**Conclusion:** `JSONStringEncoder` is not the failure point. The JS exception, when revealed, will originate in the template, not in JSON serialization.

---

**Verdict for the parent:** Logging instrumentation shipped. Run the rebuilt `/Applications/BeeChatApp.app` (mtime Aug 6 18:20), open any topic, capture logs per §0.5.4 step 3. The revealed exception will pinpoint the exact template line and the failing input, enabling a targeted one-shot fix.
