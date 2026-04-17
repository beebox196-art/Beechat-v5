# BeeChat v5

Modular, component-isolated chat client for OpenClaw. macOS-first, iOS-ready.

## ⚠️ Research-First Gate (READ FIRST)

**Before any build work:** Complete Phase 0 Prior Art Survey.
- See: `knowledge/Operations/RESEARCH-FIRST-FRAMEWORK.md`
- Research report required before code
- Reinvention timebox: 2 days max
- Track attributions: `knowledge/Operations/ATTRIBUTIONS.md`

---

## Quick Links
- [Status](./STATUS.md) — Current phase, blockers, priorities
- [Vision](./Docs/Vision/) — Goals and roadmap
- [Architecture](./Docs/Architecture/) — Technical design
- [History](./Docs/History/) — How we got here

## Structure
```
BeeChat-v5/
├── STATUS.md              # 30-second briefing (UPDATE THIS)
├── README.md              # This file
├── Docs/
│   ├── Vision/            # Goals, roadmap, AOS vision
│   ├── Architecture/      # Technical specs, design
│   ├── Decisions/         # ADRs (Architecture Decision Records)
│   ├── History/           # Development history, session summaries
│   └── Status/            # Build status, handoff notes
├── Sources/
│   ├── Persistence/       # Component 1: SQLite message storage
│   ├── Gateway/           # Component 2: WebSocket connection
│   ├── UI/                # Component 3: SwiftUI views
│   └── App/               # Component 4: Assembly
└── Tests/
    ├── Persistence/       # Persistence tests
    ├── Gateway/           # Gateway tests
    └── UI/                # UI tests
```

## How We Work
See [PROJECT-PATTERNS.md](../../.openclaw/workspace/PROJECT-PATTERNS.md) for the team's working patterns.

## Key Decisions
- **Modular architecture** — v4's monolithic approach caused cascading failures; v5 isolates components
- **Test in isolation first** — Each component must pass tests before assembly
- **Research before build** — Phase 0 survey mandatory (v4 wasted weeks on reinvention)
- **macOS-first** — iOS follows after macOS stable (90%+ code reuse target)

## Getting Started
1. Complete Phase 0 research (in progress)
2. Review architecture docs
3. Set up Xcode project
4. Build Component 1: Persistence (tested in isolation)

---
*Created from project template. Update STATUS.md immediately after project creation.*
