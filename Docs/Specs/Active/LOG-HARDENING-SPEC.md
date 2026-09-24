# LOG-HARDENING — Diagnostic Logging Standard & Leak Remediation

**Spec ID:** LOG-HARDENING
**Task ID:** T-BEECHAT-LOGGING-HARDENING
**Tier:** Standard (multi-file, release-path)
**Status:** SPEC — awaiting Kieran + Q validation (per PROCESS.md step 2)
**Author:** Bee
**Date:** 2026-09-24
**Routing:** MODE `graph` · TIER `standard` · gate recorded (integrity `8baf879b…`)

**Evidence revision pin:** all line citations below verified against working tree
HEAD `32afd4ecaa30bc1b7529599d85c289cc89c279b3` (`feat/transcript-integration`)
and `main` `381dec91a03ef65319cd5e71c6073187a85869c6`. Re-read every cite against
HEAD before this spec is folded (standing correction: line citations drift).

---

## 1. Problem statement

Three diagnostic-logging defects, of one class, were found in BeeChat-v5 on
2026-09-24. One has already leaked ~10 MB/hour. Two more are live and one is a
latent time bomb.

| # | Sink | Path | Bounding | On by default | State |
|---|---|---|---|---|---|
| 1 | `GatewayClient.debugLog` | ~~`/Users/openclaw/Desktop/BeeChat-debug.log`~~ fixed | **none** | **yes** → now gated | **Code fixed, NOT shipped** — ⚠️ latent token-logging defect (§6.1a) |
| 2 | `BeeChatLogger` (diagnostics) | `~/Desktop/BeeChat-diagnostics.log` | 1 MB → trims to 256 KB | **yes, unconditional** | **Live, leaking** |
| 3 | `DatabaseManager` seed row | `/Users/openclaw/Desktop/Claude Oversight Reports` | n/a (data) | n/a | **Live, latent failure** |

> **Scope correction (2026-09-24, post-cite-verification):** a full `grep -rn
> "/Users/" Sources/` returns **25 hits across 10 files**, not the 2 originally
> noted. Most are **legitimate** (see §3.5) — regex patterns for parsing user
> file-links, and path-*validation* constants that *assert* paths must live under
> `/Users/`. Only three are **defects**. The guard design (§4.5) must distinguish
> them, or it will false-positive on ~22 legitimate hits and be ignored. This is
> exactly the "test the validator on the form it cannot see" trap — see §4.5.

**Confidence: high.** Each sink verified at the revision pin above.

> ⚠️ **Severity note (2026-09-24, corrected):** sink 1 also contains a **latent
> credential-logging defect** — `GatewayClient.swift:579` logs the handshake frame,
> whose params carry `token` + `deviceToken` (§6.1a). Direct inspection shows the
> current log file contains **no** leaked secret (§6.1b). So: fix required,
> **no token rotation required on current evidence**.

### Why this matters

- **Sink 1** entered a loop-bug state on 2026-09-24 writing every WS frame event
  unbounded (~10 MB/hour, caught by the system canary). Diagnostic job complete;
  logging now off by default.
  **Clarification (F2, verified):** there is **no runaway loop defect.** The volume
  came from `debugLog` firing **per WS frame event**; the reconnect path itself is
  bounded (`GatewayClient.swift:603-607`, `retryCount` + `backoff.delay`). So the
  fix is "stop logging every frame," not "fix a loop." No separate ticket needed.
- **Sink 2** is a *second* logger, missed in the first pass, that writes to the
  **Desktop** on **every send/stream/state transition** — dozens of call sites —
  unconditionally. It is bounded (1 MB) but unbounded in *rate* and writes to a
  user-visible location on every run. Its documented purpose ("so Bee can read
  the log remotely") is a stale assumption: Bee reads files from the workspace /
  project tree, not Adam's Desktop.
- **Sink 3** writes a hardcoded absolute path into the database as a folder
  favourite. On any machine that is not this exact Mac, or after the Desktop
  folder is renamed/moved, this row points at a nonexistent path. It is a
  data-level coupling to a single machine-specific absolute path.

### Root class

**Machine-specific absolute paths and always-on file logging, with no shared
standard and no build-time check.** All three survived because nothing in the
build rejects them. This spec fixes the three instances **and** closes the class.

---

## 2. Scope

### In scope
- Remediate sinks 1, 2, 3.
- Introduce a single shared logging policy + one implementation to replace ad-hoc
  file loggers.
- Add a **build-time / test-time guard** that fails on the class, so instances 4+
  cannot recur.
- Get sink 1 from "committed on a test branch" to "running in an installed build"
  via the correct release path.

### Out of scope
- Migrating existing `Logger(subsystem:category:)` (os.log) call sites — these are
  **correct** and stay as-is (see §3.4).
- Rotating/compressing historical logs already on disk.
- Any transcript-engine / Option B work.

---

## 3. Findings & decisions

### 3.1 Sink 1 — GatewayClient debug logger (code fixed, unshipped)

**Current committed state** (`Sources/BeeChatGateway/GatewayClient.swift:5-35`):
- `debugLogEnabled` = env `BEE_DEBUG_LOG == "1"`  → file writes **off by default**
- `debugLogURL` = `BEE_DEBUG_LOG_PATH` ?? `~/Library/Logs/BeeChat-debug.log`
- `print("[GW] …")` retained unconditionally
- Parent dir created before write

**Defects remaining in the fix itself:**
1. **No bounding/rotation even when enabled.** If someone sets `BEE_DEBUG_LOG=1`
   and leaves it on, this repeats the exact 2026-09-24 incident. The commit
   message claims "even then it is bounded" — **that claim is false.** It is
   *gated*, not *bounded*. This must be corrected (see §4.1).
2. **Location mismatch with PROCESS expectations:** `~/Library/Logs/` is
   conventional for a macOS app but is *outside* the repo/workspace tree, so Bee
   cannot read it without an absolute-path read outside the sandbox. Prefer the
   gated-off default to write nowhere, and when enabled write to a
   **workspace-relative or tmp** location Bee can actually reach.

**Decision D1:** Keep off-by-default gating. **Add real bounding** (size cap +
  rotation) so the "bounded when enabled" claim is *true*. Change enabled-path
  default to a location reachable for diagnostics (`~/.openclaw/workspace/tmp/`
  is not appropriate for a shipped app; use `~/Library/Logs/` **but** guarantee
  bounding, and document the read path). **Correction to commit `32afd4e`
  message is required** (comment text is not evidence — pin the invariant).

### 3.2 Sink 2 — BeeChatLogger diagnostics log (live)

**Current state** (`Sources/App/Utils/BeeChatLogger.swift`):
- `logURL` = `.desktopDirectory` + `BeeChat-diagnostics.log` (line 10-13)
- `maxLogBytes = 1_048_576`, `truncateToBytes = 262_144` (bounded, lines 25-27)
- Serial `DispatchQueue` (good — no main-thread block)
- Writes unconditionally on every call
- **~40+ call sites** across `ComposerViewModel`, `MessageViewModel`,
  `MainWindow`, `SyncBridgeObserver` (verified: 38 logged lines in grep)

**Defects:**
1. Writes to the **Desktop** — user-visible clutter, and a fixed absolute location.
2. On by default with no gate — every app run writes.
3. Doc comment ("so Bee can read the log file remotely") is a **stale premise** —
   Bee's file access is the workspace/project tree, not the Desktop.
4. `rotateLog` does `Data(contentsOf:)` on the whole file up to 1 MB on every
   rotation — acceptable at 1 MB, but note it's O(n) on the write queue.

**Decision D2:** Route `BeeChatLogger` through the same policy as D1:
  gated by the same flag, writes to a **bounded, home-relative, non-Desktop**
  location, and the call sites stay as-is (no churn) — the *sink* changes, not the
  ~40 callers. If the flag is off, `log()` becomes a no-op (retaining the
  serialised console `print` for local dev if desired — decide at review).

### 3.3 Sink 3 — DatabaseManager hardcoded Desktop path (latent)

**Current state** (`Sources/BeeChatPersistence/Database/DatabaseManager.swift:421`):
```swift
"/Users/openclaw/Desktop/Claude Oversight Reports",
```
This is a **seed row** for a folder favourite ("Claude Oversight Reports").

**Defects:**
1. Machine-specific absolute path embedded in a database migration/seed.
2. On any other machine the favourite points nowhere; on this machine it breaks
   if the folder moves.

**Decision D3:** Replace the hardcoded path with a **path derived at runtime**
  (e.g. `FileManager.default.homeDirectoryForCurrentUser` + relative component),
  **or** drop the seed row and let the user add favourites through the UI
  (preferred — a seed that hardcodes *Adam's* Desktop has no place in a shipped
  app). **This touches a migration/seed — must be reviewed against whether the
  row already exists in shipped DBs** (see §5, risk R2).

### 3.5 Legitimate `/Users/` uses — must NOT be flagged

Verified at HEAD (`grep -rn "/Users/" Sources/` → 25 hits, 10 files). These are
**correct** and the guard must not touch them:

| File | Kind | Why legitimate |
|---|---|---|
| `FileLinkText.swift:39,42,109` | regex + literal | parses user-authored `file://`/absolute links |
| `LinkPolicy.swift:15,76,81,111` | validation | asserts links resolve under `/Users/` (allowlist) |
| `Topic.swift:130,161,162` | validation | asserts project paths under `/Users/openclaw/Projects/` |
| `TopicSummaryWriter.swift:150,151` | prefix list | allowed workspace/project prefixes |
| `ProjectContextReader.swift:12` | validation | allowed prefix constant |
| `ProjectDirectoryUtils.swift`, `ProjectScaffolder.swift` | default arg | **user-specific default** — see note below |
| `SyncBridge.swift:468,780,861` | constant | workspace path — see note below |
| `EditTopicSheet.swift:109` | literal | builds `/Users/openclaw/Projects/<name>/` |

**Nuance (do not over-reach):** the *validation* uses (LinkPolicy, Topic,
ProjectContextReader) are correct — they *check* a path is under `/Users/`.
The *default-argument / hardcoded-constant* uses are **portability smells**
(they assume user `openclaw`) but are **out of scope for this spec** — changing
them risks the Option B branch and is a separate portability ticket. Record them
as a follow-up, do not fix them here. **Surgical rule: every changed line traces
  to this request.**

### 3.4 Sinks that are correct — do NOT touch

`Logger(subsystem: "com.beebox.beechat", category: …)` call sites (WebTranscriptView,
MessageCanvas, HTMLMessageConverter, MessageTemplate, MessageWebView,
MarkdownToHTML, TranscriptTemplate, HTMLSanitizer, WebViewCensus) are **os.log /
unified logging**. They are gated by the system, bounded by the OS, and retrievable
via `log show`. **These are the model the file loggers should have followed.**
Record this explicitly so a future sweep does not "harden" them unnecessarily.

---

## 4. Required changes (implementation brief for Q)

### 4.1 `Sources/BeeChatGateway/GatewayClient.swift`
- Retain `BEE_DEBUG_LOG` gating and `BEE_DEBUG_LOG_PATH` override.
- **Add size bounding**: cap (default 1 MB) + truncate-to-last-N (default 256 KB),
  mirroring `BeeChatLogger`'s existing constants so there is one policy.
- Ensure the "bounded" claim in the header comment is **literally true**;
  if bounding cannot be guaranteed on a path, do not claim it.
- Build: `swift build --target BeeChatGateway` must pass.

### 4.2 `Sources/App/Utils/BeeChatLogger.swift`
- Remove `.desktopDirectory` default.
- Default path: home-relative, non-Desktop (`~/Library/Logs/BeeChat-diagnostics.log`).
- Gate writes on the shared flag; no-op when off.
- Retain serial queue + bounding.
- Update doc comment to reflect the real read path.
- **No changes to the ~40 call sites.** Sink-only change.

### 4.3 `Sources/BeeChatPersistence/Database/DatabaseManager.swift`
- **F7-resolved (round 1):** line 421 sits inside `Migration014_SeedClaudeOversightBookmark`
  (a **named, already-registered** migration, `DatabaseManager.swift:409-425`,
  using `INSERT OR IGNORE`).
- **Decision (D3 final, updated by grok F7):** **stop seeding AND add a targeted
  cleanup migration** that deletes the **exact** seeded row (matched by its path
  literal), so existing DBs stop carrying the dead Desktop path. Guard the delete
  to that exact row so no other bookmark is touched. *(Round 1 said "no migration";
  round 2 correctly notes removal-only-in-fresh-DBs leaves every shipped DB with
  the dead row — a targeted exact-match delete is the right fix.)*
- **Do NOT derive at runtime** (that reintroduces the Desktop dependency).
- **Risk check (grok F7):** verify no caller `try!`s / force-unwraps a missing
  bookmark folder. Verified: the only `fatalError` is app-support-dir creation
  (`AppRootView.swift:236`) — unrelated. No folder-path force-unwrap found.
- `swift test` for BeeChatPersistence must pass (existing migration tests).

### 4.6 Sink inventory (grok F5) — beyond the 3-site grep

The spec must **name and check** the sinks a naive `grep "/Users/"` misses.
Verified present/absent at HEAD `32afd4e`:

| Potential sink | Status (verified) |
|---|---|
| `URLSession` `EventMonitor` / `cURLDescription` | **ABSENT** — `WebSocketTransport` uses a plain `URLSession` with a WS delegate, no monitor (F5) |
| GRDB `.trace` | **ABSENT** — no `trace` config found |
| `os_log` `%{public}` on sensitive args | **NONE FOUND** — 9 `Logger(subsystem:)` sites, no `%{public}`/`os_log` with sensitive args |
| Crash reporters (Sentry/Crashlytics/signal handlers) | **ABSENT** — none found |
| Transcript / summary writers | **PRESENT** — `TopicSummaryWriter.swift:393`, `ProjectScaffolder.swift:113` write files (not logs; review for path/content safety) |

**Note:** "ABSENT" here means "not found by the searches run" — the implementer
must re-verify with the same named checks and record the result (AC-17).

### 4.4 Shared policy (new) — the class-closing change
- Introduce a **single small shared bounded-file-writer** used by both sinks
  (F10: less code than two separate bounding implementations; **do not build a
  logging framework**).
- Document as `Docs/Status/LOGGING-STANDARD.md` (or a section in PROCESS.md):
  - **No hardcoded absolute paths** in code, seeds, or migrations.
  - **No always-on file logging** — every file sink is gated by default-off.
  - **Every file sink is bounded** (size cap + rotation) — non-negotiable.
  - **Prefer `os.log`** (`Logger(subsystem:category:)`) for diagnostics; file
    sinks are the exception, requiring a justification comment. **(F12)**
    **Mirror all logs to os.log unconditionally**; the file write is the only
    gated part — so diagnostics are never wholly lost.
  - **Sensitive data (F9, widened):** no tokens/secrets **and no user message
    content or PII** in log lines. The 42 `BeeChatLogger` call sites in
    `ComposerViewModel`/`MessageViewModel` must be treated as candidate content
    leaks and reviewed.

### 4.5 Build guards (the durable mitigation) — redesigned per F4/F5/F6/F11/R2

> **Round-2 caution (grok F3/F4, accepted):** textual greps are **supporting**, not
> the class control. The **behavioural size/rotation test (AC-5) is the control** —
> a grep can be defeated by `urls(for:.desktopDirectory)`, split literals, or an
> allowlist that swallows a whole file, and a constant-assertion (G2-as-originally)
> and a grep (G3-as-originally) can both be signed **without the write path
> changing**. Each guard below therefore includes its **failure-mode test**.

Guards live in a **non-app-hosted Swift test target** (F11) and **fail if they scan
zero files** (F11 / AC-12).

- **Guard G1 (redesigned, F4):** scan `Sources/**/*.swift` for hardcoded
  **user-specific absolute paths**, allowing the legitimate forms by **exact
  literal/content**, **never by file** (a per-file allowlist would let new defects
  into already-allowlisted files). The defect pattern is `/Users/<name>/…` — i.e.
  flag `"/Users/[^/"]+/`; do **not** flag bare `"/Users/"` (the legitimate
  regex/validation prefix, §3.5). **Additional required rules (grok F3):** flag
  `urls(for: .desktopDirectory)` and `"Desktop"` path components in non-UI code
  (sink 2 used `.desktopDirectory`, which contains no `/Users/` literal at all);
  flag **split/concatenated** literal fragments that reassemble to an abs path;
  **fail on an empty scan** (AC-16).
  - Allowlist is reviewed explicitly (R3), justified **per literal**, and its
    size is asserted (so it cannot silently grow to swallow the codebase).
  - **Known limit (documented):** arbitrary runtime concatenation evades a literal
    scan — G4/policy cover that by intent; the behavioural test is the backstop.
- **Guard G2 (made behavioural, F5/F4):** **not** a constant comparison (vacuous —
  it passes when the constant is never used on the write path, which is exactly how
  sink 1's false "bounded" comment arose). Instead: inject a temp directory, write
  **more than the cap**, and assert the file size and rotated-file count stay within
  limits. **This behavioural test is the class control (AC-5/AC-16).**
- **Guard G3 (F6):** assert file loggers default to **disabled** when the gate is
  off — with **injectable gate config** (a `static let` read once cannot be tested).
  The test sets the gate off under a **temp HOME** and asserts **no file** is created.
- **Guard G4 (from §6.1):** assert no logger receives the encoded handshake frame
  or any token-bearing value. Mandatory.
- **Mutation requirement (standing correction):** each guard must be shown to
  **fail when the defect is reintroduced**, with a **recorded red run**. The
  reviewer (Kieran), not the builder, produces the red run. **G4's mutation test is
  highest priority: it must fail when line 579 is restored to logging `text`.**

---

## 5. Risks

| ID | Risk | Mitigation |
|---|---|---|
| R1 | `BEE_DEBUG_LOG` gating silently disables diagnostics someone needs | `print()`/os.log retained unconditionally; document how to re-enable |
| R2 | D3 seed change alters existing shipped DBs | Migration must be additive; verify against a real DB copy before merging; Kieran checks |
| R3 | Guard G1 false-positives on legitimate absolute paths | Allowlist with justification comments; review the allowlist explicitly |
| R4 | Sink-only change to `BeeChatLogger` still leaves ~40 call sites doing work when off | Acceptable (a no-op function call is cheap); measure, don't assume |
| R5 | Shipping the fix changes the running app Adam uses | Release via PROCESS.md deploy checklist with smoke test; rollback = previous .app backup |

---

## 6. Security / privacy

### 6.1 Sink 1 — credential-logging RISK (verified: the code path CAN log a token; evidence shows the current file does NOT contain one)

**Verified at HEAD `32afd4e`.** Two separate claims, and they have different
status — keep them distinct:

**(a) The code path is dangerous — CONFIRMED.**
- `GatewayClient.swift:579` — `debugLog("Sending handshake: \(text.prefix(500))")`
- `text` is the JSON-encoded `RequestFrame(method: "connect", params:)`
- The params are built with `auth: .init(token: config.token, deviceToken:
  currentDeviceToken)` (see `ConnectParams` construction, lines ~523/557)
- **Therefore the code, if that line executes, writes the first 500 chars of the
  handshake — which include `token` and `deviceToken` — to the log file.** That is
  a latent credential-logging defect. It must be fixed regardless.

**(b) Whether a secret was ever written to disk is UNVERIFIABLE — the file was truncated.**

Initial reading (now corrected): I inspected the live file (~32 KB, 582 lines then)
and found **zero** `token`/`auth`/`secret`/`bearer`/`handshake`/`connect`/
`deviceToken`/`password` strings; every line was `handleEvent — event=<name>`.
I wrongly concluded "no leaked secret." **That conclusion is unsound**, for three
reasons (all raised by grok's round-2 review):

1. **Path (a):** the file I read (`~/Desktop/BeeChat-debug.log`) **is** the one the
   running binary opens — verified two ways: the Aug-7 binary's `debugLog`
   hardcodes `"/Users/openclaw/Desktop/BeeChat-debug.log"` (`git show
   937e18b:…/GatewayClient.swift:5`), and `strings` on the installed binary emits
   that exact path. The post-fix `~/Library/Logs/…` path is **absent** (fix not
   shipped). So paths match — but that does **not** rescue the read (see 2).
2. **Truncation (b):** the file's **birth is 10:02:24** (app launch) but its
   **oldest surviving line is 13:49:53**. The file was **truncated in place at
   ~13:49** — the entire pre-13:49 content (including the connect/handshake events
   from app launch) is **gone**. `grep` on the current file finds **zero**
   `connect`/`handshake` lines *because they were truncated away*, not because
   they never happened. **The clean read clears nothing.** I cannot inspect the
   pre-truncation bytes.
   - **Cause of truncation: UNEXPLAINED.** No process holds the file open
     (`lsof` empty); the Aug-7 binary has **no rotation**; I performed no such
     action. Best (unverified) candidate: the system canary's repetition detector
     — the commit says the loop was "caught by the system canary's repetition
     detector," which may have truncated/rotated the file. **Recorded as an open
     unknown, not explained away.**
3. **Handshake firing (c):** line 579 *did* fire — the binary contains the
   `Sending handshake:` string, and a connect occurs at app launch. Those lines
   were in the pre-truncation content. **This is why 579 "never appeared" post-fix:
   it fired once at connect (~10:02), inside the truncated region.**

**Therefore the token question cannot be closed either way:** the code path can
write the token (confirmed), and whether it did is **forever unverifiable** on this
log, because the evidence was truncated.

> ⚠️ **Consequence — reversal of my earlier call:** I previously wrote "no token
> rotation required on current evidence." **That conclusion does not hold.** The
> evidence is not merely absent — it was destroyed by truncation. The correct
> posture is **assume-possibly-exposed → rotate the gateway token** as cheap
> insurance. **This is the safe call, and it is Adam's to make.** It supersedes the
> earlier "no rotation" line.

**Net finding:** this is a **latent** credential-logging defect, **and** disk
exposure **cannot be ruled out** because the log was truncated (§6.1b). Treat as
**possibly exposed** — fix line 579 **and** rotate the token (Adam's call).

> **Correction history (2026-09-24):** revision 1 asserted a "confirmed leak"
> (unsupported — asserted about a file I hadn't read). Revision 2 asserted "no
> leak, no rotation" (unsound — read a *truncated* file and generalised). Revision
> 3 (this one) states the defensible position: **latent defect confirmed; disk
> exposure unverifiable; rotation prudent.** Three passes, each caught by a
> different reviewer/check — recorded because it is the exact failure class this
> project keeps hitting: *a claim about evidence, made without establishing that
> the evidence is complete.*

**Required change (still required):**
- **Never log the handshake frame.** Remove or redact line 579; if the diagnostic
  is still wanted, log only non-secret fields (method, frame id, lengths).
- **Guard G4** (§4.5) — added and mutation-tested. Prevents the class.
- **Token rotation:** **recommended** (assume-possibly-exposed — §6.1b, evidence
  truncated). **Adam's call.** Supersedes the earlier "not required" line.
- **Delete the stale Desktop logs** — routine cleanup **and** because they are
  the only place a leaked secret could be; verify deletion.

**Confidence: high** on both (a) and (b) — each verified from source/file directly.

### 6.2 General log-hygiene requirements

- Logs must not be world-readable. Verify file permissions on creation.
- Removing Desktop sinks reduces accidental exposure of app internals in a
  user-visible location.

---

## 7. Acceptance criteria (verifiable)

**AC-1** `swift build --target BeeChatGateway` passes at the fix commit.
**AC-2** `swift test` (full suite) passes; no new failures; keychain-hang tests excluded as documented.
**AC-3** `grep -rn "/Users/openclaw/Desktop" Sources/` returns **zero** hits.
**(Narrowed from "all /Users/" — 22 legitimate hits remain by design; see §3.5.)**
**AC-4** With `BEE_DEBUG_LOG` **unset**, running the app writes **no** file to
  `~/Library/Logs/` and **no** file to `~/Desktop/`. (Behavioural test.)
**AC-5** With `BEE_DEBUG_LOG=1`, the file is created **and** stops growing at the
  cap (bounded) — demonstrated by writing > cap and observing rotation.
**AC-6** Guard G1 fails when a `/Users/...` literal is re-added (mutation test).
**AC-7** Guard G3 fails when a logger is made always-on (mutation test).
**AC-7b** Guard G4 fails when the handshake frame is restored to the log call
  (mutation test); and shipped code contains **no** path writing `config.token`
  or `currentDeviceToken` to a file.
**AC-8** The installed `/Applications/BeeChatApp.app` binary is **dated after the
  fix commit** and, in a live run, produces **no** `~/Desktop/BeeChat-debug.log`
  growth and **no** `~/Desktop/BeeChat-diagnostics.log` writes.
**AC-8b** The stale Desktop logs are **deleted** as routine cleanup once the fixed
  build is live (not a leak response — §6.1b).
**AC-11 (NEW)** The `GatewayClient` header comment's claim about bounding is
  **literally true** (or removed) — no comment asserts a safety property the code
  lacks (the exact failure that hid sink 1).
**AC-12 (NEW)** Guard test **fails if it scans zero source files** (vacuous-pass
  guard), and lives in a **non-app-hosted** test target.
**AC-13 (NEW)** With the gate disabled, **no** file is created under a temp HOME
  (behavioural, injectable config — not `static let`).
**AC-9** `Docs/Status/STATUS.md` build-history table has a row for the fix build.

**AC-14 (NEW, grok F1 — operational acceptance):** a **scripted operational check**
  proves the leak is stopped, independent of branch choice:
  (i) old app pid **quit**; (ii) fixed build **installed**; (iii) both Desktop logs
  **removed/truncated**; (iv) **live, size must stay flat over a scripted session**
  (measure > 5 min with a message round-trip; delta ≈ 0). *Branch choice does not
  stop the leak — only replacing the running binary does.*
**AC-15 (NEW, grok F2 — merge guard):** `feat/transcript-integration` is verified to
  contain the **bounded** hotfix sink **before** it merges — i.e. the hotfix is
  canonical and the feature branch takes it, **not vice-versa**. If `32afd4e`
  (gated-but-uncapped) would win the merge, that is a **release blocker**.
**AC-16 (NEW, grok F3):** G1's textual scan is **not** the class control by itself —
  the **behavioural size test (AC-5) is.** G1 additionally flags
  `urls(for:.desktopDirectory)`, split/concatenated literals, and **fails on an
  empty scan.** Empty-scan and allowlist-swallowing are tested explicitly.
**AC-17 (NEW, grok F5):** the sink inventory explicitly covers the 3-site grep's
  blind spots — `URLSession` `EventMonitor`/`cURLDescription`, GRDB `trace`,
  `os_log %{public}` on sensitive args, crash reporters, and the transcript
  writers — **confirmed present or confirmed absent**, each by name.
**AC-18 (NEW, grok F7):** sink 3 — a **targeted migration deletes the exact seeded
  row** (by path literal), guarded so it cannot affect other bookmarks; and no
  caller `try!`s a now-missing folder (verified: the only `fatalError` is for app
  support dir creation, `AppRootView.swift:236` — unrelated).

**Evidence rule E5:** the implementer (Q) may not sign their own ACs. Kieran
verifies AC-3, AC-6, AC-7, AC-7b, AC-8, AC-8b, AC-10, AC-11, AC-12, AC-13,
AC-14, AC-15, AC-16, AC-17, AC-18 independently, **and records a red run for
every guard with the defect reintroduced.**

---

## 8. Delivery plan (PROCESS.md standing workflow)

1. **Bee writes spec** ← this document.
2. **Kieran + Q validate spec is sound** (round 1 — reconciled §12; round 2 — reconciled §12b).
3. Reconcile findings → SOUND (or SOUND WITH FIXES) → re-review if significant.
   **Round 3 required:** grok reviewed the *brief*, not the spec — re-run with the
   spec **attached** (`Projects/AgentDrop/briefs/loghardening/SPEC.md`).
4. **Dispatch to Q to build** on a branch **from `origin/develop`** (see §9 — the
   fix is currently on `feat/transcript-integration`, which is **not** the correct base).
5. **Kieran checks the work** against ACs (E5).
6. **Bee validates** before returning to Adam.
7. **Operational acceptance (grok F1, AC-14):** quit old pid → install fixed build →
   remove both Desktop logs → **prove flat size over a scripted session.** This runs
   **regardless of branch choice** — it is what actually stops the live leak.
8. **Fable/Claude super-check** — MANUAL, only if this counts as a milestone
   (Adam decides; likely yes given it touches the release path).
9. Merge → `origin/develop` → `main` per PROCESS.md; deploy checklist; smoke test.
   **Merge guard (AC-15):** the feature branch takes the bounded hotfix sink.

---

## 9. Branch / release decision (the thing that determines shipping)

**Current topology (verified):**
- `main` = `381dec9` (does **not** contain the logger fix)
- `feat/transcript-integration` = `32afd4e` (54 commits ahead of main; contains
  the fix **plus** all in-flight Option B transcript work)
- **`develop`:** there is **no local `develop`** — `remotes/origin/develop` exists;
  the local integration branch is `develop-v0.9.5d-whitespace`. **F3a — real hole.**
  Base the hotfix on **`origin/develop`** and **record its exact SHA at cut time.**

**Decision required:** the logger fix is **orphaned** on a 54-commit-deep feature
branch. Two options:

- **Option A — hotfix branch off `origin/develop`.** Re-author the logger fix
  (+ D2, D3) onto a short-lived `fix/log-hardening` branch, build, review, ship.
  **Ships this week, independent of Option B.** ← **Recommended.**
- **Option B — carry it with transcript-integration.** Waits for the entire
  Option B programme to merge. Unacceptable for a live multi-MB/day leak.

**F3c — reconciliation rule (adding):** the hotfix is **canonical**. When
`feat/transcript-integration` eventually lands, it **rebases/merges onto the
hotfix** in `GatewayClient.swift` — **not the other way round.** The feature
branch must not re-introduce the un-gated logger.

**F3b — install step (adding):** the fix only takes effect when
`/Applications/BeeChatApp.app` is **rebuilt and replaced** (PROCESS.md deploy
checklist). Committing is not shipping.

**F3d — interim mitigation (today):** the Desktop log is still growing on the
running pre-fix app. Until the fix ships: **truncate the Desktop log(s)** and/or
quit the running app. (Low urgency — the file is ~32 KB and bounded in practice
by the app session, not genuinely unbounded; see F2.)

**PROCESS.md rule 1:** "All work goes on a branch from develop." The fix currently
violates the intent of that rule (it lives on a feature branch). Option A restores
compliance.

---

## 12. Review round 1 — reconciliation (2026-09-24)

**Reviewer:** claude (external, via AgentDrop thread `beechat-loghardening-review`).
**Verdict:** CORRECTIONS REQUIRED. **Caveat it stated:** it reviewed the *brief*,
not the full spec, and not the code — which explains finding 1 (below).

Findings reconciled against the repo (verified, not assumed):

### Accepted — spec modified

| # | Finding | Resolution |
|---|---|---|
| **F3a** | No `develop` branch established for the hotfix base | **Confirmed real.** No local `develop`; `remotes/origin/develop` exists; local integration branch is `develop-v0.9.5d-whitespace`. **§9 updated: hotfix branches from `origin/develop`; state the exact base SHA at cut time.** |
| **F3b** | Spec needs an explicit install step | **Accepted.** §9 + execution brief now include the PROCESS.md deploy step (install to `/Applications`). |
| **F3c** | Reconcile `32afd4e` (feature branch) vs the hotfix — conflict in `GatewayClient.swift` | **Accepted.** §9 now states: **the hotfix is canonical; `feat/transcript-integration` merges/rebases onto it, not the reverse.** |
| **F3d** | Interim mitigation for today (log still growing) | **Accepted.** §9 adds an immediate interim step. |
| **F4** | G1 can be bypassed (per-file allowlist) / misses Desktop half | **Accepted — G1 redesigned.** Allowlist by **exact literal** not file; pattern narrowed to `/Users/<name>/` (not bare `/Users/`); add a Desktop-component / `.desktopDirectory` rule for non-UI code; document the concatenation limit. |
| **F5** | G2 vacuous as specified | **Accepted — G2 made behavioural.** Inject temp dir, write > cap, assert size + rotation count. |
| **F6** | G3 depends on environment / `static let` not testable | **Accepted.** Require injectable gate config; test sets gate off under a temp HOME and asserts no file. |
| **F7** | Sink 3 mis-framed: dropping seed only affects fresh DBs; cleanup migration risks deleting real user data | **Accepted — resolved with fact.** `DatabaseManager.swift:409-425` is `Migration014_SeedClaudeOversightBookmark`, a **named, already-registered migration** using `INSERT OR IGNORE`. Decision: **stop seeding (edit the migration body); do NOT add a cleanup migration; do NOT derive at runtime** (deriving reintroduces the Desktop dependency). Existing rows stay as user data. Note: editing an already-applied migration diverges fresh installs from upgraded ones — **acceptable, and now stated.** |
| **F8** | Several ACs unverifiable / self-signable | **Accepted.** Split guidance from ACs; mutation evidence must be a **recorded red run by Kieran**; add AC that the `GatewayClient` header comment is accurate; shipping verified observably by a non-implementer. |
| **F9** | "No secrets" too narrow — 42 call sites may log message content | **Accepted.** Policy §4.4 extended to **user content + PII**, not only secrets. |
| **F11** | Test-target traps (sandbox can't read source; zero-file vacuous pass) | **Accepted.** Guard must live in a **non-app-hosted test target** and **fail if it scans zero files.** |
| **F12** | Sink-only change risks: readers of the file; default-off leaves no diagnostics | **Accepted.** Verified: **no reader exists in source** (grep clean) — risk cleared. Adopt: **mirror all logs to os.log always**; file write only when gated. |
| **F10** | One shared bounded file-writer, not a framework | **Accepted.** §4.4: one small shared writer used by both sinks. |

### Rejected — with reason

| # | Finding | Why rejected |
|---|---|---|
| **F1** | BLOCKER: "the handshake log **likely leaks** a credential… treat the logs as **possibly** credential-bearing: **rotate the token**" | **Already corrected before this verdict arrived.** The reviewer's own caveat ("brief only, not the spec") explains it — it reviewed my pre-correction addendum. I inspected the live log directly: **zero** token/auth/handshake strings; every line is `handleEvent — event=<name>`. Correct finding: **latent code defect (line 579 CAN log the frame) — confirmed; file contains no secret — verified.** Fix required; **rotation not required on current evidence.** The reviewer's *recommendation to log only method/id/length* is **accepted and already in §6.1.** Note: it did not have the file; its inference from code shape was reasonable, and its "I need lines 540-600" request is the right instinct. |
| **F2** | MAJOR: "gating hides the loop; is the root loop fixed?" | **Partially rejected — verified.** The "loop" is legitimate reconnection: `GatewayClient.swift:603-607` has a **bounded `retryCount` with `backoff.delay`**. The 10 MB/hour came from `debugLog` firing **per WS frame event** (617 event lines observed), not from a runaway loop. So there is **no separate loop defect to track.** Accepted sub-point: the spec should **say so explicitly** — now §1. |

**Net:** reviewer verdict CORRECTIONS REQUIRED → after reconciliation,
**SOUND WITH FIXES**, all fixes applied above. F1 dissolved on evidence (not
overridden); F2 clarified; F3–F12 accepted and applied.

---

## 12b. Review round 2 — reconciliation (grok, 2026-09-24)

**Reviewer:** grok (external, AgentDrop thread `beechat-loghardening-review`).
**Verdict:** CORRECTIONS REQUIRED, 9 findings.
**⚠️ Scope failure (recorded):** grok **never saw the spec** — it lives at
`projects/BeeChat-v5/…`, **outside the reviewer's `read_root`
(`Projects/AgentDrop`)**, and the brief said "no local file access." So grok
reviewed the *brief's account*. **Fixed:** spec + code excerpts now staged under
`Projects/AgentDrop/briefs/loghardening/` and attached. **"Naming isn't granting."**
Findings 1–4 to be re-checked against the actual spec text in round 3.

| # | Finding | Resolution |
|---|---|---|
| **F1** BLOCKER | Branch choice doesn't stop the leak; the **running** app (2026-08-07) still writes. Need an operational acceptance check. | **Accepted.** New **AC-14**: quit old pid, install fixed build, remove both Desktop logs, **prove flat size over a scripted session.** Verified the leak is live (log grew ~5 KB / 10 s during this session). |
| **F2** MAJOR | Merge hole: `32afd4e` is gated-**but-uncapped**; it can win the merge and delete the hotfix trim. | **Accepted.** New **AC-15**: feature branch must take the bounded hotfix sink; `32afd4e`-wins = release blocker. §9 rule reinforced. |
| **F3** | G1 abs-path grep is theatre (`.desktopDirectory`, split literals, allowlist swallowing, vacuous empty scans); behavioural size test is the class control. | **Accepted.** §4.5 rewritten: behavioural test = control; G1 adds `.desktopDirectory`/split-literal rules + empty-scan failure; allowlist size asserted (AC-16). |
| **F4** | G2-as-constant + G3-as-grep are **signable without the write path changing**. | **Accepted.** Both made behavioural/injectable (§4.5). |
| **F5** | 3-site search misses sinks: `URLSession` EventMonitor/`cURLDescription`, GRDB `trace`, `os_log %{public}`, crash reporters, transcript writers. | **Accepted — verified each.** New **§4.6** inventory + **AC-17**. (All named sinks verified present/absent at HEAD.) |
| **F7** | Sink-3 removal stops **new** seeds only; needs a **targeted migration** deleting the exact row; risk if a caller `try!`s a missing folder. | **Accepted.** §4.3 updated: targeted exact-match delete migration; **verified** no folder-path force-unwrap (only `AppRootView.swift:236`, unrelated). New **AC-18**. |
| **F9** | PII/content scope (round-1 F9 carried). | Already covered (§4.4). |
| **F8** | AC verifiability. | Already covered (AC-11…13). |
| **token** | grok **agrees** with the latent-not-leak framing, but demands 3 gaps closed: (a) path read vs path opened; (b) reconcile 2.27 MB / 10 MB-hr / 32 KB; (c) why 579 never appeared on the Aug build. | **Accepted — all three closed, and they REVERSE my "no rotation" call.** (a) paths match (Aug binary hardcodes the Desktop path; `~/Library/Logs` absent). (b) the file was **truncated at ~13:49** (birth 10:02:24, oldest line 13:49:53) — so my clean read **clears nothing**; cause of truncation **unexplained** (best candidate: the canary). (c) 579 **did** fire — at connect (~10:02) — inside the truncated region. **Net: exposure unverifiable → rotation RECOMMENDED** (§6.1b), reversing round-1. |

**Net:** CORRECTIONS REQUIRED → **SOUND WITH FIXES** after this reconciliation.
The most important outcome is **not** the guards — it is that grok's evidence
challenge **reversed my earlier "no rotation" conclusion**, and that the review
**never actually read the spec** (now fixed). Both recorded rather than smoothed over.

---

## 13. Open questions for validation

- **OQ-1:** D3 — *(RESOLVED round 2)*: stop seeding **and** add a targeted
  exact-match delete migration.
- **OQ-2:** Should `BeeChatLogger`'s console `print` be retained when the file sink
  is off, or fully silenced? (Leaning: retain behind the flag; silence the default.)
- **OQ-3:** Does the guard live as a Swift test, or as a script in `scripts/` run
  by the deploy checklist? (Leaning: Swift test — it runs with `swift test` and
  cannot be skipped.)
- **OQ-4:** Is this a Fable milestone (§8 step 7)? (Leaning: yes — release-path change.)
- **OQ-5 (NEW, round 2):** **Rotate the gateway token?** (§6.1b) — my call now is
  **yes, prudent** (evidence truncated, exposure unverifiable). **Adam decides.**

---

## 11. Traceability

| Item | Cite (HEAD `32afd4e`) |
|---|---|
| Sink 1 fix | `Sources/BeeChatGateway/GatewayClient.swift:5-35` |
| Sink 1 unshipped | `git branch --contains 32afd4e` → only `feat/transcript-integration` |
| Sink 2 | `Sources/App/Utils/BeeChatLogger.swift:10-27` |
| Sink 2 call sites | `grep -rn BeeChatLogger Sources/` → **42 hits, 4 files** (re-verified) |
| Sink 3 | `Sources/BeeChatPersistence/Database/DatabaseManager.swift:421` |
| Correct sinks | `grep -rn 'Logger(subsystem:' Sources/` → 9 hits (os.log) |
| `/Users/` surface | `grep -rn "/Users/" Sources/` → **25 hits, 10 files** (3 defects, 22 legitimate) |
| Governing process | `Docs/Status/PROCESS.md` |
| Live symptom | `~/Desktop/BeeChat-debug.log` 2.27 MB mtime 2026-09-24 13:10 |
| Live symptom | `~/Desktop/BeeChat-diagnostics.log` 64 KB mtime 2026-09-24 13:48 |
| Running binary | `/Applications/BeeChatApp.app` binary dated 2026-08-07 (pre-fix) |
