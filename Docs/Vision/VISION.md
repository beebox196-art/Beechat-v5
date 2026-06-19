# BeeChat v5

A personal control surface for OpenClaw — the native command centre for orchestrating agents, managing context, and directing autonomous work across Mac and iPhone.

## In Scope

- **Mission Control UI:** live agent status, active tasks, approval queues, workflow timelines — see what your agents are doing, not just what they said
- **Token economics:** per-topic, per-agent, per-day cost visibility; inline compaction, summarisation, and context-pruning actions
- **Context inspection and control:** visible context panels per topic (files, decisions, token cost, stale warnings); add, remove, pin, or reset what each agent sees
- **Cross-device continuity:** task state syncs between Mac and iPhone — start a subagent on desktop, monitor on mobile, act from either
- **Hands-off operation:** scheduled digests report back, autonomous subagents complete work, notifications only when Adam needs to act
- **Topics as workspaces:** durable project rooms with goals, artifacts, decisions, handoffs, agent runs, reviews, and completion state
- Bug fixes and stability for existing chat functionality
- UI polish that serves the control surface (not cosmetic for its own sake)
- Example in-scope PRs: "Add agent status sidebar with live task timeline", "Show per-topic token spend in topic list", "Add context panel with file/decision/token summary", "Wire approval queue for elevated exec actions"

## Out of Scope

- Features that don't surface agent activity, context, or control (pure chat features without operational value)
- Broad refactors or architecture changes without a Gate spec
- Changes that break BeeChat Mobile shared package compatibility
- New SPM dependencies without team review
- Gateway or server-side changes (BeeChat is a client)
- Features that cannot be tested against a live OpenClaw gateway on localhost
- Commercial features or monetisation layers (BeeChat is the showcase, not the product)
- Example out-of-scope PRs: "Add custom emoji reactions", "Rewrite persistence in SwiftData", "Add in-app purchases", "Replace WebSocket with HTTP polling"

## Needs Human

- Gate progression decisions (which Gate, spec approval, exit criteria changes)
- Any change to shared BeeChatPersistence, BeeChatGateway, or BeeChatSyncBridge APIs
- New feature proposals not in an approved Gate spec
- Security-relevant changes (auth, keychain, device identity)
- Changes that affect token spend or context injection strategy

## The 12-Month Test

Within a year, BeeChat should run unattended for hours or days. Scheduled work completes autonomously. Subagents report back with evidence. Notifications fire only when Adam needs to act. If Adam can't walk away from the Mac and trust the system, the vision isn't met. Design every feature against this test.

## Merge Criteria

- Trivial fixes: build passes → commit
- Standard changes: tests pass + Kieran review → commit
- Critical changes: spec + doubt-driven-development + build + Kieran review + Adam sign-off → commit
- All changes: must compile against BeeChat Mobile's Package.swift without modification

## If Blocked

State exactly what's missing: the failing test, the missing API, the unclear spec section. Do not leave a PR open with "needs discussion" — either specify the blocker or close it.