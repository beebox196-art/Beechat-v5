# WP-2I — Live-Failure RCA, Fix, and Validation Handoff

**Author:** Fable (gate reviewer) · **Date:** 2026-08-06 22:20 BST
**Branch:** `feat/transcript-integration` · **Base HEAD:** `1cfe96d`
**Status:** **FIXED AND INSTALLED — awaiting team validation.** Changes are in the working tree, **uncommitted**. Adam holds the commit decision.
**Trigger:** Adam's report — "no messages displayed in any topic, except while Bee is responding, then it disappears as it finishes."

---

## 0. TL;DR for the team

The `.web` transcript was broken by a **calling-convention mismatch at the host→document seam**, not by anything architectural.

`TranscriptTemplate.html:743` declares `upsertMessages(messages, canLoadEarlier)` — **positional**.
`WebTranscriptView.swift` emitted `window.bc.upsertMessages({messages, canLoadEarlier})` — **a single object**.

`for (const m of (messages || []))` over a non-iterable object throws `TypeError`. **Every upsert in the live app threw.** 27 of 27 JS eval errors in Adam's session were `upsertMessages`; zero were anything else.

Three things the team needs to internalise:

1. **The defect survived `1cfe96d`.** The "Fix 1b atomic settle" emits `setStreaming(null);upsertMessages({obj})` as one eval — statement 1 removes the streaming bubble, statement 2 throws. That *is* Adam's "response vanishes at the end" symptom, and the fix commit would not have removed it.
2. **321 tests were green.** Both suites are individually correct. Neither crosses the seam. Details in §3 — this is the actual root cause of the last several cycles, and it is a process defect, not a skill defect.
3. **Adam was testing a binary that predated the fixes.** Installed binary mtime `18:20:56`; commit `1cfe96d` at `21:28:04`. His 20:47–20:55 session ran the *pre-fix* build, so Fix 1a (blank-topic) has never actually been in front of him. Do not treat his report as evidence against `1cfe96d` — treat it as untested.

Fixes applied, built, installed, and regression-guarded. **Runtime smoke test is not done — that is Adam's step, §6.**

---

## 1. Evidence — how the root cause was established

Not by reading. By executing the host's actual output against the real template in a real `WKWebView`.

Probe: loads `Sources/App/Resources/TranscriptTemplate.html` into a live `WKWebView`, waits for `bcReady`, replays the exact strings `WebTranscriptView` emits. Source in Appendix A.

```
== bcReady fired ==
[setTopic(object)]                        OK -> Optional(1)
[count .msg after setTopic]               OK -> Optional(1)
[upsertMessages(object)   ← host's call]  THREW: A JavaScript exception occurred
[upsertMessages(array,bool) ← template]   OK -> Optional({appended = 1; total = 2})
[final .msg count]                        OK -> Optional(2)
```

Corroborating production log (the `privacy: .public` patch from the Q diagnosis doc did its job — that patch is what made this findable):

```
$ log show --predicate 'process == "BeeChatApp"' --info --debug --last 6h \
    | grep -oE "for: window\.bc\.[a-zA-Z]+" | sort | uniq -c
  27 for: window.bc.upsertMessages
```

**Zero `setTopic` failures.** `setTopic({topicId, messages, canLoadEarlier})` destructures an object, so the host's object form happens to match. That asymmetry is why only one of six bridge calls was broken — and why the failure looked mysterious rather than systematic.

### Full seam audit — all six bridge calls

| Template signature | Host emits | Verdict |
|---|---|---|
| `setTopic({topicId, messages, canLoadEarlier})` :713 | object | ✅ match |
| `upsertMessages(messages, canLoadEarlier)` :743 | **object** | ❌ **BROKEN — fixed** |
| `prependEarlier(messages)` :770 | *never called* | ⚠️ **latent bug — see §7** |
| `setStreaming(payload)` → reads `payload.html` :788 | `{"html": …}` | ✅ match |
| `setThinking(s)` string :816 | `"idle"` \| `"thinking"` \| `"streaming"` | ✅ match |
| `setTheme(tokens)` :823 / `setFontScale(scale)` :830 | object / number | ✅ match |

---

## 2. Why this maps exactly onto Adam's symptoms

| Symptom | Mechanism |
|---|---|
| Response renders while Bee is typing | `setStreaming` is one of the four correct calls. Works. |
| Vanishes the instant it completes | Atomic settle = `setStreaming(null);upsertMessages(…)` in **one** eval. Statement 1 removes the streaming node. Statement 2 throws. Nothing replaces it. A throw mid-script leaves the DOM stripped. |
| No messages in any topic (20:47 session) | That build was pre-`1cfe96d`, i.e. pre-Fix-1a: `setTopic` was still being called with the transient empty `messages` array, which clears the DOM. Compounded by every subsequent upsert throwing, so nothing could repopulate it. |

Note the second and third rows have **different causes**. `1cfe96d` fixed the third and not the second. Both are addressed now.

---

## 3. Why 321 green tests missed it — the real finding

This is the part worth the team's attention, because it explains the pattern of the last several cycles far better than "the problem is hard" does.

**`TranscriptJSBuilderTests`** (440 lines, added by `1cfe96d`) asserts the emitted *string*:

```swift
XCTAssertTrue(plan.statements[1].contains("window.bc.upsertMessages"))
```

It never inspects the argument shape and never executes the JS. The broken call passes every assertion in the file.

**`TranscriptFixtureTests` / `TranscriptTemplateTests`** *do* run real JS in a real `WKWebView` — but hand-write the call in the **correct positional form**:

- `TranscriptFixtureTests.swift:81, :187, :293`
- `TranscriptTemplateTests.swift:304, :509, :542, :562, :598`

Including `testHostAtomicSettleHasZeroIntermediateFlicker`, written specifically to prove Fix 1b works. It hand-writes `window.bc.setStreaming(null); window.bc.upsertMessages([{…}])`. It proves **the template** works. It says nothing about what the host sends, which is the only thing that was wrong.

**Two correct halves. An untested contract between them.** Every fix passed, every fix shipped, the app stayed broken. No amount of care on either side of the seam would have caught this; only a test that crosses it.

### Proposed evidence rule — E10 (seam execution)

> Every host→document call must have at least one test that takes **the string the host actually emits** and evaluates it against the real template, asserting no JS exception is raised. Assertions on the emitted string's *text* do not satisfy E10.

Requesting ratification alongside E8 (verdict-logic audit) and E9 (prior-art declaration). E10 is implemented in this change, not just proposed — see §4.3.

---

## 4. What changed

Three changes. All in the working tree, uncommitted.

### 4.1 `Sources/App/UI/Transcript/WebTranscriptView.swift` — the fix (2 call sites)

Fixed on the **host** side, not the template: the template matches route plan §4.3 and is depended on by 8 existing tests.

```diff
-            let upsertJSON = jsonString([
-                "messages": settledOnly,
-                "canLoadEarlier": next.canLoadEarlier,
-            ])
+            // SEAM: upsertMessages is POSITIONAL — (messages, canLoadEarlier).
+            // See TranscriptTemplate.html:743. Passing a single object makes the
+            // template's `for...of` iterate a non-iterable and throw.
             plan.statements.append("window.bc.setStreaming(null)")
-            plan.statements.append("window.bc.upsertMessages(\(upsertJSON))")
+            plan.statements.append(
+                "window.bc.upsertMessages(\(jsonString(settledOnly)),\(jsonString(next.canLoadEarlier)))"
+            )
```

```diff
-            let payload: [String: Any] = [
-                "messages": messagesPayload,
-                "canLoadEarlier": next.canLoadEarlier,
-            ]
-            plan.statements.append("window.bc.upsertMessages(\(jsonString(payload)))")
+            // SEAM: positional signature — see the note at the atomic-settle site
+            // above and TranscriptTemplate.html:743.
+            plan.statements.append(
+                "window.bc.upsertMessages(\(jsonString(messagesPayload)),\(jsonString(next.canLoadEarlier)))"
+            )
```

### 4.2 `WebTranscriptView.swift:83` — `webView.isInspectable = true`

The single highest-value line in this change, and arguably in the programme.

Its absence is why a live JS exception was chased with `otool -tV` disassembly and `strings` on the installed binary. With it, Safari ▸ Develop ▸ `<Mac name>` ▸ BeeChatApp opens Web Inspector on the live transcript: console, exceptions with line numbers, DOM tree, the `engineDebug` ring buffer, breakpoints in the scroll engine.

Deliberately unconditional (not `#if DEBUG`): BeeChat is a local single-user app and `scripts/build-and-install.sh` installs debug builds. **Kieran: flag it if you disagree** — gating it is a one-line change, but do so knowing it removes the only debugger the web engine has.

### 4.3 `Tests/BeeChatAppTests/TranscriptSeamTests.swift` — new, 6 tests (E10)

Takes `TranscriptJSBuilder.build(...).statements.joined(separator: ";")` — byte-identical to what `Coordinator.applyStateIfReady` evaluates — and runs it against the real template in a real `WKWebView`. Uses the **real** `TranscriptPayloadBuilder.messagePayload`, not a test-local imitation, so payload-shape drift also surfaces here.

| Test | Covers |
|---|---|
| `testSetTopicSeamExecutes` | first load / topic switch; asserts 2 `.msg` in DOM |
| `testUpsertMessagesSeamExecutes` | **the production defect**; asserts the appended node exists |
| `testAtomicSettleSeamExecutes` | streaming node present → settle → node gone AND settled message present (asserts count 2, "if this is 1, the response vanished") |
| `testSetThinkingSeamExecutes` | thinking transition |
| `testEverySeamStatementIsExecutable` | **backstop** — fails if `TranscriptJSBuilder` gains a `window.bc.*` call with no scenario here, and also if a covered call stops being emitted |
| `testLoadEarlierRoutesThroughUpsertNotPrependEarlier_KNOWN_GAP` | documents §7 so the gap is not mistaken for coverage; self-deletes by failing once the gap is fixed |

---

## 5. What is verified (reproduce these)

| Check | Command | Result |
|---|---|---|
| Root cause proven live | Appendix A probe | `upsertMessages(object)` THREW; `(array,bool)` OK |
| Build | `swift build` | Build complete |
| Full suite | `swift test` | **456 tests, 1 skipped, 0 failures** |
| Seam suite | `swift test --filter TranscriptSeamTests` | 6/6 pass, 0.61s |
| **Guard demonstrably fails when the bug returns** | reverted the normal-path line to the object form, re-ran | `SEAM BREAK — same-topic new message → upsertMessages / error: A JavaScript exception occurred` at `TranscriptSeamTests.swift:180`, plus count `1 != 2` at `:183`. Fix restored, suite green again. |
| Template drift | `swift scripts/embed-template.swift --check TranscriptTemplate` | exit 0 (template unmodified) |
| Installed | `./scripts/build-and-install.sh` | v0.9.5f, binary mtime **2026-08-06 22:20:14** |
| Flags preserved | `defaults read com.beebox.beechat` | `transcriptEngine = web`, `htmlRendering = 1` |

The revert-and-fail check is the E1 discipline applied to my own work: a guard nobody has watched fail is not a guard. Per Round 12b, this is now the second test in the programme demonstrated to fail when the thing it guards breaks.

---

## 6. What is NOT verified — Adam's validation steps

**Nothing has been run in the live app.** Everything above is build-time and harness evidence. The binary at `/Applications/BeeChatApp.app` (mtime 22:20:14) is the first build that has ever contained both `1cfe96d`'s fixes and the seam fix.

1. `open /Applications/BeeChatApp.app`
2. **P-1** Open a topic with history → messages render, scrolled to the bottom.
3. **P-2** Switch topics several times → each topic renders its own messages, no blank frame, no stale content from the previous topic.
4. **P-3** Send a message → "B thinking" → streaming text appears → **on completion the response stays put** (this is the headline fix).
5. **P-4** Scroll up mid-stream → the transcript must not yank you back to the bottom.
6. **P-5** Click "load earlier" → **expected to be wrong**, see §7. Note where the older messages land.
7. Capture the log either way:
   ```
   log show --predicate 'process == "BeeChatApp" AND subsystem == "com.beebox.beechat"' \
       --info --debug --last 10m | grep -i "JS eval error"
   ```
   **Expected: zero lines.** Any line here is a surviving seam break and the prefix now names the failing call in cleartext.
8. If anything looks wrong: Safari ▸ Develop ▸ `<Mac name>` ▸ BeeChatApp → Console. Exceptions now come with file and line numbers.

---

## 7. Known remaining defect at the same seam — load-earlier ordering

`prependEarlier` exists in the template (`TranscriptTemplate.html:770`) with the correct scroll-anchoring logic, and **the host never calls it**.

`onLoadEarlier` → `messageViewModel.loadEarlierMessages()` → limit +25 → `state.messages` grows **at the front** → `messagesChanged` → `upsertMessages(full window)` → the 25 new (older) messages are unmatched by `findMsgById`, so each is appended via `insertBefore(node, $thinking)` — **at the bottom, in the wrong order**, with no scroll-position compensation.

This was invisible until now because `upsertMessages` threw before it could get anything wrong. Expect it to surface the moment Adam clicks "load earlier" on the new build.

**Not fixed here** — it needs a host-side prepend path (diff old-vs-new head, emit `prependEarlier`) plus a seam scenario, which is WP-3 scope, not a WP-2I smoke-test fix. Documented by a failing-forward test rather than left silent. **Recommend WP-3 takes it as its first item.**

---

## 8. Required before merge to `main`

1. **Strip the diagnostic logging.** `WebTranscriptView.swift:~228` still carries `privacy: .public` on both the error and the JS prefix — it logs message HTML into OSLog. Q flagged this in the white-screen doc's own risk table. It earned its keep; it should not ship. *Recommendation: keep it on this branch until Adam's smoke test passes, then revert as the last commit before merge.*
2. **Kieran:** build-check + a call on §4.2 (`isInspectable` unconditional vs `#if DEBUG`).
3. **Commit the docs.** `WP2I-white-screen-diagnosis.md` and this file are both untracked. This is the **fourth** instance in the programme of review evidence stranded outside git (Rounds 6b, 8, 10, 10c). Two prior branch switches have already destroyed raw evidence. Recommend committing evidence docs at the moment they are written, independent of the code decision.
4. **Ratify E10** (§3) with E8 and E9.

---

## 9. Steal check (standing commitment, Round 10b)

Nothing to invent here — the fix *is* the standard practice we hadn't adopted:

- **`isInspectable`** is the platform's own answer to "why is my WKWebView misbehaving." Shipped by Apple in macOS 13.3, three years old, and the project had never set it. We were doing binary forensics because we had turned the debugger off.
- **Contract testing across a boundary** is the ordinary answer for any two-language bridge. The route plan defined the JS API in §4.3 as prose; prose does not fail a build. E10 is the minimum mechanical enforcement, and it costs 6 tests and 0.6 seconds.

No new ground. Both are things a web team would have had on day one, and their absence — not the architecture — is what produced weeks of "endless little tweaks."

---

## 10. Answer to Adam's strategic question

He asked, in effect: *have we got something fundamentally wrong that means we will never get on top of this?*

**No.** Option B is the right architecture and remains so — Round 10b established that BeeChat's original hybrid was the anomaly and the single-WebView transcript is the industry-standard pattern. Tonight's defect was one wrong argument shape in one of six functions, found in ten minutes once someone executed the host's output instead of reading it.

What *was* fundamentally wrong is narrower and fixable: **the project could not see its own running app.** No inspector, no seam test, an error-only log with the error redacted. Under those conditions any bug becomes a multi-day archaeology exercise, and the volume of careful work in this programme has been going into compensating for missing observability rather than into the actual problem. Both gaps are closed by this change.

---

## Appendix A — probe source

Committed to the tree at **`Experiments/SeamProbe/main.swift`** rather than left in a session scratchpad — Rounds 6b and 10 both lost raw evidence to branch switches, so this one lands in the repo immediately (untracked until Adam commits; see §8.3). Package.swift does not include `Experiments/`, so it does not affect the build.

```swift
// Loads the real TranscriptTemplate.html into a real WKWebView, waits for
// bcReady, then replays the exact strings WebTranscriptView emits.
func step1() {  // EXACTLY what the host emits for a topic switch
    let js = #"window.bc.setTopic({"topicId":"t1","messages":[{"id":"m1","role":"user","html":"<p>hello</p>","timeLabel":"10:00"}],"canLoadEarlier":false})"#
    run("setTopic(object)", js) { self.step2() }
}
func step3() {  // EXACTLY what the host emits for an upsert
    let js = #"window.bc.upsertMessages({"messages":[{"id":"m2","role":"assistant","html":"<p>reply</p>","timeLabel":"10:01"}],"canLoadEarlier":false})"#
    run("upsertMessages(object)  <-- host's actual call", js) { self.step4() }
}
func step4() {  // What the template signature actually wants
    let js = #"window.bc.upsertMessages([{"id":"m3","role":"assistant","html":"<p>reply2</p>"}], false)"#
    run("upsertMessages(array,bool) <-- template's signature", js) { self.step5() }
}
```

Build and run: `swiftc -o probe main.swift && ./probe`
(macOS 14+ cooperative activation gotcha from Round 3 applies — the probe creates its own `NSWindow` and calls `orderFrontRegardless()`, otherwise `bcReady` never fires from a background shell.)

## Appendix B — timeline

| Time (2026-08-06) | Event |
|---|---|
| 17:22:52 | Binary built from `ca122a3` source |
| 17:23:07 | `ca122a3` committed (markdown→sanitize fix) |
| 17:45 / 18:30 | Q's white-screen diagnosis; `privacy: .public` logging patch |
| 18:20:56 | Binary rebuilt + installed — **this is the build Adam tested** |
| 20:47–20:55 | Adam's failing session. 27 `upsertMessages` JS exceptions logged in cleartext |
| 21:28:04 | `1cfe96d` committed — Fix 1a/1b/2a. **Never built or installed.** Did not address the seam |
| 22:11–22:19 | Fable RCA: probe, seam audit, fix, seam suite, revert-and-fail check |
| 22:20:14 | Binary rebuilt + installed — **first build containing both `1cfe96d` and the seam fix** |
