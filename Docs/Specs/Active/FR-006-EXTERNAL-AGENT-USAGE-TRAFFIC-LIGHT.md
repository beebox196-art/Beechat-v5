# FR-006 — External Agent Usage Traffic-Light

**Status:** Proposed (not yet scheduled)
**Date:** 2026-08-14
**Author:** Bee (spec) / Adam Box (feature request)
**Project:** BeeChat-v5 (macOS app)
**Related:** AgentDrop (inter-agent messaging), Team Activity popup

---

## 1. Summary

Show live usage / remaining allowance for the external agents (Claude, Grok,
ChatGPT) inside BeeChat's **Team Activity** popup, as a per-agent traffic-light
(green / amber / red). The goal is a visible at-a-glance view of how much
bandwidth each external agent has left, as we lean harder into the AgentDrop
approach and push more volume through the external agents.

**Primary consumer:** Adam, visual glance.
**Secondary (future):** AgentDrop routing — prefer the agent with most headroom.

---

## 2. Background & Motivation

- We are starting to use the external agents (Claude, Grok, ChatGPT) much more
  heavily as part of the AgentDrop approach.
- Each provider has its own usage/allowance model, and hitting a limit mid-task
  is disruptive.
- A visible "how much have I got left" per agent lets Adam see at a glance who
  is near a wall before dispatching work.
- **Compounding win:** once all agents are on AgentDrop, live headroom data can
  feed the router so it prefers whichever agent has bandwidth. This is the
  higher-value outcome and should be kept in mind during design (expose the
  underlying numbers, not just a colour).

---

## 3. Scope

### In scope
- Poll external-agent usage endpoints on a schedule (hourly during the day).
- Map each provider's usage data to a normalised traffic-light state.
- Display the traffic-light per agent in the Team Activity popup.
- Show reset time where available (e.g. "red — resets 5:20pm").

### Out of scope (phase 2)
- AgentDrop routing integration (design should not preclude it).
- Percentage/headroom numbers for providers that don't expose them cleanly.

---

## 4. Requirements

### 4.1 Display
- **Traffic-light per agent:** green / amber / red.
- **Surface:** Team Activity button in the BeeChat sidebar → popup.
- **Reset time** shown alongside the colour where the provider exposes it.
- **Granularity:** traffic-light only (no raw numbers required for the display).

### 4.2 Thresholds (agreed)
- **Green:** > 40% headroom
- **Amber:** 20–40% headroom
- **Red:** < 20% headroom (or at/near limit)

### 4.3 Polling
- **Cadence:** hourly during the day.
- **Mechanism:** poll the provider endpoints; they are not push.

### 4.4 Data model (design intent)
- Normalise each provider to a common shape so new providers slot in as new
  data sources. Keep the underlying numbers available (even if not displayed)
  to leave the routing door open.

---

## 5. Provider Feasibility (from spike, 2026-08-14)

### 5.1 Claude — SPIKE DONE, pattern proven
- **Command:** `claude usage` (CLI v2.1.221, local).
- **Result (at limit, 2026-08-14 ~17:09):**
  ```
  You've hit your session limit · resets 5:20pm (Europe/London)
  ```
- **Findings:**
  - Endpoint works, reachable, no auth errors. Pattern is viable. ✅
  - Output is **plain text, not JSON** — `--output json` / `--json` flags do
    not exist in this CLI version. We parse the human-readable line (regex),
    not JSON.
  - Exposes **limit state** (hit / not hit) + **reset time**. ✅
  - Does **NOT** expose a **percentage / headroom number**. ⚠️
- **Traffic-light mapping for Claude:**
  - **Red** = "You've hit your session limit" (directly observable). ✅
  - **Green/Amber** = not at limit, but **cannot distinguish green from amber**
    without a percentage we don't currently get. ⚠️
- **Open question:** the Claude app shows "X% used in last 5 hours", so the
  percentage exists somewhere. Not found in `~/.claude/` obvious locations or
  via CLI flags in this version. **Phase-2 refinement:** hunt the percentage
  (Claude API directly, or a newer CLI flag/version), or accept a 2-state light
  for Claude initially.

### 5.2 Grok (SuperGrok) — NOT SPIKE DONE
- Sole credential is SuperGrok OAuth (used by Sag Twitter Scout).
- Quota info is less standardised; historically tied to rate limits and weekly
  resets. Likely the fiddliest of the three.
- **Phase 2:** investigate once the Claude pattern is proven.

### 5.3 ChatGPT (Plus, gpt-5.4-mini via OAuth) — NOT SPIKE DONE
- Limits are message-based (messages per 3-hour / per-week window depending on
  plan and model tier).
- Least documented of the three to pull programmatically; numbers shift with
  plan changes.
- **Phase 2:** investigate once the Claude pattern is proven.

---

## 6. Recommended Build Path

1. **Spike Claude (DONE).** Confirms the pattern end-to-end: poll → traffic-light
   → display. De-risks the whole feature.
2. **Spec + build the BeeChat side** (Team Activity popup UI + hourly poller)
   against the Claude data model, designed so Grok/ChatGPT slot in as new data
   sources later.
3. **Grok/ChatGPT as phase 2.** Once the pattern is proven and all agents are on
   AgentDrop, use the agents themselves to help wire their own backends (they
   know their own APIs best).

---

## 7. Open Questions / Decisions Needed

1. **Amber state for Claude:** accept a 2-state light initially (red = at limit,
   green = not at limit) and treat the percentage as phase-2? Or spend one more
   probe hunting the percentage before building?
2. **Grok/ChatGPT data sources:** to be investigated in phase 2; exact endpoints
   and units TBD.
3. **Routing integration:** confirm whether AgentDrop routing should consume
   this data in phase 2 (design keeps the door open either way).

---

## 8. Acceptance Criteria (draft)

- [ ] Team Activity popup shows a traffic-light per external agent.
- [ ] Claude state is polled hourly and reflects the live limit state.
- [ ] Red state shows the reset time where available.
- [ ] New providers (Grok, ChatGPT) can be added as new data sources without
      reworking the display layer.
- [ ] Underlying headroom numbers are retained in the data model (even if not
      displayed) to support future routing.

---

## 9. Notes

- This spec is parked until AgentDrop is fully wired for all agents, at which
  point the agents themselves can help develop the feature.
- Thresholds (green >40% / amber 20–40% / red <20%) agreed with Adam on
  2026-08-14.
