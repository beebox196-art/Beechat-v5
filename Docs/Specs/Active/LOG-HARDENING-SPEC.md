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
| 1 | `GatewayClient.debugLog` | ~~`/Users/openclaw/Desktop/BeeChat-debug.log`~~ fixed | **none** | **yes** → now gated | **Code fixed, NOT shipped** |
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

### Why this matters

- **Sink 1** entered a loop-bug state on 2026-09-24 writing every WS frame event
  unbounded (~10 MB/hour, caught by the system canary). Diagnostic job complete;
  logging now off by default.
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
- Remove the hardcoded `/Users/openclaw/Desktop/...` seed literal.
- Either derive at runtime or drop the seed (decision at review, D3).
- If the row already exists in DBs, provide a migration to correct/remove it.
- `swift test` for BeeChatPersistence must pass (existing migration tests).

### 4.4 Shared policy (new) — the class-closing change
- Introduce a single source of truth for logging policy (constants + gating),
  so sinks 1 and 2 cannot drift apart again.
- Document as `Docs/Status/LOGGING-STANDARD.md` (or a section in PROCESS.md):
  - **No hardcoded absolute paths** in code, seeds, or migrations.
  - **No always-on file logging** — every file sink is gated by default-off.
  - **Every file sink is bounded** (size cap + rotation) — non-negotiable.
  - **Prefer `os.log`** (`Logger(subsystem:category:)`) for diagnostics; file
    sinks are the exception, requiring a justification comment.
  - **Sensitive data:** no tokens/paths/PII in log lines (see §6).

### 4.5 Build-time guard (the durable mitigation)
- Add a test (Swift test target, since there is no linter in the pipeline) that
  **fails if the class recurs**. Concretely, at minimum:
  - **Guard G1:** scan `Sources/**/*.swift` for hardcoded **user-specific absolute
    paths** and fail if found outside an explicit allowlist. **Critically:** the
    allowlist must include the ~22 legitimate hits in §3.5 (regex/validation/
    prefix constants). A naive `/Users/` matcher will false-positive on all of
    them. **Design the guard against the legitimate forms first** (standing
    correction: test a validator on the form it cannot see). Suggested precise
    matcher: flag **quoted string literals** beginning `"/Users/<name>/"` that
    are **not** inside a regex/prefix-constant context — review the allowlist
    explicitly (R3).
  - **Guard G2:** assert the two file loggers' bounding constants are ≤ the policy
    cap (pins the invariant by *assertion*, not comment).
  - **Guard G3:** assert file loggers default to **disabled** when the env flag is
    absent (i.e. `log()` performs no file write) — mutation-checkable.
- **Mutation requirement (standing correction):** each guard must be shown to
  **fail when the defect is reintroduced**. A guard that cannot distinguish
  "rejected" from "absent" is not a guard. Reviewer must confirm ≥1 test fails
  when the corresponding defect is temporarily put back.

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

- Confirm no log line writes the gateway **token** or device token. Sink 1 logs
  `Sending handshake: \(text.prefix(500))` (`GatewayClient.swift:579`) — **verify
  this cannot include a token.** If it can, redact before shipping.
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
**AC-8** The installed `/Applications/BeeChatApp.app` binary is **dated after the
  fix commit** and, in a live run, produces **no** `~/Desktop/BeeChat-debug.log`
  growth and **no** `~/Desktop/BeeChat-diagnostics.log` writes.
**AC-9** `Docs/Status/STATUS.md` build-history table has a row for the fix build.

**Evidence rule E5:** the implementer (Q) may not sign their own ACs. Kieran
verifies AC-3, AC-6, AC-7, AC-8 independently.

---

## 8. Delivery plan (PROCESS.md standing workflow)

1. **Bee writes spec** ← this document.
2. **Kieran + Q validate spec is sound** (round 1 review — dispatched with this spec).
3. Reconcile findings → SOUND (or SOUND WITH FIXES) → re-review if significant.
4. **Dispatch to Q to build** on a branch **from `develop`** (see §9 — the fix is
   currently on `feat/transcript-integration`, which is **not** the correct base).
5. **Kieran checks the work** against ACs (E5).
6. **Bee validates** before returning to Adam.
7. **Fable/Claude super-check** — MANUAL, only if this counts as a milestone
   (Adam decides; likely yes given it touches the release path).
8. Merge → `develop` → `main` per PROCESS.md; deploy checklist; smoke test.

---

## 9. Branch / release decision (the thing that determines shipping)

**Current topology (verified):**
- `main` = `381dec9` (main-only count 0; **does not contain** the logger fix)
- `feat/transcript-integration` = `32afd4e` (54 commits ahead of main; contains
  the fix **plus** all in-flight Option B transcript work, unmerged and untested
  for release)

**Decision required:** the logger fix is **orphaned** on a 54-commit-deep feature
branch. Two options:

- **Option A — hotfix branch off `develop`/`main`.** Cherry-pick / re-author the
  logger fix (+ D2, D3) onto a short-lived `fix/log-hardening` branch from
  `develop`, build, review, ship. **Ships this week, independent of Option B.**
  ← **Recommended.**
- **Option B — carry it with transcript-integration.** Waits for the entire
  Option B programme to merge. Unacceptable for a live 10 MB/hour-capable leak.

**PROCESS.md rule 1:** "All work goes on a branch from develop." The fix currently
violates the intent of that rule (it lives on a feature branch). Option A restores
compliance.

---

## 10. Open questions for validation

- **OQ-1:** D3 — derive path at runtime, or drop the seed row entirely? (Leaning:
  drop; a shipped app should not seed a favourite pointing at the author's Desktop.)
- **OQ-2:** Should `BeeChatLogger`'s console `print` be retained when the file sink
  is off, or fully silenced? (Leaning: retain behind the flag; silence the default.)
- **OQ-3:** Does the guard live as a Swift test, or as a script in `scripts/` run
  by the deploy checklist? (Leaning: Swift test — it runs with `swift test` and
  cannot be skipped.)
- **OQ-4:** Is this a Fable milestone (§8 step 7)? (Leaning: yes — release-path change.)

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
