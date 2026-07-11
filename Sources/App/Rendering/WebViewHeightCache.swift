import Foundation

/// Last accepted WebView content height per message, keyed by the layout
/// inputs that determine it. Lets settled bubbles mount at their true height
/// instead of the 40pt seed, so topic-open content size is approximately
/// right before any WebContent process has spun up.
///
/// In-memory only — heights are cheap to re-measure across launches.
final class WebViewHeightCache {
    static let shared = WebViewHeightCache()

    private struct Entry { var height: CGFloat; var width: CGFloat; var fontScale: CGFloat }
    private var store: [String: Entry] = [:]
    private let lock = NSLock()

    /// Approximate seed for cold-mount. Intentionally does not validate width or
    /// fontScale — a stale-width seed is still an order of magnitude closer to
    /// truth than the 40pt floor, and the first honest report from the WebView
    /// corrects it within a frame of WebKit spin-up. Per spec amendment
    /// (Bee, 2026-07-11): the verbatim fontScale check was dropped; approximate
    /// seeding is the point, correctness comes from the transactional reporter.
    func seed(id: String) -> CGFloat? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[id] else { return nil }
        return e.height
    }

    /// Record the most recent honest height measurement for this id. Safe to
    /// call from any thread; `NSLock` serialises all store access.
    func record(id: String, height: CGFloat, width: CGFloat, fontScale: CGFloat) {
        lock.lock(); defer { lock.unlock() }
        // Crude cap; heights are free to re-measure next time a WebView mounts.
        if store.count > 2000 { store.removeAll() }
        store[id] = Entry(height: height, width: width, fontScale: fontScale)
    }
}
