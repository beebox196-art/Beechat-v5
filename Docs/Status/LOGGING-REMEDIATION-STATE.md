# BeeChat Logging Remediation — CURRENT STATE

**Last updated:** 2026-09-24 22:20 BST
**Task:** T-BEECHAT-LOGGING-HARDENING
**Status:** IN PROGRESS — first build attempt failed (wrong base), rolled back, rework starting

---

## 1. WHAT ADAM RUNS TODAY (the known-good app)

| Item | Value |
|---|---|
| Path | `/Applications/BeeChatApp.app` |
| Version | `0.9.5l` |
| CFBundleVersion | `2026.08.07` |
| Binary sha256 | `b92602befc722f507f17a9363768d7a0895b1b2c68e97b1fd2cb3c3183cdf9e8` |
| Binary mtime | Aug 7 13:59:46 2026 BST |
| State | ✅ Running, fully functional (confirmed by Adam 20:59) |

**Rollback bundle (verified byte-identical to the running app):**
`~/.openclaw/backups/beecchat-rollback-20260924/BeeChatApp.app.pre-loghardening`
Restore = quit app → copy bundle back to `/Applications` → relaunch. ~2 minutes.

---

## 2. WHERE THAT APP CAME FROM (provenance — established 2026-09-24 21:30)

**Source commit: `937e18b`** — "auto-backup: 2026-08-07 22:04:01 BST" on branch `feat/transcript-integration`.

Evidence chain (verified, read-only):
1. **Version match** — `VERSION` at `937e18b` = `0.9.5l`; the ONLY commit in all history at that version.
2. **Timestamp match** — binary built Aug 7 13:59; the source content of `937e18b` ends Aug 7 13:58.
3. **Ancestry** — `git merge-base --is-ancestor 381dec9 937e18b` = 0. `937e18b` = `main` **+ 50 commits**.
4. **Structural** — 99.92% symbol overlap with the running binary; identical embedded JS strings
   (`userScrolledUp`, jump-to-latest, day-boundary date headers, `transcriptEngine`).
5. **Defects present** — `Sending handshake` (GatewayClient.swift:569) and `desktopDirectory`
   (BeeChatLogger.swift:11) — confirms it is the correct PRE-fix base.

**Why not byte-identical when rebuilt:** Swift compilation is non-deterministic (randomised UUIDs,
hash seeds); `Package.resolved` is gitignored so transitive deps (SwiftSoup, GRDB) drift; worktree
vs source-tree path differs in DWARF. **Byte-equality is NOT an achievable gate** — see §5.

⚠️ **`937e18b` is an auto-backup commit.** It is the best provenance match available; the rework
builds from it. If a future exact-binary reconstruction is ever needed, this is the recorded starting point.

---

## 3. THE THREE LOGGING DEFECTS (what the job is for)

| # | Sink | Location | Effect |
|---|---|---|---|
| 1 | Hardcoded debug logger | `GatewayClient.swift` (~line 569) | Wrote every WS frame to a fixed Desktop path, unbounded (~10 MB/hr loop bug). **Also logs the handshake frame = gateway token + device token.** |
| 2 | `BeeChatLogger` | `Sources/App/Utils/BeeChatLogger.swift:11` | Writes to `~/Desktop/BeeChat-diagnostics.log` unconditionally, from ~42 call sites. |
| 3 | Seeded Desktop path | `DatabaseManager.swift:421` | Seeds `/Users/openclaw/Desktop/Claude Oversight Reports` into the DB (`Migration014`). |

**⚠️ CONFIRMED CREDENTIAL EXPOSURE (outstanding):** the live gateway token is on disk —
5 files in `~/.openclaw/logs/beechat-debug-archive/` (now 153 files total, growing while the
Aug-7 app runs). Local-scoped, not remote-reachable. **Not yet rotated or purged** (Adam's
decision: authenticate the replacement build first).

---

## 4. WHAT WENT WRONG ON THE FIRST ATTEMPT (2026-09-24 afternoon)

**The build was shipped off the wrong base.** Q built `fix/log-hardening` off `origin/develop`
(`682e701`) per the spec's "Option A". Installed as `BeeChat-V5.app`, swapped live → **UI regression**
(no message rendering on topic click, no jump-to-latest). Adam caught it in ~2 minutes; rolled back.

**Measured root cause:**
```
origin/develop (682e701)  = 2026-06-30   ← TWO MONTHS STALE (what we branched off)
main (381dec9)            = 2026-08-06
937e18b (the running app) = 2026-08-07
scroll-clamp fix c84a50f (Aug 4) in develop?  NO   ← the reason the UI broke
scroll-clamp fix c84a50f (Aug 4) in 937e18b?  YES
```
`origin/develop` is a stale June branch that does **not** contain the Aug-4 self-healing scroll
clamp — the fix that makes message rendering and jump-to-latest work. The branch *name*
("develop" = the integration line per PROCESS.md) was a lie about its *content*.

**The verified code work is NOT wasted.** The logging fix itself passed 3 independent verification
rounds (see §6). Only the *base* was wrong. The rework re-bases that work onto `937e18b`.

---

## 5. THE CORRECTION (recorded, so it cannot recur)

Full entries in `~/.openclaw/workspace/corrections.md` (2026-09-24 20:59 and 21:40);
standing one-liner in `~/.openclaw/workspace/AGENTS.md` §Standing corrections.

**Rule: prove the base is the DEPLOYED LINE by ancestry + version — a branch's name is not its content.**
- Gate: `git merge-base --is-ancestor <deployed-ref> <build-base>` returns 0 (base is a superset of
  what Adam runs) **AND** the base's `VERSION` matches the running app's reported version.
- Then `git diff <deployed-ref>..<base>` must show only the intended change's files.
- **Byte-equality of compiled output is NOT the gate** — unachievable for Swift (non-deterministic
  builds + gitignored `Package.resolved`). A gate that can never pass is not a gate.
- **Grep history for the running app's version string FIRST** — it identifies the source commit directly.
- Verification scope must include the *premise* (the base), not only the implementation. Two Kieran
  rounds passed last time because nobody checked the base.

---

## 6. VERIFIED CODE WORK (carried forward to the rework)

The logging changes are verified and sound; they just sit on the wrong base.

**Round 1** (`2a64c0a`) — full implementation. Kieran: CORRECTIONS REQUIRED (blocker F-1).
**Round 2** (`f32d14b`, `b48947a`) — F-1/F-2/F-3 fixed. Kieran: SOUND WITH FIXES (residual N-1).
**Round 3** (`1f0b3f1`, `cd102c8`) — N-1 fixed. Kieran: **SOUND (final)**.
  - Credential guard G4: 20/20 mutation RED, 8 sink assertions each
  - Clean tree: 75 runs, 0 false-REDs
  - No regressions: G1/G2/G3, AC-3 carve-out, Migration016 all pass
  - `swift build -c release` ✓ · `swift test` 164/1 skip/0 fail ✓

**Contents of the verified change:** four sinks remediated, a shared `BoundedFileLog`, `LOGGING-STANDARD.md`,
and guards G1–G4 (all mutation-proven load-bearing).

**These commits live on `fix/log-hardening` (off the WRONG base) — they must be re-based onto `937e18b`.**

---

## 7. THE REWORK PLAN (starting 2026-09-24 22:20)

1. **Q** — branch `fix/log-hardening-v2` off **`937e18b`**; carry ONLY the logging change.
   Evidence: `git diff 937e18b..fix/log-hardening-v2` shows logging files and nothing else.
2. **Kieran** — independently verify the **base ancestry** AND the diff scope (the gate that was missing).
3. **Gav / claude** — external adversarial read: "could this change touch UI?"
4. Adam smoke-tests the new build **side-by-side** (old app untouched as rollback).
5. Only after a verified working build is deployed: purge archives + Desktop logs, rotate gateway
   token, re-pair device token.

**Hard rule for this rework:** the new branch's diff vs `937e18b` must be *logging-only*. If any UI
file appears in the diff, stop.

---

## 8. HOUSEKEEPING LEDGER

| Item | State |
|---|---|
| Broken `/Applications/BeeChat-V5.app` | ✅ REMOVED (2026-09-24 21:03) |
| Q's scratch worktree `/tmp/beecchat-prov-937` | ✅ REMOVED (git worktree remove) |
| `/Applications/BeeChatApp.app` rollback | ✅ Intact, byte-unchanged |
| `~/.openclaw/backups/beecchat-rollback-20260924/` | ✅ Present |
| Archive purge / token rotation | ⏳ HELD for Adam (after working build) |
| STATUS.md build row (AC-9) | ⏳ Pending (on successful deploy) |
| AC-15 cherry-pick → `feat/transcript-integration` | ⏳ Pending decision |
| Scripts: `release.sh`, `build-and-install.sh` | ✅ Untouched |
| New script `scripts/install-beechat-v5.sh` (branch `chore/beechat-v5-packaging`, commit `4477867`) | ⚠️ Reviewed (SOUND WITH FIXES, 0 blockers) but built off the WRONG base — do not use as-is; will be re-pointed |
