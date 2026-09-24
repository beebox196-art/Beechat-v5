# LOG-HARDENING — Execution Brief (Telegram channel)

**Task:** T-BEECHAT-LOGGING-HARDENING
**Spec:** `Docs/Specs/Active/LOG-HARDENING-SPEC.md` (repo `/Users/openclaw/projects/BeeChat-v5/`)
**Tier:** Standard · **Routing:** MODE `graph` (gate integrity `8baf879b…`)
**Status:** SPEC written, cites verified, **review rounds 1–3 reconciled** (claude + grok, AgentDrop `beechat-loghardening-review`). All three returns were CORRECTIONS REQUIRED → **SOUND WITH FIXES** (§12, §12b, §12c, §12d, §12e). **Round 3 (both reviewers, spec attached)** found two defects my spec had wrong: a **second sink** (line 279 URL) and that **the fix still `print`s the token**. Two reviewers found the same second sink independently — strongest signal in the exercise.

**Highest-impact outcome:** the live gateway token (and a device token) are **confirmed on disk** (hash-verified, §6.1b); **rotation + device re-pair REQUIRED**.

**New ACs 14–20** (operational acceptance incl. the **archive dir**; merge guard; guard anti-theatre; sink inventory; targeted migration; archive purge; token rotation + device re-pair).

---

## Why this exists

Adam asked what happened to the BeeChat debug/diagnostics log and whether it needs
a formal coding process. Findings:

1. **The debug logger was fixed but never shipped.** Commit `32afd4e` (2026-09-24)
   disabled the hardcoded Desktop logger, but it lives only on
   `feat/transcript-integration`. `main` (`381dec9`) does not contain it. The
   **running** `/Applications/BeeChatApp.app` is dated 2026-08-07 — pre-fix.
2. **A second logger was missed** — `BeeChatLogger.swift` writes unconditionally to
   `~/Desktop/BeeChat-diagnostics.log` from 42 call sites.
3. **A third sink** — `DatabaseManager.swift:421` hardcodes a Desktop path into the DB.
4. **A latent credential-logging defect** — `GatewayClient.swift:579` logs the
   handshake frame (carries token + deviceToken). *Not a proven leak; the log file
   contains no secret. Fix required regardless.*

**Yes, this needs the formal process.** Two of the three defects are in the
release path, and the class has already recurred once.

---

## What Adam does via Telegram

The whole job can be driven from Telegram. Suggested sequence:

### Step 1 — Read the review verdicts
The Kieran + Q validation is already dispatched (AgentDrop thread
`beechat-loghardening-review`). Ask Bee: *"what did the log-hardening review say?"*
Bee reconciles findings into the spec → **SOUND** or **SOUND WITH FIXES**.

### Step 2 — Approve the branch decision (§9)
The spec recommends **Option A: hotfix branch `fix/log-hardening` off `develop`**,
shipping this week, independent of the Option B transcript work.
Say: *"Go with Option A, dispatch Q to build."*

### Step 3 — Q builds
Q implements §4 (all four sinks + shared policy + guards G1–G4), on
`fix/log-hardening`, per `Docs/Status/PROCESS.md`.
Deliverable: build passes, guards written, mutation tests shown failing when the
defect is reintroduced.

### Step 4 — Kieran verifies (E5 — implementer can't sign own work)
Kieran checks AC-1 … AC-10 independently, especially:
- AC-3 (zero `/Users/openclaw/Desktop` hits)
- AC-6 / AC-7 / AC-7b / AC-10 (mutation tests actually fail when defect restored)
- AC-8 (`/Applications` binary dated after fix, no Desktop writes in a live run)

### Step 5 — Bee validates, then deploy
Per PROCESS.md deploy checklist: `swift build -c release`, `swift test`,
increment CFBundleVersion, ad-hoc sign, install, relaunch, STATUS.md row, smoke test.

### Step 6 — Cleanup
Delete the stale Desktop logs (`BeeChat-debug.log`, `BeeChat-diagnostics.log`) —
routine cleanup. Update `Docs/Status/LOGGING-STANDARD.md` (new).

### Step 7 — Milestone? (Adam decides)
If this counts as a milestone, Bee writes the Fable/Claude super-check `.md` prompt
for Adam to paste manually (PROCESS.md standing workflow, step 6).

---

## Decisions Adam may need to make

| # | Decision | Spec default |
|---|---|---|
| D-branch | Option A (hotfix off origin/develop) vs Option B (wait for transcript-integration) | **A** |
| OQ-1 | Sink 3: derive path at runtime, or drop the seed row | **stop seeding + targeted delete migration** |
| OQ-4 | Is this a Fable milestone | leaning **yes** |
| OQ-5 | **Rotate the gateway token?** | **YES — confirmed leak** (5 files, 44 occ, hash-verified) |
| OQ-6 | **Purge token-bearing archives?** | **YES** — `~/.openclaw/logs/beechat-debug-archive/` (destructive → needs your OK) |
| OQ-7 | **Re-pair the device token?** | leaning **yes** unless the handshake prefix excludes it |

**Rotation order (grok R3-4):** rotate the gateway token **after** the Aug binary is
  dead and the replacement neither logs nor prints the URL/token. **R3-1:** the
  current fix **still `print`s the token** before the gate — the fix must redact
  *before* the print.

**New operational step (grok F1 / AC-14) — required regardless of branch choice:**
quit the old app pid, install the fixed build, remove **both** the Desktop log **and**
`~/.openclaw/logs/beechat-debug-archive/`, and **prove the log size stays flat over a
scripted session** with **no new token-bearing file** in either location. Branch choice
does not stop the live leak; only replacing the running binary does.

---

## Current state (what's already done)

- ✅ Spec written + committed (`91758e9`, `d762160`, `1ba346a`)
- ✅ All line cites verified against HEAD `32afd4e`
- ✅ Routing gate recorded + verified fresh
- ✅ Kieran + Q validation dispatched (AgentDrop `beechat-loghardening-review`)
- ⏳ Awaiting verdicts
- ❌ Nothing built, nothing merged, nothing shipped — **held for Adam**

---

## Non-negotiables (from the standing corrections)

- **No future-time commitment without a job ID.**
- **Mutation-test every guard** — a guard that can't distinguish "rejected" from
  "absent" is not a guard.
- **Re-read every cited line against HEAD before folding.**
- **Pin verification to a revision** (`git show HEAD:<file>`), not a report.
- **No config/branch changes without Adam** — this brief is the handoff; Bee does
  not merge to `main` unilaterally.
