# BeeChat v5

A personal control surface for OpenClaw — the native command centre for orchestrating agents, managing context, and directing autonomous work across Mac and iPhone.

## Purpose

BeeChat is Adam's portal to the full team and everything we're working on — the ongoing activities, goals, and aspirations. It is the primary interface between Adam and Bee, and between Adam and the agent team. It will develop toward being the connection point as Bee moves closer to full autonomous operation.

Initially a personal tool for Adam. Medium-term aspiration: evaluate whether BeeChat could become a commercial offering. Long-term consideration: potentially open BeeChat Mobile to other family members (e.g., Adam's wife). Multi-user is not a current design constraint but should not be architecturally precluded.

## In Scope

- **Multi-topic chat:** durable project rooms with goals, artifacts, decisions, handoffs, agent runs, reviews, and completion state. Topics are workspaces, not just message threads.
- **BeeBoard:** idea collection, intent tracking, pin prioritisation, and archive/restore. The bridge between what's on Adam's mind and what the team works on. Central to the BeeChat experience, not a side feature.
- **Team activity watching:** live view of what agents are doing — Sag's scout runs, Gav's digests, Luna's briefings, Q's builds, Kieran's reviews. Not just task queues, but a living picture of the team at work.
- **Research dialog:** integrated research workflow (`/research` pipeline) surfacing findings, reports, and external distribution within BeeChat. The research pop-up box concept (BeeBoard pin: Research Pop Up Box).
- **Personal UI elements:** desktop folder view, file browsing, quick access to workspace resources. BeeChat is Adam's personal portal, not a generic dashboard — it should feel like his.
- **Mission Control absorption:** project tracking, task management, and workflow visibility that Mission Control was designed to provide but that BeeChat will encompass. BeeChat becomes the project tracking layer, not just the chat layer.
- **Context inspection and control:** visible context panels per topic (files, decisions, token cost, stale warnings); add, remove, pin, or reset what each agent sees
- **Token economics:** per-topic, per-agent, per-day cost visibility; inline compaction, summarisation, and context-pruning actions
- **Cross-device continuity:** task state syncs between Mac and iPhone — start a subagent on desktop, monitor on mobile, act from either
- **Hands-off operation:** scheduled digests report back, autonomous subagents complete work, notifications only when Adam needs to act
- **Beelinks integration (future):** alternative viewing of captured knowledge via Beelinks knowledge graph. Not built yet, but BeeChat should be ready to surface Beelinks context queries when Phase 2 visualisation ships.
- Bug fixes and stability for existing chat functionality
- UI polish that serves the control surface (not cosmetic for its own sake)
- Example in-scope PRs: "Add agent status sidebar with live task timeline", "Show per-topic token spend in topic list", "Add context panel with file/decision/token summary", "Wire approval queue for elevated exec actions", "Add BeeBoard pin creation from topic context menu", "Surface research pipeline results in topic sidebar"

## Out of Scope

- Features that don't surface agent activity, context, or control (pure chat features without operational value)
- Broad refactors or architecture changes without a Gate spec
- Changes that break BeeChat Mobile shared package compatibility
- New SPM dependencies without team review
- Gateway or server-side changes (BeeChat is a client)
- Features that cannot be tested against a live OpenClaw gateway on localhost
- Commercial features or monetisation layers (not yet — see Purpose above; medium-term aspiration, not current scope)
- Multi-user auth or user management (long-term consideration, not current scope)
- Example out-of-scope PRs: "Add custom emoji reactions", "Rewrite persistence in SwiftData", "Add in-app purchases now", "Replace WebSocket with HTTP polling", "Add multi-tenant user accounts"

## Needs Human

- Gate progression decisions (which Gate, spec approval, exit criteria changes)
- Any change to shared BeeChatPersistence, BeeChatGateway, or BeeChatSyncBridge APIs
- New feature proposals not in an approved Gate spec
- Security-relevant changes (auth, keychain, device identity)
- Changes that affect token spend or context injection strategy
- Any change to the purpose or scope of BeeChat (commercial pivot, multi-user expansion)

## The 12-Month Test

Within a year, BeeChat should run unattended for hours or days. Scheduled work completes autonomously. Subagents report back with evidence. Notifications fire only when Adam needs to act. If Adam can't walk away from the Mac and trust the system, the vision isn't met. Design every feature against this test.

## Merge Criteria

- Trivial fixes: build passes → commit
- Standard changes: tests pass + Kieran review → commit
- Critical changes: spec + doubt-driven-development + build + Kieran review + Adam sign-off → commit
- All changes: must compile against BeeChat Mobile's Package.swift without modification

## If Blocked

State exactly what's missing: the failing test, the missing API, the unclear spec section. Do not leave a PR open with "needs discussion" — either specify the blocker or close it.