# Empirical Findings — WebView Population, 2026-07-11 Session

**Author:** Bee (manual log inspection)
**Date:** 2026-07-11, 17:25 BST
**Source:** unified log via `/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961'`
**App version:** 0.9.5e (2026.07.11-scroll, manual-test build)
**Window sampled:** 16:24:06 – 16:50:41 BST (≈26 minutes of active session)
**Status:** raw findings, prior to any code changes for v0.9.5f

---

## Counts

| Metric | Count | Rate | Significance |
|---|---:|---:|---|
| WebContent processes spawned (`Installed launch log hook`) | 79 | ~3/min | Heavy WebView population |
| WebContent XPC connection invalidations (system-level exit signal) | 44 | ~1.7/min | 56% spawn-kill ratio over window |
| **Swift `webViewWebContentProcessDidTerminate` delegate fires** | **0** | 0 | **R3 cycle not directly observed via Swift** |
| HTMLMessageConverter "nodes/depth cap exceeded → WebView" bail-outs | 78 | ~3/min | Native converter giving up — **W4 finding operationalised** |
| BeeChat.app MessageTemplate resource-bundle misses | 1 | — | Using embedded fallback (expected) |
| Live WebContent processes at sample time | 17 | — | Mix of `WebContent.xpc` (4) and `EnhancedSecurity.xpc` (13) |

## Live WebContent distribution at sample time (RSS)

| Service | Count | Avg RSS | Max RSS | Notes |
|---|---:|---:|---:|---|
| `com.apple.WebKit.WebContent.xpc` (regular) | 4 | ~44 MB | ~50 MB | Likely serves MessageWebView instances |
| `com.apple.WebKit.WebContent.EnhancedSecurity.xpc` | 13 | ~15 MB | ~16 MB | Lighter sandboxed variant; matches the launchservicesd-connection-prohibited pattern |

The EnhancedSecurity processes were the ones hitting "CONNECT: Attempt to connect to launchservicesd prohibited" (78 occurrences) — a known WebKit-on-Sonoma quirk (rdar://28724618) — followed shortly after by XPC connection invalidation. The regular `WebContent.xpc` processes are heavier and more stable.

## What this tells us

### Confirms
- **§5 strategic flag from Fable's RCA is urgent, not optional.** The 78 HTMLMessageConverter bail-outs in 26 minutes is exactly the "send every table to a permanent WKWebView" structural pattern Fable flagged. Native table rendering (SwiftUI `Grid`) reduces the WebView population from dozens-per-topic to single-digits-per-topic — eliminating R1/R2/R3 surface area simultaneously.
- **WebView population is structurally high.** 79 spawn events over 26 minutes = ~3 WebViews created per minute. This explains the topic-open storm symptom Adam reported.
- **W4's "~26 MB per WebContent process" arithmetic is a low estimate.** Real-world RSS on regular `WebContent.xpc` is 30–50 MB. Per-topic memory cost for a 30-bubble topic ≈ 1–1.5 GB resident WebContent processes alone.

### Contradicts / Demotes
- **R3 (post-kill collapse cycle) is demoted from "likely" to "secondary / possible."** The Swift delegate that R3 depends on (`MessageWebView.swift:198`, `webViewWebContentProcessDidTerminate`) has fired **zero times** in the sampled session, despite 44 system-level WebContent XPC exits. Three possible explanations, in order of plausibility:
  1. **The dying processes are EnhancedSecurity.xpc, not the regular WebContent.xpc that serve MessageWebView.** The EnhancedSecurity pattern (launchservicesd-prohibited → XPC exit) is a separate WebKit subsystem, possibly tied to background tabs / prefetch / extension content. This matches the RSS distribution (EnhancedSecurity processes are lighter and more numerous).
  2. **LazyVStack tears down WebViews before the death callback fires**, so the handler never gets a chance to log.
  3. **The Swift log line isn't landing in unified log** despite `Logger.error` (unlikely — we see other `com.beebox.beechat:*` logs at full fidelity).

- **The "flash-then-disappear" symptom (Adam's #4) has at most one of three possible mechanisms, not two:**
  - R3 kill cycle: demoted.
  - R1+R2 height collapse: still viable; changes 1–2 will catch this.
  - WebView destroy/recreate on SwiftUI re-render: untested but unlikely given LazyVStack retention (W4 finding).

### Does NOT change
- Fable's prescription Changes 1–3 are correct in shape regardless of R3 status.
- R1 (empty-document zero) and R2 (wrong-width report) fire independently of process kills — both are bugs that happen on every single WebView mount. The transactional report shape (Change 1) and width-matched acceptance (Change 2) fix these directly.
- Change 3 (height cache for settled messages) reduces the topic-open storm regardless of mechanism.

## What to do next

1. **Push back to Fable on R3 framing.** Share the zero-delegate-fire finding. Ask: (a) is the launchservicesd-prohibited pattern really in the MessageWebView pipeline, or in a separate WebKit subsystem? (b) should the Swift delegate be hardened regardless (e.g. by adding KVO on `webView.title` or polling `webView.bounds`) so we have direct evidence either way?

2. **Build v0.9.5f from Fable's prescription, justified against R1+R2 not R3.** Changes 1–3 land together with the live-WebView census instrumentation (Change 4). Census will give us empirical data on MessageWebView instance count specifically, which we don't have yet.

3. **Take §5 (native Grid table rendering) to spec-pack status separately.** The 78 bail-outs in 26 minutes is the data point that makes §5 the next architectural conversation, not a future one. But don't bundle it into v0.9.5f — it's a different scope and warrants its own brief.

4. **Re-run the log check on a v0.9.5f session** to compare against these baselines. Specifically: do HTMLMessageConverter bail-outs decrease (with native Grid), does the live-WebContent count change, does `webViewWebContentProcessDidTerminate` ever fire?

---

## Reproduction commands

```bash
# Full BeeChat unified log (processIdentifier required — bundle ID not set on the app)
/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961'

# Converter bail-outs (HTMLMessageConverter fallback)
/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961' | grep "HTML walk bailed out"

# WebContent spawn events
/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961' | grep "Installed launch log hook"

# WebContent exit events
/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961' | grep "XPC message reply connection invalidated"

# Swift-side terminate handler fires (should be 0 in baseline)
/usr/bin/log show --last 12h --info --predicate 'processIdentifier == 91961' | grep "WebContent process terminated"

# Live WebContent snapshot
ps -ax -o pid,rss,command | grep "WebKit.*WebContent" | grep -v grep
```

Note: the `subsystem == "com.beebox.beechat"` predicate Fable suggested does not work because the installed app has no bundle identifier set in Info.plist (a separate small bug). Use `processIdentifier` with the live PID, or restart with bundle-id fix to enable subsystem-predicate queries.