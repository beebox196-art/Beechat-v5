# Phase 0 Research Plan — BeeChat v5

**Created:** 2026-04-17  
**Timebox:** 4 hours (initial survey)  
**Owner:** Bee (Coordinator) → Gav (Research)  
**Status:** Not started

---

## Research Goals

Answer these questions before any build work:

1. **Persistence Layer**
   - What's the best SQLite + Swift pattern for message storage?
   - GRDB vs. SQLite.swift vs. CoreData for our use case?
   - Prior art: ClawChat, other Swift chat clients

2. **Gateway/WebSocket Layer**
   - OpenClaw WebSocket API spec (from docs + ClawChat implementation)
   - Session management, heartbeat, reconnection patterns
   - Prior art: ClawChat's working implementation

3. **UI Architecture**
   - SwiftUI NavigationSplitView patterns for chat
   - Message list performance (lazy loading, pagination)
   - Prior art: ClawChat, other SwiftUI chat apps

4. **OpenClaw Integration**
   - Device identity and token auth (from v4 learnings)
   - Session routing, topic handling
   - Plugin hooks available?

---

## Research Sources

### Must-Study (Validated Prior Art)
- [ ] ClawChat (`ngmaloney/clawchat`) — Working OpenClaw Swift client
- [ ] OpenClaw docs — WebSocket API, session routing, device pairing
- [ ] GRDB documentation — SQLite best practices for Swift

### Secondary Sources
- [ ] SwiftUI chat app tutorials/patterns
- [ ] WebSocket best practices in Swift
- [ ] OpenClaw extension source (device-pair plugin)

---

## Deliverables

1. **Research Report** (`PHASE0-RESEARCH-REPORT.md`)
   - Summary of findings per goal area
   - Recommended patterns/repos to adapt
   - Attribution list for adapted code

2. **Shoulders Index Updates**
   - Add validated repos to `knowledge/Operations/SHOULDERS-INDEX.md`

3. **Build Plan**
   - Component-by-component build sequence
   - Estimated time per component
   - Risk assessment

---

## Timebox Enforcement

- **2 hours:** Initial survey complete
- **4 hours:** Report draft ready
- **Stop:** If approaching 4 hours without clarity, escalate to Adam for decision: extend research or pivot to build

---

## Success Criteria

Research is complete when:
- [ ] We know which persistence library to use (with rationale)
- [ ] We understand OpenClaw WebSocket API fully
- [ ] We have ClawChat code paths identified for adaptation
- [ ] Build plan is clear and sequenced
- [ ] Attribution tracker is ready
