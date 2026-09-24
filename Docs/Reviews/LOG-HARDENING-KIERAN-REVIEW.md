# LOG-HARDENING — Independent Verification (E5)

**Reviewer:** Kieran (independent; implementer Q may not sign their own gate)
**Date:** 2026-09-24
**Repo:** `/Users/openclaw/projects/BeeChat-v5`
**Branch:** `fix/log-hardening`
**Commit under test:** `2a64c0a1a9a4188a8c790f9fb83cf11e300a281b`
**Base:** `origin/develop` @ `682e701ddb2dc21bdee7cb36fca61fc8d55fcfa6`
**Spec:** `Docs/Specs/Active/LOG-HARDENING-SPEC.md` (not present on this branch — retrieved from branch `feat/transcript-integration` @ `00e708b`; see F-10)
**Q's claims (treated as claims, not fact):** `Docs/Reviews/LOG-HARDENING-MUTATION-EVIDENCE.md`, `Docs/Status/LOGGING-STANDARD.md`

## VERDICT: CORRECTIONS REQUIRED

The three primary guards (G1 abs-path rule, G2 behavioural bound, G3 default-off gate) are
genuinely load-bearing — each goes red when its defect is restored, and I reproduced all
three independently. The sink refactor, migration, and full suite are sound.

**One blocker:** the highest-priority credential guard, **G4, is not reliably load-bearing
against the exact defect it exists to catch.** With the handshake log restored, G4 passed
(0 failures) on **5 of 20 runs — a 25% false-green rate.** A guard that can be defeated by
run-to-run dictionary key ordering is not yet a guard. Details in F-1.

A second, independent finding (F-2): G1's documented split-literal defence is not wired into
the scan path, and its own fixture tests the joined form the scan never uses — the exact
"test the validator on the form it cannot see" trap from the standing corrections.

---

## AC-by-AC results

| # | Criterion | Result | Evidence (command → observed) |
|---|---|---|---|
| AC-1 | `swift build --target BeeChatGateway` | **PASS** | `swift build --target BeeChatGateway` → `Build of target: 'BeeChatGateway' complete!` |
| AC-2 | Full `swift test` | **PASS** | `swift test` → `Executed 164 tests, with 1 test skipped and 0 failures` |
| AC-3 | `/Users/openclaw/Desktop` only in Migration016 | **PASS** | `grep -rn "/Users/openclaw/Desktop" Sources/` → 1 hit: `DatabaseManager.swift:448` (the allowlisted predicate) |
| AC-4/5 | Bounded write, behavioural | **PASS** | G2 test drives 10×~400 B into 1 024 B cap; disabled trim → RED `("4000") is greater than ("1024")` |
| AC-5 | G2 behavioural (not constant) | **PASS** | Same — real >cap write, asserts size + mode + single generation |
| AC-6 | G1 mutation → RED | **PASS** | Added literal → RED `GatewayDiagnostics.swift: /Users/mutation/Desktop/secret.log`; reverted → green |
| AC-7 | G3 mutation → RED | **PASS** | Gate always-on → 3 failures (lines 90/95/96); reverted → green |
| AC-7b | G4 mutation → RED | **FAIL (blocker)** | Handshake restore: 8 failures on some runs, **0 failures on 5/20 runs**. URL restore: reliably 4 failures. See F-1 |
| AC-8 | Installed binary post-fix | **NOT SATISFIED** | Installed `BeeChatApp` dated `Aug 7 13:59`, still contains `Sending handshake` (1 hit), lacks `BEE_DEBUG_LOG`. Release action, not code — see F-5 |
| AC-8b | Stale Desktop logs deleted | **NOT VERIFIED** | Out of my limits (no log deletion); no evidence in the commit |
| AC-9 | STATUS.md build row | **NOT SATISFIED** | `Docs/Status/STATUS.md` updated `2026-06-22`; no logging/hardening row — see F-6 |
| AC-10 | No token to file; G4 fails on either restore | **FAIL (blocker)** | Same as AC-7b — handshake half is flaky |
| AC-11 | Header comment literally true | **PASS** | `GatewayClient.swift:6-9` comment matches `BoundedFileLog` behaviour (1 MB cap, trim to 256 KB, 0600) |
| AC-12 | Non-app-hosted guard; names files; zero-scan fail | **PASS** | `BeeChatLoggingTests` target (non-hosted); asserts names `GatewayClient.swift`, `Topic.swift`; `XCTAssertFalse(sources.isEmpty)` |
| AC-13 | Gate off under temp HOME → no file | **PASS** | G3 test uses injected `environment: [:]` + temp `homeDirectory` |
| AC-14 | Operational leak-stopped proof | **NOT RUN** | Requires app quits/install/reconnect session (out of scope) |
| AC-15 | Tests cherry-picked to feat/transcript-integration | **NOT SATISFIED** | `git ls-tree 32afd4e` → no `LoggingPolicyTests`/`GatewayLoggingSecurityTests`/`BoundedFileLog` — see F-7 |
| AC-16 | G1 flags split literals + `.desktopDirectory` | **PARTIAL/FAIL** | `.desktopDirectory` caught in non-UI targets only; **split absolute literals evade the abs-path scan** — see F-2 |
| AC-17 | Sink inventory by name | **PASS** | All five re-run; results match Q's recording (below) |
| AC-18 | Migration deletes exact seed; consumer safe | **PASS** | 4 migration tests green; consumer `BookmarkRepository.fetchAll()` clean — see F-8 (opt-in real DB) |
| AC-19/20 | Purge archives / rotate token | **NOT DONE** | Operational; no automation; out of my limits |
| AC-21 | Files created 0600 | **PASS** | `BoundedFileLog.swift:95,100` create + set `0o600`; G2 asserts it |
| AC-22 | AC-4/5 in E5 | **PASS** | I verified AC-4/AC-5 behaviourally |

---

## Findings

### F-1 — BLOCKER: G4 false-greens 25% of the time when the credential leak is restored

**What I did.** Restored exactly the defect the guard exists for — added
`debugLog("Sending handshake: \(text.prefix(500))")` after the frame-encode log line
(`GatewayClient.swift:583`) — then ran, 20×:

```
swift test --filter "GatewayLoggingSecurityTests.testG4ChallengeHandshakeAndReconnectNeverExposeCredentials"
```

**Observed (defect PRESENT):** `0 failures` on **5 of 20 runs (25%)**, 8 failures on the rest.
A false-green means: the token-bearing frame is being logged, and G4 says nothing.

**Root cause (proven, not inferred).** I instrumented the encode site:

```
G4DIAG prefixHasTok=false prefixHasDev=false tokOffset=697 devOffset=658 len=779
G4DIAG prefixHasTok=false prefixHasDev=false tokOffset=502 devOffset=548 len=779
G4DIAG prefixHasTok=true  prefixHasDev=true  tokOffset=146 devOffset=192 len=779
```

The encoded handshake frame is a fixed **779 chars**, but `JSONEncoder` emits dictionary
keys in **non-deterministic order**, so the sentinel offset inside `text` varies per run
(observed **146 … 727**). The leaking call uses `text.prefix(500)`. When the offset is
**≥ 500**, the sentinel falls outside the prefix and the leak captures *no* credential —
so G4 passes while the defect is present.

**Why the fixture doesn't save it.** G4's fixture guards with
`sentMessages.contains { $0.contains(token) && $0.contains(deviceToken) }` — that checks the
**full** frame, not `text.prefix(500)`. So the fixture proves a credential-bearing handshake
*exists*, but never proves the credential is inside the *exact 500-char window the leaking
sink would capture*. The test asserts the precondition, not the sink's view. That is the
distinction between "rejected" and "absent" the standing correction warns about.

**Severity:** blocker. This is the highest-priority guard in the spec (§4.5: "G4's mutation
test is highest priority"), it sits on a **confirmed live credential leak** (§6.1b), and it
is not load-bearing against the specific sink it was written for.

**Suggested fix (for Q, not applied by me):** make the sentinel deterministic relative to the
leak window — e.g. (a) encode with `.sortedKeys` and assert the sentinel offset < 500 in the
test, or (b) place the sentinel so it is guaranteed to fall within any 500-char prefix
(auth token first by construction), or (c) most robustly, have G4 assert on the *prefix the
code actually logs*, i.e. inject the sink and check `message.contains(token)` for the exact
message string produced. Also: the fixture should assert the *negative* deterministically —
loop or pin the key order so red/green is stable.

**Also observed:** the red-run magnitude is unstable across three modes — `8 failures
(0 unexpected)` (assertions), `1 failure (1 unexpected)` (thrown/unexpected), and
`0 failures`. The `1 unexpected` runs indicate a timing/concurrency flake in
`ReconnectingFakeTransport` (the `0..<200` poll loop + timeout `Task`). Flaky security tests
erode trust; worth de-flaking regardless of the fix above.

### F-2 — MAJOR: G1's split-literal defence is not wired into the scan; its fixture tests the form the scan never uses

Spec §4.5 and AC-16 state G1 "flag[s] **split/concatenated** literal fragments that reassemble
to an abs path." The implementation only joins fragments for the **Desktop** rule, not the
absolute-path rule:

- Scan (line 26): `Self.userSpecificAbsoluteLiterals(in: source)` — **raw** source.
- Scan (line 38-40): `let normalized = joinAdjacentStringFragments(...)` then `desktopLiterals(in: normalized)` — **joined**.
- Fixture (line 54): `Self.userSpecificAbsoluteLiterals(in: normalizedDefect)` — **joined**.

So the must-fail fixture validates the abs-path checker on the *joined* string, while the
production scan feeds it the *raw* string. The fixture therefore passes while the scan
silently skips split literals — the "test a validator on the form it cannot see" trap.

**Probed, defect forms injected into a NON-UI target (`Sources/BeeChatGateway`):**

| Injected form | Scanner sees | Expected | **Actual** |
|---|---|---|---|
| `"/Users/mutation/Desktop/secret.log"` (plain) | raw literal | RED | **RED** ✓ |
| `"/Users/" + "alice/secret.log"` (split) | fragments | RED | **GREEN ✗** |
| `".desktopDirectory"` in non-UI target | token | RED | **RED** ✓ |
| `"/Users/" + "alice/Desktop/secret.log"` (split, App target) | fragments | RED | **GREEN ✗** |

An attacker/regressor writes `"/Users/" + "alice/Desktop/secret.log"` and G1 stays green in
every target. That is a genuine, statically-visible defeat of the class control.

**Severity:** major. Mitigating context: the spec itself calls the textual scan "supporting,
not the class control" and acknowledges "arbitrary runtime concatenation evades a literal
scan." But adjacent **string-literal** concatenation is exactly what AC-16 claims to catch and
is statically resolvable, so either wire the join into the abs-path scan or strike the claim
and the misleading fixture.

### F-3 — MAJOR: G1's Desktop rule cannot catch the original sink-2 defect form in the App target

`isNonUITarget` is hard-scoped to `Sources/BeeChatGateway/`, `Sources/BeeChatPersistence/`,
`Sources/BeeChatSyncBridge/`. Sink 2's original defect
(`FileManager.default.urls(for: .desktopDirectory, …)`) lived in
`Sources/App/Utils/BeeChatLogger.swift` — the **App** target.

I restored that exact form in `Sources/App/Utils/BeeChatLogger.swift`:
`swift test --filter LoggingPolicyTests.testG1SourcePathPolicy` → **passed** (0 failures).
The same form in `Sources/BeeChatGateway` → **RED**.

So the guard, as scoped, would not have caught (nor would it catch a regression of) the
second real defect. The `/Users/<name>/` literal rule *is* global and does fire in the App
target, so the class is not wholly unguarded — but the Desktop-component half is narrower than
the §1/§3.5 narrative implies. The spec text literally says "non-UI targets" (§4.5), so this
is per-spec-as-written; flagging because the guard-to-defect gap is real.

### F-4 — MINOR: BeeChatLogger content-sanitizer is marker-based and narrow

`BeeChatLogger.sanitized()` redacts only the `, text=` / ` text=` markers (one legacy field).
42 call sites exist; the one content-bearing site
(`MessageViewModel.swift:123`, `text=\(text.prefix(50))`) is covered by the ` text=`/`, text=`
marker. But the redaction is string-pattern-based and one marker away from a leak; and the
policy (§4.4/F9) says "no user message content or PII," which a marker match does not enforce
generally. Acceptable as a surgical fix; note it as a standing smell, not a blocker.

### F-5 — MINOR: AC-8 not satisfied (installed binary is pre-fix)

`/Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp` is dated `Aug 7 13:59:46 2026`, still
emits `Sending handshake` (1 `strings` hit) and lacks `BEE_DEBUG_LOG`. Committing is not
shipping. This is a release-checklist action, correctly out of my limits, but AC-8 is
**open** — the live leak is not stopped by this commit.

### F-6 — MINOR: AC-9 not satisfied

`Docs/Status/STATUS.md` was last updated `2026-06-22`; there is no build-history row for the
log-hardening build. Trivial to remedy.

### F-7 — MINOR: AC-15 not satisfied

`git ls-tree -r 32afd4e` shows no `BoundedFileLog.swift`, `LoggingPolicyTests.swift`, or
`GatewayLoggingSecurityTests.swift` on `feat/transcript-integration`. The merge guard the spec
requires (so a bad merge resolution turns the tests red rather than silently reverting) is
**not** in place.

### F-8 — MINOR: the real-DB migration test is opt-in (skipped by default)

`testMigration016AgainstRealDatabaseCopyWhenProvided` skips unless `BEECHAT_REAL_DB_PATH` is
set. I ran it against a **copy** of the live DB:

```
cp "/Users/openclaw/Library/Application Support/BeeChat/BeeChat.sqlite" /tmp/beechat-real-run.sqlite
BEECHAT_REAL_DB_PATH=/tmp/beechat-real-run.sqlite swift test --filter LoggingHardeningMigrationTests.testMigration016AgainstRealDatabaseCopyWhenProvided
→ passed (0.189s)
```

Live DB inspection (read-only on a copy): 6 bookmarks, exactly **1** pristine seed; the other
5 Desktop bookmarks differ in `name`/`iconName` so survive the predicate. The test is
non-mutating by design (it migrates a GRDB `backup` destination, not the source — correct).
Risk: because it is opt-in, CI/`swift test` alone does **not** gate the real-DB case. Worth a
documented fixture DB checked in, or a required step in the release checklist.

### F-9 — NIT: `testMigration016AgainstRealDatabaseCopyWhenProvided`'s fallback branch is weak

When `pristineBefore == 0`, it asserts `fetchAll().count >= 0` — always true (vacuous). Harmless
here because the primary assertion (`pristineAfter == 0`) still fires, but it is dead assertion
weight.

### F-10 — NIT / process: the cited spec is not on the branch under test

`Docs/Specs/Active/LOG-HARDENING-SPEC.md` does not exist on `fix/log-hardening`; it lives on
`feat/transcript-integration`. A reviewer (or future reader) checking the commit under test has
no in-repo copy of the criteria it is signed against. Fold the spec (or a copy) onto the fix
branch, or cite the exact SHA in the commit message.

---

## Verification detail (reproducible commands)

**AC-17 sink inventory — independently re-run (matches Q's recording):**

```
grep -rn 'EventMonitor|cURLDescription' Sources Package.swift   → 0 hits (ABSENT)
grep -rn '\.trace\b' Sources                                     → 0 hits (ABSENT)
grep -rn 'os_log|%\{public\}' Sources                            → 0 hits (ABSENT)
grep -rn 'Sentry|Crashlytics|NSSetUncaughtExceptionHandler|signal\(' Sources Package.swift → 0 hits (ABSENT)
grep -rn 'TopicSummaryWriter|ProjectScaffolder' Sources          → present (user-requested writers)
```
`Logger(subsystem:)` sites use `.private` interpolation; no `.public`/`%{public}` sites found.

**Bookmark consumer:** `BookmarkRepository.fetchAll()` returns an ordinary `[Bookmark]`
(no force-unwrap, no `try!`); `FolderPicker.loadBookmarks()` renders the empty array and calls
`FileManager.fileExists` before use. No `sortOrder == 4` assumption anywhere (`grep` → 0 hits).
Fresh-DB test asserts `fetchAll().isEmpty`.

**Mutation red-runs I produced (all reverted; tree verified byte-identical to `2a64c0a` after each):**

| Guard | Mutation | Result |
|---|---|---|
| G1 | `"/Users/mutation/Desktop/secret.log"` in GatewayDiagnostics | RED (1 failure, exact diagnostic) |
| G2 | trim branch disabled (`if false`) | RED (`("4000") is greater than ("1024")`) |
| G3 | gate `!= "0"` (always-on) | RED (3 failures) |
| G4-URL | restore `debugLog("transport.connect called — url=\(url.absoluteString)…")` | RED (4 failures — gateway token × 4 sinks) |
| G4-handshake | restore `debugLog("Sending handshake: \(text.prefix(500))")` | **FLAKY — RED 15/20, FALSE-GREEN 5/20** |

**Build / suite (clean HEAD):**
```
swift build -c release   → Build complete!
swift test               → Executed 164 tests, with 1 test skipped and 0 failures
```

**Cleanliness:** all mutations reverted; `git diff 2a64c0a -- Sources Tests Package.swift` empty
before writing this review. The only `git status` entries are pre-existing untracked docs
(`RCA-unread-marker*`, `FIX-002-content-dedup-guard.md`) unrelated to this change.

---

## What is genuinely good here

- G2 is a **real** behavioural control: it drives a true >cap write and asserts size, mode,
  and single-generation count. Not a constant compare. Mutation-verified.
- G3 uses **injectable** config + temp HOME, so it tests the write path, not a `static let`.
  Mutation-verified.
- `BoundedFileLog` correctly caps even a single oversize record (suffix-trim), one file, no
  generations, 0600 — matches the policy and AC-21.
- Migration016's predicate matches all four spec conditions exactly, and the 3 + real-DB
  fixtures cover pristine/renamed/re-iconed/bookmarked/copy cases.
- The refactor is surgical: sink-only change to `BeeChatLogger`, no call-site churn, `BEE_DEBUG_LOG_PATH`
  override preserved for the gateway.

---

## Bottom line

`SOUND WITH FIXES` is not defensible while the credential guard can pass with the credential
leak present. Verdict: **CORRECTIONS REQUIRED.** Required before this can be signed:

1. **F-1 (blocker):** make G4 deterministically red when the handshake log is restored
   (pin key order / assert on the exact logged prefix), and de-flake the transport fixture.
2. **F-2 (major):** wire fragment-joining into the abs-path scan (or strike the AC-16
   split-literal claim and fix the misleading fixture so it exercises the scan's real path).
3. **F-3 (major):** decide whether the Desktop-component rule should cover the App target;
   as scoped it does not catch sink 2's own defect form.
4. **F-5/F-6/F-7 (minor):** AC-8 (ship), AC-9 (STATUS row), AC-15 (cherry-pick tests to the
   feature branch) are outstanding.

None of F-1…F-7 is irreversible; all are code/doc changes on `fix/log-hardening`. F-1 is the
one that matters most — it is the difference between a guard and a gesture.

— Kieran

---
---

# ROUND 2 — Independent Re-verification (E5)

**Reviewer:** Kieran (independent; Q may not sign their own fix)
**Date:** 2026-09-24
**Branch:** `fix/log-hardening`
**New commit under test:** `f32d14be2b2efefd08959b0668b492d6a8fe6618` ("fix(logging): make hardening guards deterministic")
**Prior verified baseline:** `2a64c0a` (round-1 review)
**Diff reviewed:** `git diff 2a64c0a..f32d14b` = 4 files, +87/−34
**Q's claims:** `Docs/Reviews/LOG-HARDENING-MUTATION-EVIDENCE.md` — treated as **claims**, not fact.

## VERDICT: SOUND WITH FIXES

All three round-1 corrections are **independently verified as genuinely fixed**:

- **F-1 (was BLOCKER)** — G4 is now deterministically load-bearing. 20/20 RED on the handshake
  mutation, **zero false greens**, and — critically — the RED is for the *right reason* (the 8
  credential-leak sink assertions), not the precondition or a flake. `.sortedKeys` genuinely
  pins the sentinel offset (measured 109/70 across runs; round 1 saw 146–727).
- **F-2 (was MAJOR)** — the split-literal defence is now wired into the abs-path scan; the
  split form goes RED in the *production* scan, and the fixture is proven load-bearing against
  the *split* form (not the joined one).
- **F-3 (was MAJOR)** — the Desktop-component rule now covers `Sources/App`; sink 2's own defect
  form goes RED naming `Sources/App/Utils/BeeChatLogger.swift`.

No previously-passing guard regressed (G1/G2/G3, AC-3 carve-out, Migration016 all still green;
G2/G3 mutations still RED). Full suite: **164 tests, 1 skipped, 0 failures.**

**One residual (minor) finding remains** (N-1): the transport fixture still **flakes ~4% on the
clean tree** — a false-**RED** via `GatewayClient.swift:158` (`code -99`), which **contradicts
Q's explicit "0 unexpected failures" claim**. This is a test-reliability defect, not a guard
defeat or a security hole: I found **no false-green** in any sample. Sign-with-fix, not block.

---

## Round-2 findings

### N-1 — MINOR: the transport fixture still flakes (~4% false-RED on clean code), contradicting Q's "0 unexpected failures"

**What I did.** Ran the G4 test on the **clean** tree (no mutation) repeatedly:

- 30 runs → **28 PASS, 2 FAIL** (`1 failure (1 unexpected)` each)
- 40 runs → **39 PASS, 1 FAIL** (`1 failure (1 unexpected)`)
- Combined clean-tree sample: **3 false-REDs in 70 runs (~4.3%)**

**Failure detail (clean run 33):**

```
Sources/BeeChatGateway/GatewayClient.swift:158: error: ... failed: caught error:
  "Error Domain=GatewayClient Code=-99 \"Handshake completed but state is connecting, not connected\""
Executed 1 test, with 1 failure (1 unexpected) in 0.028 seconds
```

**Root cause.** This is the same concurrency flake flagged in round-1 F-1's "also observed" note:
`connect()` (line 158) checks `state != .connected` immediately after the continuation resumes,
but `succeedHandshake()` resumes the continuation from the receive-loop `Task`, so `state` can
still read `.connecting` for a scheduling tick. It is a race between the state transition and the
caller's post-resume check — independent of the log-hardening fix, and present with **no mutation applied**.

**Why it matters for E5.** Q's evidence file states the 20-run G4 experiment produced "**0
unexpected failures**". Over a larger sample that is not reproducible: the fixture emits
`1 unexpected` at roughly 1-in-20 to 1-in-30 on both clean and mutated trees. A red result is not
self-interpreting if it can also be produced by a race — a reviewer reading "RED" cannot tell
"leak caught" from "race thrown" without the sink-failure count. That is the same
"rejected vs absent" indistinguishability the standing corrections warn about, one level up.

**Severity: minor.** It is a **false-RED**, so it never lets a real leak pass (I found zero
false-greens). But it is the class of flakiness round 1 flagged, Q declared eliminated, and it is
not. Fix: assert on the sink captures *before* the `state` check, or make `connect()` await the
settled state (e.g. resume the continuation only after `state = .connected` is published), or
have the fixture ignore the `-99` throw as fixture plumbing.

### N-2 — NIT: round-1 F-5/F-6/F-7 (AC-8/AC-9/AC-15) remain outstanding and untouched by this commit

`f32d14b` touches only the four hardening files; the operational/doc ACs are unchanged:

- **AC-8** — installed `/Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp` still dated **Aug 7
  13:59**, still contains `Sending handshake` (1 `strings` hit). Not shipped.
- **AC-9** — `Docs/Status/STATUS.md` still has no logging/build-history row.
- **AC-15** — `feat/transcript-integration` still lacks `BoundedFileLog.swift` / the two guard test
  files (merge guard not in place).

These were correctly out of scope for a code-fix commit; recording them as still-open so the
verdict is not read as "everything green".

---

## F-1 verification detail (BLOCKER → FIXED)

**Method.** Re-applied the exact defect — inserted after the frame-encode log line at
`GatewayClient.swift:588`:

```swift
debugLog("Sending handshake: \(text.prefix(500))")
```

**1. Handshake mutation, 20 runs (fresh, definitive):**

```
RED: 20/20   GREEN: 0/20
runs with unexpected>0: 0/20
runs with exactly 8 sink-assertion failures: 20/20
```

Every run failed the **8 credential-leak assertions** (4 sinks × {token, deviceToken}), e.g.:

```
GatewayLoggingSecurityTests.swift:71: XCTAssertFalse failed - gateway token escaped a diagnostic sink
GatewayLoggingSecurityTests.swift:72: XCTAssertFalse failed - device token escaped a diagnostic sink
```

Zero `must be inside the exact prefix` failures and zero `fixture did not` failures in the 20 —
i.e. the precondition passed and the guard caught the real defect. **The 20/20 is real, not a
precondition artefact.** (Larger sanity sample: 30 mutated runs → 30/30 RED; 29/30 failed the 8
sink assertions, 1/30 was the N-1 race RED-with-wrong-reason. Still **zero false-greens**.)

**2. Determinism proof (`.sortedKeys` pins the offset).** I temporarily instrumented the fixture to
print sentinel offsets. Round 1 measured offsets swinging **146…727** (token landed outside
`prefix(500)` on 25% of runs → false-green). Round 2, with `.sortedKeys`:

```
G4DIAG frame=0 len=779 tokOffset=109 devOffset=70
G4DIAG frame=1 len=779 tokOffset=109 devOffset=70
```

Identical across every run. **The offsets are now pinned at 109/70 — both inside the 500-char
window, deterministically.** This is the substantive fix; the precondition alone would not have
been enough.

**3. Load-bearing precondition (the round-1 trap — must fail LOUDLY, not silently skip).** I forced
the precondition false by shrinking the asserted window (`prefix(10)` instead of `prefix(500)`):

```
GatewayLoggingSecurityTests.swift:69: error: ... failed -
  fixture credentials must be inside the exact prefix(500) handshake leak window
Executed 1 test, with 1 failure (0 unexpected)
```

It **fails loudly** as a test failure (`XCTFail` + early `return`), **not** a skip and **not** a
silent pass. If the fixture ever stops exercising the leak window, G4 goes red rather than green.
Trap closed.

**4. URL mutation (separate sink).** Restored round-1's second defect form after `transport.connect`:

```swift
debugLog("transport.connect called — url=\(url.absoluteString) origin=\(origin)")
```

→ **RED, 4 failures** (gateway token in all four sinks). Reverted → green.

**5. Byte-identical revert.** After each mutation/test cycle I ran `git checkout --` and confirmed:

```
git diff f32d14be2b2efefd08959b0668b492d6a8fe6618   → EMPTY (exit 0)
```

The tracked tree is byte-identical to `f32d14b`. (`git status` shows only the three pre-existing
untracked docs, unrelated.)

---

## F-2 verification detail (MAJOR → FIXED)

The fix routes **both** the production scan and the fixtures through one helper,
`sourceFindings(in:relativePath:)`, which joins adjacent string fragments **before** the abs-path
and Desktop rules run.

**1. Production scan catches the split form.** Injected round-1's exact split literal into a real
non-UI source file (`Sources/BeeChatGateway/GatewayDiagnostics.swift`):

```swift
static let __mutPath = "/Users/" + "alice/Desktop/secret.log"
```

→ **RED** via the production scan (`swift test --filter LoggingPolicyTests.testG1SourcePathPolicy`):

```
LoggingPolicyTests.swift:46: XCTAssertTrue failed -
  Sources/BeeChatGateway/GatewayDiagnostics.swift: /Users/alice/Desktop/secret.log
Sources/BeeChatGateway/GatewayDiagnostics.swift: Desktop component in /Users/alice/Desktop/secret.log
```

In round 1 this exact input was **GREEN**. Now it is RED, named with the reassembled literal.

**2. The fixture tests the SPLIT form, not the joined form (mutation-tested).** The round-1 defect
was that the fixture validated the checker on a *joined* string while the scan fed it the *raw*
string. To prove that is no longer true, I removed the join from `sourceFindings` and re-ran the
fixture test:

```
LoggingPolicyTests.swift:55: XCTAssertFalse failed   → RED
```

Line 55 is exactly `XCTAssertFalse(splitFindings.userSpecificAbsoluteLiterals.isEmpty)` — the
**split**-form assertion. So the fixture fails when the join is gone and passes when it is present:
it is **load-bearing on the split form**. Restored; tree clean.

---

## F-3 verification detail (MAJOR → FIXED)

The `isNonUITarget` allow-list is gone; `usesDesktopDirectory` is computed for **every** scanned
source file, so the Desktop rule is global (App target included).

Restored sink 2's own defect form in the App target:

```swift
private static let __probeURLs = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
```

`Sources/App/Utils/BeeChatLogger.swift` → **RED**, naming that file:

```
LoggingPolicyTests.swift:46: XCTAssertTrue failed -
  Sources/App/Utils/BeeChatLogger.swift: .desktopDirectory
```

In round 1 the same form in the same file was **GREEN**. Reverted; tree clean.

---

## Regression sweep (previously-passing guards must not break)

| Guard / control | Command | Result |
|---|---|---|
| G1 abs-path policy (production) | `swift test --filter LoggingPolicyTests.testG1SourcePathPolicy` | **PASS** |
| G1 fixtures (split + App Desktop + bare validator) | `...testG1FixturesRejectSplitAbsolutePathAndAppDesktopDefects` | **PASS** |
| G2 behavioural bound | `...testG2WriterBoundsOneFileAndUsesPrivatePermissions` | **PASS** |
| G3 default-off gate | `...testG3DefaultGateCreatesNoFileUnderInjectedHome` | **PASS** |
| AC-3 carve-out | `grep -rn "/Users/openclaw/Desktop" Sources/` | **1 hit** (DatabaseManager.swift:448, the allowlisted Migration016 predicate) |
| Migration016 | `swift test --filter LoggingHardeningMigrationTests` | **3 pass, 1 skipped** (real-DB opt-in), 0 fail |

Mutation load-bearing re-checks (defect restored → must go RED):

| Guard | Mutation | Result |
|---|---|---|
| G2 | disabled `existing + data.count > maximumBytes` trim branch | **RED** — `("4000") is greater than ("1024")` |
| G3 | gate `!= "0"` (always-on unless explicit 0) | **RED** — 3 assertion failures (lines 106/111/112) |

Full suite + release build at `f32d14b` (clean tree):

```
swift build -c release   → Build complete!
swift test               → Executed 164 tests, with 1 test skipped and 0 failures
```

---

## E8 — pre-registered criteria vs verdict logic (no silent skips)

Every AC printed in spec §7 is accounted for below; nothing is silently dropped. Criteria marked
**operational** are outside a reviewer's limits (they need install/kill/rotate) — they are listed
explicitly as **not-verified-here**, not omitted.

| # | Criterion (pre-registered) | Round-2 status | Evidence |
|---|---|---|---|
| AC-1 | `swift build --target BeeChatGateway` | **PASS** | release build complete |
| AC-2 | Full `swift test` passes | **PASS** | 164 / 1 skipped / 0 fail |
| AC-3 | zero `/Users/openclaw/Desktop` except Migration016 | **PASS** | grep → 1 allowlisted hit |
| AC-4 | gate off → no file (behavioural) | **PASS** | G3 (injected env + temp HOME) |
| AC-5 | gate on → bounded, behavioural | **PASS** | G2 drives >cap write |
| AC-6 | G1 fails when `/Users/...` re-added | **PASS** | abs-path mutation RED |
| AC-7 | G3 fails when always-on | **PASS** | G3 mutation RED (3 failures) |
| AC-7b | G4 fails when handshake restored | **PASS (F-1 fixed)** | 20/20 RED, 8 sink asserts, 0 false green |
| AC-8 | installed binary post-fix | **NOT SATISFIED** | binary dated Aug 7; still `Sending handshake` (N-2) |
| AC-8b | stale Desktop logs deleted | **NOT VERIFIED** | outside reviewer limits |
| AC-9 | STATUS.md build row | **NOT SATISFIED** | no row (N-2) |
| AC-10 | no code writes token/deviceToken; G4 fails on either restore | **PASS (F-1 fixed)** | handshake 20/20 RED + URL 4 RED; no token-write site greps |
| AC-11 | GatewayClient header comment literally true | **PASS** | comment matches BoundedFileLog (1 MB cap, 256 KB trim, 0600, default-off) |
| AC-12 | non-app-hosted target; named files; zero-scan fails | **PASS** | asserts `GatewayClient.swift` + `Topic.swift`; `XCTAssertFalse(sources.isEmpty)` |
| AC-13 | gate off under temp HOME → no file | **PASS** | G3 |
| AC-14 | scripted operational leak-stop proof | **NOT RUN** | needs install/reconnect session (operational) |
| AC-15 | tests cherry-picked to feat/transcript-integration | **NOT SATISFIED** | files absent on that branch (N-2) |
| AC-16 | G1 flags split literals + `.desktopDirectory` + empty-scan | **PASS (F-2/F-3 fixed)** | split → RED (F-2); App `.desktopDirectory` → RED (F-3); empty-scan assert present |
| AC-17 | sink inventory by name | **PASS** | round-1 re-run; unchanged by this commit |
| AC-18 | migration deletes exact seed; consumer safe | **PASS** | 3 migration tests green (real-DB opt-in skipped) |
| AC-19 | purge archives | **NOT VERIFIED** | outside reviewer limits |
| AC-20 | rotate token / re-pair device | **NOT VERIFIED** | outside reviewer limits |
| AC-21 | files created 0600 | **PASS** | G2 asserts `0o600`; `BoundedFileLog` sets it |
| AC-22 | AC-4/AC-5 in E5 | **PASS** | verified behaviourally above |

**E8 result: honest.** No pre-registered criterion is missing from the verdict logic; the
operational ones are named as not-verified rather than quietly dropped.

---

## Adversarial angle — is the fix still theatre?

- **Is 20/20 real, or an artefact of a weak precondition?** Real. I checked red-for-the-right-reason
  (8 sink assertions, precondition *passed*) and, separately, that the precondition itself fails
  loudly when forced false. `.sortedKeys` was independently measured to pin the offset (109/70) —
  the determinism is in the encoder, not just the assertion.
- **Does `.sortedKeys` truly pin the offset?** Yes — verified by instrumentation across runs
  (round 1: 146–727; round 2: constant 109/70).
- **Can the guard still be defeated?** I probed non-500 prefix lengths as a proxy for "a different
  leak window the guard wasn't calibrated for": `prefix(110)` and `prefix(100)` → RED (4 sink
  asserts, correct — both sentinels inside); `prefix(75)` → **GREEN**, and that is **correct**:
  token sits at offset 109, so `prefix(75)` genuinely captures no credential. The guard is honest
  across window sizes — it reddens iff a credential actually escapes. No false-green found in any
  sample.
- **Remaining theatre surface:** N-1's race means a "RED" could occasionally be the race rather
  than the leak. Mitigation: the sink-failure count distinguishes them (leak = 8 asserts, race = 1
  unexpected). Recommend fixing the race so red is unambiguous.

---

## Bottom line (round 2)

**SOUND WITH FIXES.** The blocker and both majors are genuinely resolved and independently
reproduced; the previously-passing guards did not regress; the full suite is green. The only
outstanding code-level item is **N-1** (fixture race → ~4% false-RED, and Q's "0 unexpected"
claim is not reproducible) — a reliability fix, not a security hole. AC-8/8b/14/19/20 remain
operational (outside reviewer limits); AC-9/AC-15 remain open as before.

Nothing merged, deployed, installed, or rotated by me. Only this document is committed.

— Kieran (round 2)
