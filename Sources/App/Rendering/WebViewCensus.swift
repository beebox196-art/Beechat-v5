import Foundation
import os

/// Live census of WebView mount/teardown churn.
///
/// Tracks three counts: total mounts, total teardowns, and currently-alive
/// WebViews. Counters increment on makeNSView and decrement on dismantleNSView.
/// Thread-safe via OSAllocatedUnfairLock; both callsites are main-actor so the
/// lock is uncontended in practice, but the lock makes the contract explicit.
///
/// Exposes a JSON snapshot string for `log show`/manual debugging. Not for
/// production telemetry — this is a targeted instrumentation harness for the
/// v0.9.5f scroll-fix patch series. Remove or move behind a feature flag after
/// R3 (WebContent kills) is empirically resolved.
enum WebViewCensus {
    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "WebViewCensus")
    private struct State { var totalMounts = 0; var totalTeardowns = 0 }

    /// Called from MessageWebView's `makeNSView`. Increments totalMounts and
    /// updates the live count. Logs a one-line INFO-level trace at most once
    /// per 1000 mounts to bound log volume.
    static func recordMount() {
        let snapshot = lock.withLock { state -> (mounts: Int, alive: Int) in
            state.totalMounts += 1
            return (state.totalMounts, state.totalMounts - state.totalTeardowns)
        }
        if snapshot.mounts % 1000 == 0 {
            logger.info("CENSUS mounts=\(snapshot.mounts) alive=\(snapshot.alive)")
        }
    }

    /// Called from MessageWebView's `dismantleNSView`. Increments totalTeardowns.
    /// No throttling — teardowns are usually balanced against mounts, log volume
    /// is bounded by the mount-side throttle.
    static func recordTeardown() {
        lock.withLock { state in state.totalTeardowns += 1 }
    }

    /// Snapshot for `log show`/`log stream` debugging. JSON shape is stable:
    /// { "mounts": Int, "teardowns": Int, "alive": Int }. `alive` is the
    /// derived live count. String is suitable for pasting into a bug report.
    static func snapshot() -> String {
        let (m, t) = lock.withLock { ($0.totalMounts, $0.totalTeardowns) }
        return "{\"mounts\":\(m),\"teardowns\":\(t),\"alive\":\(m - t)}"
    }
}
