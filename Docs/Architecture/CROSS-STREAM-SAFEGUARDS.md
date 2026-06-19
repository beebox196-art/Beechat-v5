# Cross-Stream Safeguards — BeeChat Mac vs Mobile

**Date:** 2026-05-24
**Trigger:** Cross-contamination incident during Gate 2F mobile work broke Mac build.
**Author:** Bee (team review required before adoption)

---

## The Architecture (What We're Protecting)

```
BeeChat-v5 (single SPM repo)
├── Sources/App/              ← MAC-ONLY (42 files)
│   └── BeeChatApp executable
├── Sources/BeeChatGateway/   ← SHARED (11 files) → compiled into BOTH Mac + iOS
├── Sources/BeeChatPersistence/ ← SHARED (13 files) → compiled into BOTH Mac + iOS
├── Sources/BeeChatSyncBridge/  ← SHARED (15 files) → compiled into BOTH Mac + iOS
└── Sources/BeeBoard/           ← SHARED (Mac uses, iOS doesn't)

BeeChat-Mobile (separate repo)
└── SPM path dep → ../../BeeChat-v5
    └── Imports: BeeChatGateway, BeeChatPersistence, BeeChatSyncBridge
    └── DOES NOT import Sources/App
```

**The risk:** Any change to the 3 shared packages (39 files total) compiles into both Mac and iOS. A change that works on iOS can silently break the Mac, and vice versa. The protocol version mismatch incident (v3→v4) is the perfect example — a two-line change broke the Mac handshake.

---

## Rules for BeeChat Development

### Rule 1: Classify Every Change

Before any code change, declare which stream it affects:

| Category | Affects | What to do |
|---|---|---|
| **Mac-only** | `Sources/App/` only | Build Mac only. No mobile impact. |
| **Mobile-only** | `BeeChat-Mobile/` repo only | Build iOS only. No Mac impact. |
| **Shared** | Any of the 3 shared packages | **MUST build both Mac AND iOS.** This is the danger zone. |

If you're not sure, it's **Shared** by default.

### Rule 2: Shared Changes Need Dual Validation

Any commit that touches `BeeChatGateway`, `BeeChatPersistence`, or `BeeChatSyncBridge` must pass:

1. `swift build` in BeeChat-v5 (Mac) ✅
2. `swift build` in BeeChat-Mobile (iOS) ✅
3. Mac app launch + handshake test ✅ (if handshake/auth code changed)

**No exceptions.** Not even for "just a version number change."

### Rule 3: Branch Discipline

| Branch | Purpose | Can merge to develop? |
|---|---|---|
| `develop` | Mac baseline — always working | N/A (source of truth) |
| `feature/gate-2f-*` | Mobile work on shared packages | Only after dual validation |
| `feature/gate-2f-unified` | Integrated (shared + Mac features) | Only after dual validation |
| `main` | Release tag point | After Adam approval |

**Never commit mobile-only fixes directly to `develop`.** They go on the feature branch, get dual-validated, then merge.

### Rule 4: Platform Conditionals Go in Shared Code

If a behaviour differs between Mac and iOS, the conditional lives in the shared package:

```swift
#if os(iOS)
    // iOS-specific
#else
    // macOS-specific
#endif
```

**Never** hardcode iOS-only values that would break Mac at runtime (like the protocol version incident).

### Rule 5: The "Mac Works" Gate

Before deploying any build to Adam's iPhone:

1. Mac app builds clean from current branch ✅
2. Mac app launches and connects to gateway ✅
3. THEN build and deploy to iPhone

If Mac doesn't work, the iPhone build doesn't ship. Full stop.

### Rule 6: Team Review for Shared Changes

Kieran's adversarial review should explicitly check:
- "Would this break the other platform?"
- "Are there hardcoded values that assume one platform?"
- "Does this change a shared interface that both apps depend on?"

Mel's review should flag any platform-specific UI assumptions.

---

## What Went Wrong This Morning (Post-Mortem)

The protocol version was bumped from 3→4 in `ConnectParams.swift` (shared package) to fix the iPhone handshake. The change was correct for iOS. But the Mac app was still expecting protocol v3 on that branch, so it couldn't connect to the gateway either.

**The fix was right. The process was wrong.** The change needed dual validation before deployment, and it didn't get it.

---

## Checklist for Q (Implementation)

When implementing any BeeChat change:

- [ ] Which files am I touching? (Mac-only / Mobile-only / Shared)
- [ ] If Shared: does Mac still build? `swift build` in BeeChat-v5
- [ ] If Shared: does iOS still build? `swift build` in BeeChat-Mobile
- [ ] If Shared: does Mac still connect to gateway? (handshake test)
- [ ] Have I added any platform-specific values without `#if os()` guards?

## Checklist for Bee (Coordination)

Before telling Adam a build is ready:

- [ ] Mac builds clean from the target branch
- [ ] Mac launches and connects to gateway
- [ ] iOS builds clean (simulator or device)
- [ ] Both builds use the same shared package commit

---

## Open Questions for Adam

1. **OK to merge shared package fixes (protocol v4, AnyCodable iOS fix) back into develop?** These improve both platforms.
2. **OK to merge the topic-project-binding changes on unified into develop?** They're Mac-only (`Sources/App/`) plus small shared additions (Topic model, TopicRepository).
3. **Should `feature/gate-2f-unified` become the new Mac baseline** once it's fully validated, so we stop working off diverged branches?
