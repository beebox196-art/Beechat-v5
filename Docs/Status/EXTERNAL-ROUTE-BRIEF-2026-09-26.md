# BeeChat — External Route Brief (2026-09-26)

**To:** external reviewers (grok, claude, chatgpt)
**From:** Bee (coordinator) — on behalf of Adam
**Revision:** r2, 2026-09-26 23:00 BST — **3 factual corrections applied** (see box below); r1 was wrong on the fix's base, the commit gap, and a SyncBridge claim.
**Goal (Adam's words, verbatim):** *"a version working from the right foundation as current Beechat with the surgical removal of the debug logs. That is the goal here. No major changes just eliminating the unnecessary log writing."*

---

> ### ⚠️ r2 corrections (2026-09-26) — r1 contained 3 false "verified" facts
> Independent repo check (HEAD `ee9baf0`, worktrees `937e18b` / `cd102c8`) found and fixed:
> 1. **Base was wrong.** r1 said the fix is based on `main@381dec9`. Actual: `2a64c0a`'s parent = **`682e701`** (`v0.9.4-archiving`, 2026-06-30, `origin/develop`). `381dec9` is **NOT** an ancestor of the fix (`git merge-base --is-ancestor 381dec9 cd102c8` → false). The fix sits on a **two-month-stale `develop`** — that *is* the wrong-base lineage; r1 mislabelled *which* wrong base.
> 2. **Gap was wrong.** r1 said 50 commits (`381dec9..937e18b`, true but measured from the wrong ref). From the fix's **real** base it is **98** (`682e701..937e18b`).
> 3. **SyncBridge was wrong.** r1 said the fix's core touches `SyncBridge.swift`. It does not — `2a64c0a` (and every fix/review commit on the branch) has **no SyncBridge hunk**.
>
> Corrections marked inline below with **[r2]**. The route verdict (A, base `937e18b`) is **unaffected** — the C-thesis breaks on a *test-module collision*, not on any of these three facts. Full evidence: `AgentDrop/beechat-brief/GROK-ROUTE-ACK-DETAIL.md`.

---

## 1. The decision we need you to stress-test

**Which source base should the "debug-log removal" change be built on, and how should the change reach it?**

Options currently on the table:

- **Option A — Port the logging fix forward onto `937e18b`** (Adam's running app revision, `0.9.5l`). Take the *intent* of the logging-hardening work (bounded file sink, reduced/eliminated verbose diagnostic writes) and re-apply it surgically to the 0.9.5l tree.
- **Option B — Land the existing `fix/log-hardening` branch as-is** (real base `682e701` = `v0.9.4-archiving`, `origin/develop`, 30 Jun — **[r2]** corrected from the r1 claim of `main@381dec9`) and ship that as a separate build.
- **Option C — Cherry-pick the 3 fix commits onto `937e18b`.**
- **Option D — something else you can argue for.**

Bee's provisional read: **Option A is the only one consistent with Adam's goal**, because Adam wants *current BeeChat* (his running 0.9.5l) with logs removed — not an older commit with logs removed. But that read must be tested, not assumed.

## 2. Hard facts (verified this session, cite-checkable)

### Revisions
| Ref | SHA | Date | VERSION | Notes |
|---|---|---|---|---|
| `main` | `381dec9` | 2026-08-06 | — | Superset of `develop`; ancestor of `937e18b`. **NOT the base of the fix** **[r2]** |
| `develop` | `682e701` | 2026-06-30 | `v0.9.4-archiving` | **The fix's REAL base** **[r2]** (two-month-stale) |
| Adam's running app | `937e18b` | 2026-08-07 | `0.9.5l` | "auto-backup" tip; superset of `main`, **+96 over the fix's base** (98 incl. both endpoints) **[r2]** |
| `fix/log-hardening` | `cd102c8` | 2026-09-24 | — | 3 fix commits + 3 Kieran review commits; **real base `682e701`**, not `381dec9` **[r2]** |
| `fix/log-hardening-v2` (rework) | `937e18b` | — | `0.9.5l` | Correct base, **zero commits applied yet** |

### Ancestry
- `main (381dec9)` **IS** an ancestor of `937e18b` → the running app contains main.
- `381dec9` is **NOT** an ancestor of `fix/log-hardening`. The fix's actual base is `682e701` (`develop`), which **IS** an ancestor of `main`. **[r2]** So the fix branched off `develop` *before* main moved forward — it is not a superset of the running app, and the divergence is `develop`→`main`→`937e18b`.
- The logging branch does **NOT** contain the web-transcript commits that `937e18b` has — **98 commits** across the gap from the fix's real base (`682e701..937e18b`), not the 50 that r1 stated (50 was `381dec9..937e18b`, measured from the wrong ref). **[r2]**

### What the logging fix actually contains (3 core commits)
- `2a64c0a` fix(logging): harden diagnostic file sinks — **11 files**: new `Sources/BeeChatLogging/BoundedFileLog.swift` (106 lines), new `Sources/BeeChatGateway/GatewayDiagnostics.swift` (36 lines), rewrite of `Sources/App/Utils/BeeChatLogger.swift`, edits to `GatewayClient.swift`, `DatabaseManager.swift`, `Package.swift` (new `BeeChatLogging` target), + 3 test files, + `Docs/Status/LOGGING-STANDARD.md`, + mutation-evidence doc.
- `f32d14b` fix(logging): make guards deterministic — 4 files.
- `1f0b3f1` test(logging): eliminate G4 reconnect race — 2 files.
- Kieran review commits: `be32e69` (CORRECTIONS REQUIRED), `b48947a` (SOUND WITH FIXES), `cd102c8` (round-3 final sign-off SOUND).

### Presence of the fix's target files in Adam's running tree (`937e18b`)
- `Sources/App/Utils/BeeChatLogger.swift` — **EXISTS** (74 lines, the *old* pre-hardening logger; writes to `~/Desktop/BeeChat-diagnostics.log`, 1 MB rotate).
- `Sources/App/UI/Components/MessageCanvas.swift`, `Sources/App/Rendering/HTMLMessageConverter.swift` — **EXIST**.
- `Sources/BeeChatLogging/BoundedFileLog.swift` — **ABSENT** (new file the fix introduces).
- `Sources/BeeChatGateway/GatewayDiagnostics.swift` — **ABSENT** (new file).
- `Package.swift` at `937e18b` does **NOT** declare a `BeeChatLogging` target.

### Packaging
- `scripts/install-beechat-v5.sh` (commit `4477867`, on branch `chore/beechat-v5-packaging`) builds and installs a side-by-side `BeeChat-V5.app` **without touching** `/Applications/BeeChatApp.app`.
- **KNOWN DEFECT:** that script is based on the same wrong-base lineage — it must be re-pointed at `937e18b` before it can build Adam's actual app.

## 3. What is NOT yet verified (call these out)

1. **Does the logging fix depend on anything only present in its real base (`682e701`) lineage?** The fix edits `DatabaseManager.swift` (and `BeeChatLogger.swift`, `GatewayClient.swift`, `Package.swift`) — **NOT** `SyncBridge.swift` **[r2]**. Across the gap `682e701..937e18b`: `DatabaseManager.swift`, `BeeChatLogger.swift`, `GatewayClient.swift` are **byte-identical**; only `Package.swift` differs (17+/12−). So there is no source-content drift in the fix's production targets. (The cross-base break is in the **test module** — see §4 C.)
2. **Concurrency safety of the side-by-side test.** `BeeChat-V5.app` would share `CFBundleIdentifier` (`com.beebox.beechat`), DB path, SyncBridge, and gateway pairing with the running app. Can they co-exist without corrupting each other's DB or stealing the gateway connection? **Unverified.**
3. **The "surgical removal" scope.** The existing fix *hardens* log sinks (bounded file, redaction) rather than purely *deleting* verbose logging. Is hardening the same as Adam's "eliminating unnecessary log writing"? This may be scope drift.

## 4. What we want from you

1. **Route verdict.** A/B/C/D — which base, and why. Argue from the "current BeeChat, logs surgically removed, no feature change" goal.
2. **Attack the cherry-pick idea.** Is A (port intent forward) genuinely safer than C (cherry-pick SHAs)? What specifically breaks in a cherry-pick across the **98**-commit base gap (real base `682e701`) **[r2]**?
   - **Our finding — challenge it:** cherry-picking `2a64c0a f32d14b 1f0b3f1` onto `937e18b` **applies clean** (exit 0) and `swift build` **succeeds** (app + all 50 transcript files compile), but `swift test` **fails at compile**: `invalid redeclaration of 'InMemoryTokenStore'`. Cause: the fix's `GatewayLoggingSecurityTests.swift` declares its own `private final class InMemoryTokenStore`; `937e18b` already has a **shared** `Tests/BeeChatGatewayTests/InMemoryTokenStore.swift` (added by `0de258e` on the transcript line, **absent** from `682e701`). Two declarations in one module → the test target does not build. Control: `swift test` on `cd102c8` compiles and is green. So C is out on a **test-module collision**, not a DB one — and it isn't silent, it stops at compile. Do you agree, and is there a repaired C worth considering?
3. **Scope question.** Does "surgical removal of debug logs" mean *delete verbose call-sites*, or *bound/rotate the sink*? The existing fix does the latter. Which does Adam actually want, and is there a reading where both are needed?
4. **Concurrency.** What must be true (bundle id / DB path / sync port / gateway pairing) for the old and new app to be smoke-tested side-by-side without mutual corruption? If it cannot be safe, say so plainly.
5. **What evidence would falsify your recommendation?** (Be specific — what test/command would change your answer.)
6. **Anything we have not asked** that the goal implies.

**Constraints:** No writes to Adam's running app. No destructive git. Read-only analysis plus recommendations. If you cannot see the repo, say so and reason from the facts above.

Reply with: route verdict, the falsifying evidence, and your top 2 risks.
