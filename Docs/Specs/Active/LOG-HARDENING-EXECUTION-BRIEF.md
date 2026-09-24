# LOG-HARDENING — Execution Brief (Telegram channel)

**Task:** T-BEECHAT-LOGGING-HARDENING
**Spec:** `Docs/Specs/Active/LOG-HARDENING-SPEC.md` (repo `/Users/openclaw/projects/BeeChat-v5/`)
**Tier:** Standard · **Routing:** MODE `graph` (gate integrity `8baf879b…`)
**Status:** SPEC written, cites verified, **review round 1 reconciled** (claude via AgentDrop `beechat-loghardening-review`; verdict CORRECTIONS REQUIRED → **SOUND WITH FIXES**, §12). Second reviewer (grok) dispatched but its connector is backed up (93 queued) — not blocking.

**Reconciled:** 11 findings accepted & applied (F3–F12), 2 rejected on evidence (F1 latent-not-leak; F2 no runaway loop). Added AC-10…13, guard redesigns, `origin/develop` as hotfix base.

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
| D-branch | Option A (hotfix off develop) vs Option B (wait for transcript-integration) | **A** |
| OQ-1 | Sink 3: derive path at runtime, or drop the seed row | **drop the seed** |
| OQ-4 | Is this a Fable milestone | leaning **yes** |
| — | Token rotation? | **not required** on current evidence |

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
