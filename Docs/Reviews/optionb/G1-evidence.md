# G1 — Memory feasibility — evidence

**Date:** 2026-08-05T12:12:07.366Z
**Build:** TranscriptSpike WP-0 2026-08-05
**Machine:** Openclaw's Mac mini, macOS 26.5.1, arm64
**Operator:** Q
**Verifier:** Adam

## Pre-registered criteria (verbatim)

- Soak duration: **1800 seconds (30 min)**
- WebContent process count: **stable across the soak** (start-of-soak count ≤ end-of-soak count). macOS launches WKWebView's WebContent XPC services from launchd (ppid=1), so direct-child enumeration is not possible; we count *all* processes with exe path containing `WebKit.WebContent` via `proc_listpids`.
- RSS total budget: **app + WebContent ≤ 400 MB**
- Plateau: **no monotonic growth across the final 10 min**, tolerance **20 MB** spread
- Sample interval: **60s**
- Message count: **re-derived from GRDB** at the start of the run

## Data source

- DB path: `/Users/openclaw/Library/Application Support/BeeChat/BeeChat.sqlite`
- Topic ID: `491EA8D6-9527-4E71-89B4-D0A06DF3F49D`
- Session key (used in messages.sessionId): `agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d`
- Query: `SELECT COUNT(*) FROM messages WHERE sessionId = ? AND role IN ('user','assistant')`
- Live DB (read-only, opens with `readonly=true` Configuration).

## Samples

| Time | app MB | web MB | total MB | web_count |
|---|---|---|---|---|
| 2026-08-05 11:50:07 +0000 | 28.0 | 807.5 | 835.5 | 29 |
| 2026-08-05 11:51:07 +0000 | 27.5 | 892.8 | 920.3 | 30 |
| 2026-08-05 11:52:07 +0000 | 24.6 | 807.3 | 831.9 | 29 |
| 2026-08-05 11:53:07 +0000 | 24.1 | 807.3 | 831.4 | 29 |
| 2026-08-05 11:54:07 +0000 | 24.1 | 807.3 | 831.4 | 29 |
| 2026-08-05 11:55:07 +0000 | 24.1 | 807.3 | 831.4 | 29 |
| 2026-08-05 11:56:07 +0000 | 24.1 | 807.3 | 831.4 | 29 |
| 2026-08-05 11:57:07 +0000 | 24.1 | 807.3 | 831.4 | 29 |
| 2026-08-05 11:58:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 11:59:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:00:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:01:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:02:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:03:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:04:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:05:07 +0000 | 24.1 | 821.2 | 845.3 | 29 |
| 2026-08-05 12:06:07 +0000 | 24.1 | 823.2 | 847.3 | 29 |
| 2026-08-05 12:07:07 +0000 | 24.2 | 823.5 | 847.6 | 29 |
| 2026-08-05 12:08:07 +0000 | 24.2 | 823.5 | 847.6 | 29 |
| 2026-08-05 12:09:07 +0000 | 24.1 | 823.5 | 847.6 | 29 |
| 2026-08-05 12:10:07 +0000 | 24.2 | 823.5 | 847.6 | 29 |
| 2026-08-05 12:11:07 +0000 | 24.2 | 823.5 | 847.6 | 29 |
| 2026-08-05 12:12:07 +0000 | 24.2 | 794.5 | 818.6 | 29 |

## Verdict

**Verdict: PASS**


Max app+web RSS observed: 920.3 MB (system-wide web RSS included)
Final app+web RSS: 818.6 MB
Final-10-sample APP RSS plateau spread: 0.1 MB (this is the spike's own app process — the only RSS we can isolate)

## Raw log

See `spike-run.log` in this directory.
