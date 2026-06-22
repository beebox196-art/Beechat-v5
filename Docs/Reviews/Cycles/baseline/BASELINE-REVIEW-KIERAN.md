# Baseline/Tagging Strategy Review — Kieran

**Date:** 2026-05-24 17:15 BST
**Reviewer:** Kieran (adversarial reviewer)
**Branch reviewed:** `develop` (HEAD `55bb74a` — hotfix: correct message sort order)
**Compared against:** `main` (HEAD `52234f7` — Gate 2F Phase 0)
**Feature branch:** `feature/gate-2f-unified` (9 commits ahead of develop)

---

## Summary: Mostly Solid, Two Gaps Need Closing

The plan is directionally right. Tagging `develop` as a baseline gives us an anchored reference point with protocol v4, and keeping the feature branch separate avoids contaminating baseline with unvalidated work. But there are two material gaps and one risk I want surfaced before execution.

---

## 1. Tagging `develop` HEAD — Safe with One Caveat ✅→⚠️

**What works:**
- `develop` has the protocol v4 fix (bumped `ConnectParams.swift` from min/max 3→4, plus `HelloOk` default fallback). This is correct — iOS needs v4.
- The AnyCodable iOS compatibility fix is on `develop` (replaced the `NSDictionary` equality hack with proper type-switched comparison). This matters for iOS builds.
- `develop` HEAD (`55bb74a`) is a clean sort-order hotfix — no shared-package churn.
- Mac app builds from `develop` via `Sources/App/` which is Mac-only.

**The caveat — ChatField vendor discrepancy:**
`main` is missing the entire `Vendors/ChatField/` directory (~147 files of deletions relative to develop). `develop` has ChatField fully present as a local SPM dependency. If anyone ever tries to build from `main` (e.g., a hotfix or rollback), the Mac app will fail because `BeeChatApp` depends on `.product(name: "ChatField", package: "ChatField")` and the vendored package won't exist.

This doesn't block tagging `develop`, but it means `main` is effectively **unbuildable** right now. Tagging develop is the right call — `main` has diverged in a destructive direction.

**Verdict:** Tag `develop` as `v0.1.0-baseline`. It's the only branch that actually builds both platforms.

---

## 2. Build-Validate Before Tagging — Correct, but Specify Scope ⚠️

The plan says "build-validate both Mac and iOS." Good. Here's what that should actually verify:

### Required validations (in order):
1. **`swift build` on BeeChat-v5 from `develop`** — confirms shared packages + Mac app compile
2. **Mac app launch + gateway handshake** — confirms protocol v4 handshake works on Mac
3. **`swift build` on BeeChat-Mobile** — confirms the path dependency resolves and iOS compiles

### Why order matters:
If step 1 fails, don't proceed to step 3. The path dependency means BeeChat-Mobile will inherit whatever `develop` has — if develop doesn't build, Mobile won't either.

### Missing validation I'd add:
4. **Check the `.build` resolution cache isn't stale.** BeeChat-Mobile uses a path dependency (`../../BeeChat-v5`). If someone previously built against a different `develop` HEAD and SPM cached it, the build might appear green against stale artifacts. Recommend: `rm -rf .build` in BeeChat-Mobile before the iOS build validation.

---

## 3. Feature Branch Isolation — Correct, Divergence Risk is Manageable ✅

`feature/gate-2f-unified` is 9 commits ahead of `develop`, all topic-project-binding work. These are:
- Steps 1-8 of topic-project-binding (metadata extension, repository updates, project scaffolder, scanner, UI wiring, context injection)
- Two bugfixes on top (infinite spinner, project context re-injection)

**None of these touch `develop`.** The divergence is clean — all 9 commits build on top of `develop`'s current state.

**Divergence risk: LOW for now.** The branch is only 9 commits, all touching `Sources/App/` (Mac-only) or shared packages for topic-binding features. As long as `develop` doesn't get heavy shared-package changes, rebasing this onto develop will be trivial.

**What could change that:**
- If protocol changes again (v5?) — would need a rebase
- If shared-package interfaces change significantly in BeeChatGateway/BeeChatPersistence/BeeChatSyncBridge — would need merge resolution

**Recommendation:** Set a timebox. If the feature branch isn't merged back into develop within 2 weeks, flag it for a rebase check. Nine commits today is easy. Twenty-seven in three weeks is a headache.

---

## 4. SPM Dependency — Already a Path Dependency, No Change Needed ✅

Checked `/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Package.swift`:

```swift
.package(path: "../../BeeChat-v5"),
```

This is a **path dependency**, not a branch or version reference. It always resolves to whatever is on disk at `../../BeeChat-v5`. There is no "branch pin" to update — the dependency follows whatever commit is checked out in the BeeChat-v5 directory.

**What this means for the plan:**
- Step 4 ("Update BeeChat-Mobile's SPM dependency to reference `develop` branch explicitly") is **unnecessary** — it already does this implicitly via the path dependency.
- If we wanted to pin to a specific tag later, we'd need to change from a path dependency to a git URL dependency with `from: "v0.1.0-baseline"` or similar. That's a future decision, not a baseline-tag prerequisite.

**Caveat:** Path dependencies are great for active development but risky for tagged releases. If the plan is to have a stable baseline tag, consider whether BeeChat-Mobile should eventually reference `develop` via git URL + branch, so CI/remote builds don't depend on local filesystem state.

---

## 5. Cross-Stream Safeguards Integration — The Missing Link ⚠️

The safeguards doc (`CROSS-STREAM-SAFEGUARDS.md`) is well-written but it has **six open questions for Adam** that haven't been answered. These aren't blockers for adopting the rules, but they signal the doc isn't fully operationalized yet.

**What's actually needed:**

The safeguards doc describes rules. The plan says "merge it into the workflow so Q always checks both platforms." But "merge into workflow" is vague. Here's what I'd make concrete:

1. **Add a pre-commit or CI check** — any PR touching shared packages must include `swift build` output from both BeeChat-v5 and BeeChat-Mobile. No output = no merge.
2. **Update the PR template** — include the Q checklist from the safeguards doc as a mandatory section.
3. **Tag the baseline first, then adopt the rules** — don't let the rules delay the baseline tag. The baseline gives us an anchor; the rules protect it going forward.

---

## 6. Rollback Plan — Missing from the Proposal 🔴

The proposed plan has no rollback strategy. If `v0.1.0-baseline` turns out to be wrong (e.g., we discover after tagging that there's a bug in the protocol v4 implementation, or the AnyCodable fix has edge cases), what do we do?

**Recommended rollback plan:**

### If the tag is wrong:
1. **Delete the tag:** `git tag -d v0.1.0-baseline` (local) + `git push origin :refs/tags/v0.1.0-baseline` (remote). Tags are lightweight — deleting and recreating is cheap.
2. **Fix the issue on develop.**
3. **Re-tag with a suffix:** `v0.1.0-baseline.1` or `v0.1.1-baseline` — don't reuse the same tag name if it was already pushed somewhere SPM might have cached it.

### If develop itself has a latent bug:
1. **Use the most recent existing working tag** — we already have `v0.5.5-pre-topic-binding`, `v0.6.0-reset-inject`, and `v0.6.0-topic-binding`. These are older but may represent known-good states.
2. **Create a hotfix branch** from the last-known-good tag, cherry-pick only the protocol v4 fix + AnyCodable fix from develop, tag that as `v0.1.0-baseline` instead.

### SPM cache consideration:
If anyone has already resolved dependencies against `v0.1.0-baseline` (in `.build/checkouts/` or `Package.resolved`), deleting and re-tagging with the same name won't help — SPM caches by tag name. That's why re-tagging should use a new name if the tag was ever pushed to origin and consumed.

---

## 7. Additional Risks Worth Noting

### 7.1 `main` is a zombie branch
`main` is 147 files behind `develop` (it's missing ChatField entirely, and has ~834 deletions vs develop's additions). `main` currently has protocol v3, which is wrong for both platforms. **`main` should not be used for anything until it's brought forward.** Anyone accidentally building from `main` will hit compile errors (missing ChatField) AND protocol mismatches.

**Recommendation:** Fast-forward `main` to `develop` after the baseline tag, or at minimum document that `main` is NOT a buildable state.

### 7.2 Existing tag naming convention
We have a mess of tags already: `v0.5.0-*`, `v0.6.0-*`, `v5-stable-*`, `v5.1-*`, plus pre-fix tags. The proposed `v0.1.0-baseline` is a different numbering scheme. That's fine for a baseline, but it will be confusing when we start doing `v0.2.0`, `v0.3.0` etc. alongside `v0.6.0-topic-binding`.

**Recommendation:** Either use `v0.7.0-baseline` (continuing the sequence from the latest `v0.6.0-*`) or clearly document that `v0.1.0-baseline` is a new baseline series that supersedes the older numbering.

### 7.3 BeeBoard is shared but Mac-only in practice
`BeeBoard` is listed as SHARED in the safeguards doc, but BeeChat-Mobile's Package.swift doesn't import it. However, it IS defined as a product in BeeChat-v5's Package.swift. This means changes to BeeBoard won't break iOS at build time (because iOS doesn't depend on it), but could break if someone adds BeeBoard as a dependency to BeeChatMobileKit later.

**Low risk, but worth a comment in the safeguards doc.**

---

## Decision Matrix

| Plan Step | Verdict | Notes |
|---|---|---|
| 1. Tag develop as v0.1.0-baseline | ✅ Approve | But consider version numbering consistency |
| 2. Build-validate both platforms first | ✅ Approve | Add `.build` cache purge step |
| 3. Keep feature branch separate | ✅ Approve | Set 2-week divergence timebox |
| 4. Update SPM dependency to develop | ℹ️ Unnecessary | Already a path dependency — follows disk state |
| 5. Integrate safeguards into workflow | ✅ Approve | But make concrete (PR template + pre-commit) |

## Missing from Plan (Add Before Execution)

- **Rollback plan** — tag deletion + re-tag strategy
- **main branch status** — document or fast-forward, it's currently broken
- **SPM cache purge** — clear `.build` before iOS validation
- **Version numbering decision** — baseline series vs continuing from v0.6.0

---

## Bottom Line

The plan is sound. Tag `develop` — it's the only branch that works. Build-validate both platforms (purging the SPM cache first). Keep the feature branch separate but timebox the divergence. The safeguards doc is good content but needs operationalization, not just adoption. And write a rollback plan before you create the tag, because the cost of not having one is high when SPM starts caching it.

Do the tag. Then fix `main`.
