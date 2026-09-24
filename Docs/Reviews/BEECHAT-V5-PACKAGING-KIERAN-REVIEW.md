# BEECHAT-V5 PACKAGING — Independent Safety Review (E5)

**Reviewer:** Kieran (independent; implementer Q may not sign their own gate)
**Date:** 2026-09-24
**Repo:** `/Users/openclaw/projects/BeeChat-v5`
**Branch:** `chore/beechat-v5-packaging`
**Commit under test:** `44778676127133cf53b7d27075b1e5717ba9d40b`
**Base / scope reference:** `fix/log-hardening` (frozen, signed)
**Script under review:** `scripts/install-beechat-v5.sh` (NEW, 265 lines)
**Q's claims (treated as claims, not fact):** commit-message "Verified end-to-end" block in `4477867`

---

## VERDICT: **SOUND WITH FIXES**

The script genuinely *protects* the `/Applications/BeeChatApp.app` rollback, not just *promises* to. I traced every write/copy/rm/rsync/mv in the file (lines 153, 161, 188, 196, 202, 207, 218) and there is no path from any of them to `/Applications/BeeChatApp.app/...` — the destination variable is hardcoded, double-asserted, and the install target is verified to be disjoint from the rollback before any dangerous operation runs. I independently verified current state on disk (AC §C below) and the rollback hash is still pinned. The script is **safe to merge as-is**, with the four findings below as improvements rather than blockers.

**One major, three minors.** None path to rollback damage; the major is a `mktemp` failure edge that would be visible-but-noisy rather than dangerous, and two of the minors are defensive-coding improvements. The single-blocker question — *can a re-run damage `/Applications/BeeChatApp.app`?* — is **NO**, and I show the trace below.

---

## AC-by-AC results

| # | Question (brief) | Result | Evidence (command → observed) |
|---|---|---|---|
| AC-1 | Re-run CAN damage `/Applications/BeeChatApp.app`? | **NO** | Trace every write/copy/rm/rsync/mv in `install-beechat-v5.sh`; see F-T1. Every dangerous op targets a hardcoded V5-only path; the rollback's binary is sha256-asserted before AND after. |
| AC-2 | Pre-flight hash guard is REAL (non-zero exit on drift)? | **YES** | `fail()` calls `exit "${2:-1}"` (line 78); the `if [...] !=` block at line 95 calls `fail … 1`; verified pipeline. `set -e` interaction examined in F-2 — boundary case is benign. |
| AC-3 | `rm -rf` on `$DIR/` cannot widen scope (DIR unset → `/`)? | **NO widening possible** | `APP_DST` hardcoded at line 52; pre-asserted against rollback at lines 112–118; `set -u` active. Trace in F-3. |
| AC-4 | Ad-hoc signs FINAL installed location + `codesign --verify` gates? | **YES** | Sign at line 207 (`codesign --force --deep --sign - "$APP_DST"`); verify at line 213 (`codesign --verify --verbose=2 "$APP_DST"`); both inside `if ! …` blocks that call `fail … 5`. |
| AC-5 | Builds in release mode and copies RELEASE binary (not debug)? | **YES** | Line 133 `swift build -c release`; line 142 `RELEASE_BINARY="$REPO/.build/arm64-apple-macosx/release/$BUNDLE_EXECUTABLE"`; stage-replace at line 162 `cp -f "$RELEASE_BINARY" "$STAGE_BINARY"`. |
| AC-6 | Avoids touching repo's untracked `BeeChatApp.app` template; mktemp + trap? | **YES** | Line 69 `STAGING_ROOT="$(mktemp -d -t beechat-v5-staging)"`; line 75 `trap cleanup EXIT`; cleanup at line 71 `rm -rf "$STAGING_ROOT"` (quoted, dynamic-binding so stale value can't escape). |
| AC-7 | Idempotent: second run ends in same state? | **YES** | Lines 188–195 `if [ -e "$APP_DST" ] || [ -L "$APP_DST" ]; rm -rf "$APP_DST"; fi` handles prior installs. Worst-case residue: see F-M1 (stale-template scenario). |
| AC-8 | No `--delete`, glob, or unquoted path that could widen scope? | **YES** | Line-118 self-check + verbatim absence of `--delete` in the only rsync call (line 202). Trace F-8 below. |
| AC-9 | `/Applications/BeeChatApp.app` sha256 still pinned? | **YES** | `shasum -a 256 /Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp` → `b92602befc722f507f17a9363768d7a0895b1b2c68e97b1fd2cb3c3183cdf9e8` (matches commit-message claim). |
| AC-10 | `/Applications/BeeChat-V5.app` plist identity correct + codesign passes? | **YES** | `PlistBuddy -c Print` confirmed all six fields; `codesign --verify --verbose=2` → exit 0, "valid on disk; satisfies its Designated Requirement". See AC §C below for full values. |
| AC-11 | `git diff --stat fix/log-hardening..HEAD` = only the new script? | **YES** | `git diff --stat fix/log-hardening..HEAD` → 1 file changed, 265 insertions: `scripts/install-beechat-v5.sh`. `release.sh` and `build-and-install.sh` show 0 diff. |

---

## State verified (read-only)

All read-only AC items (AC-9, AC-10, AC-11) checked against current disk and git at the time of this review:

**AC-9 — rollback sha256:**
```
$ shasum -a 256 /Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp
b92602befc722f507f17a9363768d7a0895b1b2c68e97b1fd2cb3c3183cdf9e8  /Applications/BeeChatApp.app/Contents/MacOS/BeeChatApp
```
Matches `$ROLLBACK_PINNED_SHA256` (line 57 of the script). Rollback **byte-intact**.

**AC-10 — V5 plist identity + codesign:**
```
$ /usr/libexec/PlistBuddy -c "Print" /Applications/BeeChat-V5.app/Contents/Info.plist
    CFBundleName              = BeeChat-V5           ✓
    CFBundleIdentifier        = com.beebox.beechat   ✓ (unchanged — does not orphan data)
    CFBundleVersion           = 2026.09.24a          ✓
    CFBundleExecutable        = BeeChatApp           ✓ (binary name preserved)
    CFBundleDisplayName       = BeeChat-V5           ✓
    CFBundleShortVersionString = 0.9.5l              ✓

$ codesign --verify --verbose=2 /Applications/BeeChat-V5.app
/Applications/BeeChat-V5.app: valid on disk
/Applications/BeeChat-V5.app: satisfies its Designated Requirement
EXIT=0
```
All six identity assertions in the bundle match the spec in the commit message.

**AC-11 — diff scope:**
```
$ git diff --stat fix/log-hardening..HEAD
 scripts/install-beechat-v5.sh | 265 ++++++++++++++++++++++++++++++++++++++++++
 1 file changed, 265 insertions(+)

$ git diff --stat fix/log-hardening..HEAD -- scripts/release.sh scripts/build-and-install.sh
(empty)
```
No mutations to the standing release path. As required.

---

## Findings

### F-T1 — Trace: every dangerous operation, with the variable that drives it

| Line | Op | Source | Destination | Rollback reachable? |
|---:|---|---|---|---:|
| 153 | `cp -R` | `$TEMPLATE_BUNDLE` (= `$REPO/BeeChatApp.app`, hardcoded line 47, disjointness-checked at lines 105–107) | `$STAGING_BUNDLE` (= mktemp dir, line 69) | **No** — source is the repo template, dst is a tmpdir |
| 162 | `cp -f` | `$RELEASE_BINARY` (= `$REPO/.build/arm64-apple-macosx/release/BeeChatApp`, line 142) | `$STAGE_BINARY` (= `$STAGING_BUNDLE/Contents/MacOS/BeeChatApp`, line 161) | **No** — both inside the staging bundle |
| 188–195 | `rm -rf "$APP_DST"` (only if `APP_DST` exists/is a symlink) | — | `$APP_DST` (= `/Applications/BeeChat-V5.app`, hardcoded line 52, asserted at lines 109–118) | **No** — APP_DST triple-asserted to be `/Applications/BeeChat-V5.app`, NOT `/Applications/BeeChatApp.app` |
| 202 | `rsync -a "$STAGING_BUNDLE/" "$APP_DST/"` | staging bundle | `/Applications/BeeChat-V5.app` | **No** — same reasoning as 188–195; no `--delete`, source has trailing `/` (contents-into-dest semantics) |
| 207 | `codesign --force --deep --sign -` | — | `$APP_DST` (already shown safe) | **No** |
| 213 | `codesign --verify --verbose=2` | — | `$APP_DST` | **No** (read-only) |
| 71 | `rm -rf "$STAGING_ROOT"` (in trap) | — | mktemp dir | **No** — staging is in /tmp under beechat-v5-staging.*, never /Applications |

The only writes that even *touch* `/Applications` are line 188's gated `rm -rf "$APP_DST"` and line 202's `rsync -a`. Both reference `APP_DST`, which is hardcoded to `/Applications/BeeChat-V5.app` AND asserted to be disjoint from `ROLLBACK_BUNDLE` at lines 109, 113, 117. There is no value `APP_DST` can ever take that names `/Applications/BeeChatApp.app` — and four separate guards say so:

1. **Line 109:** equality check — `if [ "$APP_DST" = "$ROLLBACK_BUNDLE" ]`
2. **Line 113:** substring check — `if [[ "$APP_DST" == *"$ROLLBACK_BUNDLE"* ]]`
3. **Line 117:** equality check — `if [[ "$APP_DST" != "/Applications/$NEW_BUNDLE_NAME" ]]`
4. **Post-flight (line 234):** rollback binary sha256 re-check; exit 6 on any drift

**Conclusion:** the rollback cannot be damaged by a re-run. The four guards form a tight belt-and-braces envelope around the only operations that can ever touch `/Applications`.

### F-2 — Pre-flight hash guard is REAL, with one benign boundary case [minor]

The pre-flight hash guard at lines 92–97 is *not* the "warn and continue" trap:

```bash
ROLLBACK_ACTUAL_SHA256="$(shasum -a 256 "$ROLLBACK_BINARY" | awk '{print $1}')"
if [ "$ROLLBACK_ACTUAL_SHA256" != "$ROLLBACK_PINNED_SHA256" ]; then
    fail "rollback binary sha256 drifted from pinned Aug-7 value …" 1
fi
```

The comparison is a **value** comparison (`!=`), not a substring or pattern. On any drift — including `ROLLBACK_ACTUAL_SHA256=""` (file vanished between line 87 and line 92), or partial garbage from a read error — the body executes `fail`, which calls `exit 1`.

**Boundary case I checked (and the script handles correctly):** `set -e` does not propagate failures from inside `$(…)` command substitution to the assignment line in modern bash. So if `shasum` were to return non-zero on a permission-denied read (it doesn't — shasum emits an error and the awk pipe gets nothing meaningful), the assignment `ROLLBACK_ACTUAL_SHA256=...` would still exit 0 from the shell's POV, and `set -e` would NOT fire. *But* the next test `[ "" != "$ROLLBACK_PINNED_SHA256" ]` is true, and the body calls `fail … 1`. So the script still aborts. The defense-in-depth works.

**Minor finding:** the `RC=0` raw-of-subshell-status is implicit. For maximum robustness one could write `ROLLBACK_ACTUAL_SHA256="$(shasum -a 256 "$ROLLBACK_BINARY" | awk '{print $1}')" || fail "could not hash rollback binary" 1`. Cost: one extra line, no new behavior under normal conditions. **Severity: minor (defensive, not required).**

### F-3 — `rm -rf "$APP_DST"` scope is provably bounded [PASS, evidence above]

The worried-operator failure mode is "what if `APP_DST` is unset → `rm -rf "$APP_DST/"` expands to `rm -rf "/"`". This cannot happen here:

1. `APP_DST="/Applications/$NEW_BUNDLE_NAME"` — assignment at **line 52**, unconditionally, before any later use.
2. `set -u` is on (line 37) — an *unbound* expansion would abort. Even if `$NEW_BUNDLE_NAME` were unset, `set -u` would catch it at line 52.
3. The `APP_DST != "/Applications/BeeChat-V5.app"` assertion at **line 117** is a third independent check.
4. There is no `/` suffix on `$APP_DST` anywhere — and even if there were, the disjointness-assertion block (lines 109–118) runs *before* the `rm -rf` at line 193.

**Conclusion:** `rm -rf "$APP_DST"` can only ever delete a path whose name is literally `/Applications/BeeChat-V5.app` (or `/Applications/BeeChat-V5.app/`). There is no value of any variable in the script that lets that path point at `/`, `/Applications`, or the rollback bundle.

### F-4 — Ad-hoc signing is FINAL + verified [PASS]

```bash
# Line 207
codesign --force --deep --sign - "$APP_DST"
# Line 213
codesign --verify --verbose=2 "$APP_DST"
```

Both operations reference `$APP_DST` (the installed path, /Applications/BeeChat-V5.app), not the staging bundle. The verify step is the standard macOS designated-requirement check; my independent run (AC-10 above) shows exit 0 with the canonical "valid on disk; satisfies its Designated Requirement" output. **`codesign --verify` does gate success — it sits inside an `if ! …; then fail … 5; fi` block at line 213.**

### F-5 — Build mode + binary path [PASS]

```bash
# Line 133
swift build -c release
# Line 142
RELEASE_BINARY="$REPO/.build/arm64-apple-macosx/release/$BUNDLE_EXECUTABLE"
# Line 162
cp -f "$RELEASE_BINARY" "$STAGE_BINARY"
```

Release mode confirmed. Binary path is the standard SwiftPM release location. **Minor lint (no impact):** the `arm64-apple-macosx` slice in the path is hardcoded — the script would write "release binary not found" if run on an Intel Mac. Given the existing rollback is arm64 and the build host is the Mac mini, this is fine, but worth flagging if anyone ever runs this on a non-arm64 box. **Severity: minor (operational portability, not safety).**

### F-6 — mktemp + trap + repo template untouched [PASS]

```bash
# Line 69
STAGING_ROOT="$(mktemp -d -t beechat-v5-staging)"
STAGING_BUNDLE="$STAGING_ROOT/$NEW_BUNDLE_NAME"

# Line 71
cleanup() { rm -rf "$STAGING_ROOT"; }

# Line 75
trap cleanup EXIT
```

- `mktemp -d -t beechat-v5-staging` creates `/tmp/beechat-v5-staging.XXXXXX/` (unique). The variable `$STAGING_ROOT` holds that path.
- The trap is `cleanup EXIT` — fires on *any* exit (success, `set -e` abort, `exit` calls inside `fail`, shell error). Cleanup is therefore unconditional, which is what you want.
- The trap function body references `$STAGING_ROOT` via `$STAGING_ROOT` (unexpanded at trap-time), so even if some pathological shell behaviour re-evaluated the trap body weirdly, the value used is the *current* value of the variable, not a snapshot. Quoted, so word-splitting can't widen scope.
- **The repo's untracked `BeeChatApp.app` template is the *source* read at line 153 (`cp -R`), not the write target. The write target is `$STAGING_BUNDLE` (a subdir of mktemp). The template is never opened in write mode.**

**Major finding (F-M1, edge case):** if `mktemp -d` ever fails (very rare: disk-full in /tmp, weird perms), `set -e` *does* fire on that line (assignment-as-command exits with mktemp's code), so the script aborts cleanly. No `STAGING_BUNDLE=/BeeChat-V5.app`-at-root edge case exists.

**However** — and this is the only non-trivial edge — if the operator passes a working directory that has the *repo's* `BeeChatApp.app` template resolved through a symlink into `/Applications/BeeChatApp.app`, the line 105 disjointness check (`cd $TEMPLATE_BUNDLE && pwd -P` vs `cd $ROLLBACK_BUNDLE && pwd -P`) would catch it. I verified by inspection: `pwd -P` resolves symlinks before comparison. Good. **Severity: not a finding — guard is sound.**

### F-7 — Idempotency: worst-case residue on failure [PASS with one minor]

Idempotent happy-path:
- Run 1: rollback intact, build OK, stage OK, `APP_DST` doesn't exist, rsync creates it, sign OK, verify OK, post-flight OK → end state: rollback unchanged, V5 app at `/Applications/BeeChat-V5.app`.
- Run 2: rollback still intact (verifies again), build incremental, `$APP_DST` exists → `rm -rf "$APP_DST"` at line 193 → rsync recreates, sign, verify → end state: same as Run 1. ✓

**Failure-mode residue (the question the brief asks):** if any step between line 131 (build) and line 230 (final summary) fails:
- `set -e` aborts on first non-zero.
- Trap fires `rm -rf "$STAGING_ROOT"` — staging is cleaned.
- Rollback is intact (post-flight only runs on success; pre-flight already proved it was intact).
- `$APP_DST` may be in a partial state: either still absent (line 188 didn't fire or failed) or left with a partial signed/unsigned bundle (rsync partially complete, codesign failed). **In neither case did the rollback get touched.**

**Minor finding:** if `codesign` fails at line 207 mid-process, the operator is left with a `BeeChat-V5.app` that has unstamped binary components. Re-running is safe — line 188's `rm -rf` clears it. But the failure is silent at the point of resolution: the script fails with exit 5 and the operator has to read the script to understand. **Suggested improvement (severity: minor / nit):** after the `rm -rf` / `rsync` step, fail-fast if the install doesn't look like a valid app bundle (e.g., `[ -f "$APP_DST/Contents/Info.plist" ] || fail ...`). Currently this is implicit via the codesign step, but explicit validation would let the operator see the problem early. **Not required for safety; quality-of-life.**

### F-8 — No `--delete`, no glob, no unquoted path [PASS, with one nit]

- `rsync -a "$STAGING_BUNDLE/" "$APP_DST/"` (line 202) — no `--delete`, no glob, both paths quoted with trailing `/` (correct "into-directory" semantics). **No widening possible.**
- `cp -R "$TEMPLATE_BUNDLE" "$STAGING_BUNDLE"` (line 153) — both quoted; `-R` is fine on macOS for a `.app` bundle. No glob.
- `cp -f "$RELEASE_BINARY" "$STAGE_BINARY"` (line 162) — both quoted; single file. No glob.
- `rm -rf "$APP_DST"` (line 193) — quoted; singleton. **No widening.**
- `rm -rf "$STAGING_ROOT"` (line 71, trap) — quoted. **No widening.**
- `shasum -a 256 "$ROLLBACK_BINARY"` etc. — quoted. **No widening.**
- `plutil -replace CFBundleName -string "$BUNDLE_NAME" "$STAGE_PLIST"` — all quoted.
- `mkdir -p "/Applications"` — literal.

**Nit (severity: nit):** the self-check at line 121 (`grep -nE -- '--delete[[:space:]]' "$0" | grep -qE '...'` ) catches `--delete ` literally followed by whitespace, which is the standard form. Variants `--delete-after`, `--delete-before`, `--delete-excluded`, `--delay-updates` are not caught by this regex. The script does not actually *use* any of these variants, so this is purely a "guard against future edit"; the regex covers what an inattentive copy-paste from elsewhere would introduce. **No action required; flag if the regex is ever extended.**

---

## Adversarial: worst-case at 11pm

I ran the script through the eyes of a tired operator who:

1. **Runs the script from the wrong directory.** `REPO` is computed from `BASH_SOURCE[0]` at line 44, so the script always knows its own location. The relevant commands `cd "$REPO"` (line 132) happen inside the script. ✓

2. **Runs the script with arguments.** The script does not read `$@` or `$1`. All paths are derived from internal hardcoding. Argument pollution is harmless. ✓

3. **Has TMPDIR set to something weird.** `mktemp -d -t beechat-v5-staging` honors `$TMPDIR` if set (POSIX). If `$TMPDIR` points to something pathological (e.g., `/Applications` itself — which would be insane), staging would land there, but the *only* thing that gets written to staging is via mktemp'd subdirs and the `cp` commands; rsync target is hardcoded `/Applications/BeeChat-V5.app`, NOT `$STAGING_ROOT/...` in that weird sense. Worst case: staging-area tmpdir is in `/Applications` instead of `/tmp`. The rollback still cannot be damaged because stage operations use `cp -R "$TEMPLATE_BUNDLE" "$STAGING_BUNDLE"` where both are explicit-dir arguments; even if STAGING_ROOT is `/Applications/stagingXXX`, the destination is `BeeChat-V5.app` inside, not touching `BeeChatApp.app`. **Best-case mitigation:** explicit `TMPDIR=/tmp mktemp ...` to remove ambiguity. **Severity: nit (defense in depth, no current risk).**

4. **Re-runs the script while a previous run is still in progress (race).** Two concurrent runs: each gets its own mktemp dir (unique). Pre-flight checks pass (rollback unchanged). The `rm -rf "$APP_DST"` from run 2 competes with the `rsync` from run 1. **Result:** a mix of files at `/Applications/BeeChat-V5.app`. **Rollback:** both runs' pre-flight and post-flight guarantees still hold. **The V5 app itself ends up broken.** Operator notices, kills both, re-runs. Rollback intact. ✓

5. **The repo template (`$REPO/BeeChatApp.app`) is corrupted or out-of-date.** Script builds release, then copies busted template around the good binary. End state: non-functional V5 app. Rollback intact. Operator notices on launch, fixes template, re-runs. **No rollback risk. **Severity: nit — fix-up requires operator judgment, but rollback is safe.

6. **The operator's environment lacks codesign / shasum / plutil / rsync.** Each operation uses POSIX-standard short names but does NOT pre-validate their presence. `set -e` catches the failure on first invocation. Rollback intact. ✓

7. **The operator runs with `sudo` and points APP_DST at a path the unprivileged user owns.** Sudo + rm -rf is the operator's choice; the script itself will either succeed (leaving root-owned files behind) or fail (set -e catches the permission error). Rollback intact. ✓

**Conclusion: there is no single worst thing this script does that damages the rollback.** All worst cases are bounded to (a) a partial/broken V5 install (recoverable) or (b) a controlled abort with clear error messages.

---

## Summary

- **Verdict:** SOUND WITH FIXES.
- **Blockers:** 0.
- **Major:** 0.
- **Minor:** 3 (F-2: explicit-or-fail on shasum pipe; F-5: arch-path portability note; F-7: fail-fast after install). All are improvements, not requirements.
- **Nits:** 3 (F-8 regex scope; F-T1 TMPDIR pin; F-5 arch-path note).
- **Rollback integrity at time of review:** ✓ verified independently, byte-identical to Aug-7 pin.
- **Q's commit-message claims:** independently verifiable. All five end-to-end claims in commit 4477867 reconfirmed by my own commands (sha256 + plist + codesign).

The script is ready for sign-off. None of my findings gate merge. If Adam wants the three minors addressed, they are all small, localised edits; otherwise the script ships.

— Kieran, E5 independent safety review, 2026-09-24
