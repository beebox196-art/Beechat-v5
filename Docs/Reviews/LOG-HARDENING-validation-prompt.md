# Validation request — LOG-HARDENING spec (T-BEECHAT-LOGGING-HARDENING)

You are reviewing a spec, not code. Bee authored it. Your job: find where it is
wrong, unsound, or will not survive contact with the real repo.

## The spec

`/Users/openclaw/projects/BeeChat-v5/Docs/Specs/Active/LOG-HARDENING-SPEC.md`
(repo: `/Users/openclaw/projects/BeeChat-v5/`, commit `91758e9`, branch
`feat/transcript-integration`).

## Context in one paragraph

On 2026-09-24 a hardcoded Desktop debug logger in `GatewayClient.swift` was found
in a loop-bug state writing ~10 MB/hour (caught by the system canary). I patched
it (commit `32afd4e`) — now gated off by default on `BEE_DEBUG_LOG=1`. But: (a) the
fix is **committed, not shipped** — it lives on a 54-commit feature branch, `main`
does not contain it, and the running `/Applications/BeeChatApp.app` is dated
2026-08-07 (pre-fix). (b) There are **two more sinks** of the same class —
`BeeChatLogger.swift` writes unconditionally to `~/Desktop/BeeChat-diagnostics.log`
from 42 call sites, and `DatabaseManager.swift:421` seeds a hardcoded
`/Users/openclaw/Desktop/Claude Oversight Reports` row into the DB. The spec
remediates all three and adds a build guard to close the class.

## What I want from you

**Kieran** — adversarial review of soundness:
1. Is §9 (branch/release decision) right that the fix must go on a
   `fix/*` branch off `develop`, not wait for transcript-integration? Any hole?
2. §4.5 guard design: will G1/G2/G3 actually catch the class without
   false-positiving on the 22 legitimate `/Users/` hits (§3.5)? Where would you
   attack it?
3. §3.3 / D3 (DatabaseManager seed row): is "drop the seed" safe against existing
   shipped DBs, or does it need a migration? What breaks?
4. §6: does `GatewayClient.swift:579` (`debugLog("Sending handshake: \(text.prefix(500))")`)
   risk logging a token? Verify.
5. Anything in the ACs that is not actually verifiable, or that the implementer
   could sign without doing the work (E5 violation risk)?

**Q** — implementation feasibility:
1. Is the shared-policy refactor (§4.4) worth it versus just fixing the two sinks?
2. Can a Swift test genuinely implement G1 without a linter? How?
3. Does routing `BeeChatLogger` through the same gate break any of the 42 call
   sites' behaviour?
4. Migration risk on D3 — what does the existing migration code look like?

## Constraints

- **You have no local file access.** Everything you need is inlined below or in
  the spec excerpt. If you need a specific file, say which and why.
- Do not propose building anything. Review only.
- Verdict format: **SOUND** / **SOUND WITH FIXES** / **CORRECTIONS REQUIRED**,
  then numbered findings each with severity (blocker/major/minor/nit).

## Key evidence inlined

```
Sources/BeeChatGateway/GatewayClient.swift:5-35  (post-fix, HEAD 32afd4e)
    private let debugLogEnabled = ProcessInfo.processInfo.environment["BEE_DEBUG_LOG"] == "1"
    private let debugLogURL = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["BEE_DEBUG_LOG_PATH"]
            ?? "\(NSHomeDirectory())/Library/Logs/BeeChat-debug.log")
    private func debugLog(_ message: String) {
        print("[GW] \(message)")
        guard debugLogEnabled else { return }
        ... (writes, no size cap — the "bounded" claim in the header comment is FALSE)

Sources/BeeChatGateway/GatewayClient.swift:579
            debugLog("Sending handshake: \(text.prefix(500))")

Sources/App/Utils/BeeChatLogger.swift:10-13,25-27
    private static let logURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("BeeChat-diagnostics.log")
    }()
    private static let maxLogBytes: Int = 1_048_576
    private static let truncateToBytes: Int = 262_144

Sources/BeeChatPersistence/Database/DatabaseManager.swift:421
                "/Users/openclaw/Desktop/Claude Oversight Reports",

All 25 /Users/ hits in Sources/ (10 files):
  FileLinkText.swift:39,42,109          (regex + link parsing)
  EditTopicSheet.swift:109              (literal /Users/openclaw/Projects/)
  ProjectDirectoryUtils.swift:8,10,35   (default arg)
  ProjectScaffolder.swift:39,40,45,46   (default args)
  LinkPolicy.swift:15,76,81,111         (validation — correct)
  SyncBridge.swift:468,780,861          (workspace constants)
  TopicSummaryWriter.swift:150,151      (prefix list)
  ProjectContextReader.swift:12         (validation — correct)
  DatabaseManager.swift:421             (DEFECT)
  Topic.swift:130,161,162               (validation — correct)
```

## Branch topology (verified)

```
main = 381dec9  (does NOT contain the logger fix)
feat/transcript-integration = 32afd4e  (54 commits ahead of main; the fix is orphaned here)
git rev-list --left-right --count main...feat/transcript-integration  →  0  54
```
