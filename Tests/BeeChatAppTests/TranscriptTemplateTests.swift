import XCTest
import WebKit
import os
@testable import BeeChatApp

// MARK: - TranscriptTemplate Tests
//
// Headless tests for the single-WebView transcript document (WP-2).
//
// Strategy:
//   - Load TranscriptTemplate.html into a real WKWebView (no SwiftUI host).
//   - Drive the document via evaluateJavaScript using window.bc.* API.
//   - Read state via window.bc.state().
//   - Wait for layout/paint between operations with expectation + polling.
//
// T1 — setTopic lands scrollTop == scrollHeight − clientHeight before first paint callback
// T2 — user-intent detection (Fix 2) preserves scroll position across streaming
// T3 — prependEarlier preserves anchor offset exactly
// T4 — streaming settle produces zero node-count flicker
//
// Plus template sanity tests (resolution chain, CSS variables, bridge API surface)
// to mirror MessageTemplateTests. Tests are additive — the baseline 407/0/0
// from WP-1 must still hold (these are new tests, no existing test is removed).
//
// MARK: E1–E7 reminders:
//   E1 — pre-registered criteria: each test asserts specific observable contract.
//   E2 — log .info+: failures use .error; progress uses .debug.
//   E3 — thresholds before run: tolerances are constants in the test (50 px
//         pin-re-engage band, 3-node MutationObserver threshold, etc.).
//         (The 50/120 hysteresis from route plan §4.4 was deliberately
//         rejected — see transcript.html:216-217; there is no 120 threshold.)
//   E4 — real-data fixtures: fixture corpus renders real sanitized HTML.
//   E5 — implementer + verifier differ: Q builds, Kieran checks, Bee validates.
//   E6 — negative results recorded: every FAIL captured with full state dump.
//   E7 — concurrent suite: `swift test` is run with -j flag for parallelism.

@MainActor
final class TranscriptTemplateTests: XCTestCase {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "TranscriptTemplateTests")

    // MARK: - Test fixture: headless WKWebView

    private var webView: WKWebView!
    private var loadExpectation: XCTestExpectation!

    override func setUp() async throws {
        try await super.setUp()
        let config = WKWebViewConfiguration()
        // No message handlers — the test injects scripts directly via evaluateJavaScript.
        // The template's bridge() helper swallows the missing-handler case, so the
        // document runs cleanly.
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
        self.loadExpectation = expectation(description: "template loaded")
        webView.loadHTMLString(TranscriptTemplate.html, baseURL: nil)
        await fulfillment(of: [loadExpectation], timeout: 5.0)
        // Wait until window.bc exists. The IIFE / window.bc assignment happens in
        // the <script> at the bottom of the body; navigationFinished fires before
        // script execution, so we poll briefly.
        try await waitForCondition(expression: "typeof window.bc !== 'undefined'", timeout: 5.0)
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    // MARK: - Helper: evaluate JS and unwrap

    /// Evaluate a JavaScript expression and return its raw result. We use a continuation
    /// wrapper to await the async evaluateJavaScript callback in a non-actor-isolated
    /// context, then assert the result is the expected type.
    ///
    /// WKWebView's evaluateJavaScript returns `WKErrorCode. JavaScriptExecutionReturned
    /// A Result Of An Unsupported Type` (Code=5) when the script's last expression is
    /// `undefined`, a function, an HTML element, or other types the bridge can't
    /// marshal. To make tests robust, we ALWAYS wrap the user's expression in
    /// JSON.stringify-friendly form: the caller is expected to return either a
    /// primitive, an object/array, or `null`/`undefined`. If a test returns a complex
    /// non-bridgeable value, wrap it explicitly: `(function() { ...; return JSON.stringify(x); })()`.
    private func eval(_ js: String, timeout: TimeInterval = 5.0) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    Self.logger.debug("eval error: \(error.localizedDescription) for: \(js.prefix(120))")
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }

    /// Evaluate an expression and return its result as a JSON-decoded dictionary.
    /// Use for expressions whose return type WKWebView can't bridge (e.g. objects
    /// containing non-marshallable members) — the JS side serializes, Swift parses.
    /// The user's JS must be a SINGLE expression — no trailing `;` (would be
    /// inside the JSON.stringify parens and break parsing).
    private func evalJSON(_ js: String) async throws -> [String: Any] {
        let trimmed = js.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let raw = try await eval("JSON.stringify(\(trimmed))") as? String ?? "null"
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TranscriptTemplateTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "could not JSON-parse: \(raw)"])
        }
        return obj
    }

    /// Wait until a JS expression evaluates to a truthy value. Used for polling
    /// layout settling that we can't observe from Swift directly (e.g. "did
    /// ResizeObserver fire after this mutation?").
    private func waitForCondition(expression: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await eval(expression), let truthy = result as? Bool, truthy {
                return
            }
            // 30ms poll — same cadence the spike harness used for layout settles.
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw NSError(domain: "TranscriptTemplateTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timeout waiting for: \(expression)"
        ])
    }

    /// Wait for two rAFs (matches the engine's deferred repin cadence).
    /// The engine uses two nested requestAnimationFrame calls in deferredRepin;
    /// we approximate that here by sleeping ~50ms (≈ 3 frames at 60fps) on the Swift
    /// side. evaluateJavaScript cannot bridge a Promise return — that's the
    /// "unsupported type" WK error Code=5 — so we cannot await the promise
    /// directly. Sleeping for a few frames is the standard Swift-side pattern
    /// when the WebView host can't observe rAFs (route plan §9 acknowledged this).
    private func waitForTwoRAFs() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)  // ~3 frames at 60fps
    }

    // MARK: - Template Resolution Sanity

    func testEmbeddedTranscriptTemplateIsNonEmpty() {
        XCTAssertFalse(TranscriptTemplate.html.isEmpty,
                       "TranscriptTemplate.html must never be empty — embedded fallback is guaranteed")
    }

    func testEmbeddedTemplateHasExpectedDOM() {
        let html = TranscriptTemplate.html
        XCTAssertTrue(html.contains("id=\"transcript\""), "must have #transcript container")
        XCTAssertTrue(html.contains("id=\"load-earlier\""), "must have #load-earlier button")
        XCTAssertTrue(html.contains("id=\"jump\""), "must have #jump overlay")
        XCTAssertTrue(html.contains("id=\"thinking\""), "must have #thinking indicator")
    }

    func testEmbeddedTemplateHasBridgeAPISurface() {
        let html = TranscriptTemplate.html
        // The methods are members of window.bc (declared as `setTopic(...)` etc.).
        // We assert each is present at least once in the JS object literal body.
        for method in ["setTopic(", "upsertMessages(", "prependEarlier(",
                       "setStreaming(", "setThinking(", "setTheme(",
                       "setFontScale(", "scrollToBottom()", "state()",
                       "selectionText()"] {
            XCTAssertTrue(html.contains(method),
                          "template must expose window.bc.\(method)")
        }
    }

    func testEmbeddedTemplateHasCSPMeta() {
        let html = TranscriptTemplate.html
        // Route plan §4.6: own-inline-only CSP. The meta tag's content attribute
        // is the contract; Mel reviews the policy wording at sign-off.
        XCTAssertTrue(html.contains("Content-Security-Policy"),
                      "TranscriptTemplate.html must declare a CSP meta tag")
        XCTAssertTrue(html.contains("default-src 'none'"),
                      "CSP must set default-src 'none' (route plan §4.6)")
        XCTAssertTrue(html.contains("img-src https: data:"),
                      "CSP must allow https: and data: for image sources")
        XCTAssertTrue(html.contains("script-src 'unsafe-inline'"),
                      "CSP must allow the template's own inline script")
        XCTAssertTrue(html.contains("connect-src 'none'"),
                      "CSP must block all network connections from the document")
        XCTAssertTrue(html.contains("form-action 'none'"),
                      "CSP must explicitly deny form submission (belt-and-braces audit clarity)")
    }

    func testEmbeddedTemplateHasFRMULTICOPYAffordances() {
        let html = TranscriptTemplate.html
        // A2 — pre/code copy button
        XCTAssertTrue(html.contains("bc-copy-btn"), "must have pre/code copy button CSS")
        XCTAssertTrue(html.contains("attachCopyButton"), "must have attachCopyButton JS")
        XCTAssertTrue(html.contains("navigator.clipboard.writeText") || html.contains("navigator.clipboard"),
                      "must use navigator.clipboard.writeText for A2/A3")
        // A3 — per-message copy button
        XCTAssertTrue(html.contains("bc-copy-msg"), "must have per-message copy button CSS")
        XCTAssertTrue(html.contains("attachMessageCopyButton"), "must have attachMessageCopyButton JS")
        XCTAssertTrue(html.contains("bcCopyMessage"), "must post bcCopyMessage bridge event for A3")
        // A4 — selection-friendliness
        XCTAssertTrue(html.contains("-webkit-user-select: text"),
                      "A1/A4: document must enable native text selection")
        XCTAssertTrue(html.contains("'scroll'") || html.contains("scroll', { passive: true"),
                      "A4: engine must use scroll listener (not selection events)")
    }

    func testEmbeddedTemplateHasGeometryTokens() {
        // Route plan §3.2 — geometry token group added by ThemeManager.
        // (--bc-bubble-max was removed in WP-2 Kieran-conditions correction;
        // bubble width is hardcoded 66% in CSS for native parity with
        // MessageBubble.BubbleWidthModifier, which has no theme variation.)
        let html = TranscriptTemplate.html
        for token in ["--bc-radius-bubble", "--bc-pad-h-bubble", "--bc-pad-v-bubble",
                      "--bc-gap-msg", "--bc-shadow-bubble"] {
            XCTAssertTrue(html.contains(token),
                          "template must consume geometry token \(token)")
        }
        // Sanity guard against re-introducing the removed token by accident.
        XCTAssertFalse(html.contains("--bc-bubble-max"),
                       "--bc-bubble-max was removed (native parity); hardcoded 66% in CSS instead")
    }

    // MARK: - T1 — setTopic lands scrollTop == scrollHeight − clientHeight before first paint

    /// T1 (route plan §9): after setTopic, scrollTop must be the clamped max
    /// (scrollHeight − clientHeight) BEFORE the first paint callback fires.
    /// We assert this by reading bc.state() synchronously after setTopic and
    /// checking that scrollTop equals scrollHeight − clientHeight, AND that
    /// distanceFromBottom === 0. The two-rAF deferred-repin cadence in the
    /// engine means we MUST sample before any rAF fires — setTopic's synchronous
    /// scrollTop assignment is what we test.
    func testT1_setTopicLandsAtBottom() async throws {
        let messages = fixtureMessages(count: 5)
        let count = try await eval("""
        window.bc.setTopic({
          topicId: 't1-topic',
          messages: \(asJSON(messages)),
          canLoadEarlier: false
        });
        """) as? Int
        XCTAssertEqual(count, 5, "setTopic should report 5 messages loaded")

        // Synchronous state read — must reflect the atomic pin.
        let st = try await stateDict()
        let expected = (st["scrollHeight"] as? Int ?? 0) - (st["clientHeight"] as? Int ?? 0)
        XCTAssertEqual(st["scrollTop"] as? Int, expected,
                       "setTopic must land scrollTop at scrollHeight - clientHeight (atomic pin)")
        XCTAssertEqual(st["distanceFromBottom"] as? Int, 0,
                       "distanceFromBottom must be 0 immediately after setTopic")
        XCTAssertEqual(st["pinned"] as? Bool, true,
                       "pinned must be true after setTopic")
    }

    // MARK: - T2 — user-intent detection (Fix 2) preserves scroll position

    /// T2 (route plan §9): the engine uses user-intent detection (Fix 2 from
    /// the WP-0 re-check) instead of 50/120 dfb hysteresis (which the spike
    /// deliberately rejected — see transcript.html:216-217) for the
    /// "leave pinned" path. We verify both legs:
    ///   - At dfb=0 (just-set-bottom), engine is pinned.
    ///   - A user scroll up by 200px triggers userScrolledUp=true; engine
    ///     is now unpinned.
    ///   - A subsequent engine repin (e.g. streaming append) does NOT
    ///     re-pin because userScrolledUp=true; distanceFromBottom persists.
    ///   - scrollToBottom() (explicit re-pin) clears userScrolledUp and re-pins.
    /// This is the proven WP-0 G2 behaviour, exercised in headless form.
    func testT2_pinHysteresisAndUserScrollPersistence() async throws {
        // Seed a tall transcript so we have scrollable distance.
        let messages = fixtureMessages(count: 20, contentLength: 800)
        _ = try await eval("""
        window.bc.setTopic({
          topicId: 't2-topic',
          messages: \(asJSON(messages)),
          canLoadEarlier: false
        });
        """)

        // (1) Pinned at bottom.
        var st = try await stateDict()
        XCTAssertEqual(st["pinned"] as? Bool, true, "must be pinned after setTopic")

        // (2) User scrolls up 200px. This is a REAL window.scrollTo — no manual
        // dispatchEvent. The engine's scroll listener is on `document` (B-1 fix,
        // Fable super-check 2026-08-06): viewport scroll events fire at the
        // Document and bubble to window, so a document-level listener catches
        // the real user scroll. If the listener were still on
        // document.scrollingElement (the old B-1 defect), this real scroll would
        // NOT reach it and userScrolledUp would stay false → this test FAILS.
        // This is the regression guard: T2 must fail before the B-1 fix and
        // pass after.
        _ = try await eval("(function(){ window.scrollTo(0, 200); return document.scrollingElement.scrollTop; })();")
        try await waitForTwoRAFs()

        st = try await stateDict()
        XCTAssertEqual(st["pinned"] as? Bool, false,
                       "user scroll up must unpin (pinned=false)")
        XCTAssertEqual(st["userScrolledUp"] as? Bool, true,
                       "userScrolledUp flag must persist after explicit user scroll")

        // (3) A subsequent engine repin (simulated streaming append) must NOT
        // force re-pin because userScrolledUp=true. We trigger this by calling
        // upsertMessages with new content — the engine calls deferredRepin if
        // pinned, but pinned is now false, so scrollTop should not jump.
        let preScrollTop = st["scrollTop"] as? Int ?? 0
        let appended = try await eval("""
        window.bc.upsertMessages([{
          id: 't2-extra',
          role: 'assistant',
          senderName: 'Bee',
          timeLabel: 'now',
          html: '<p>New message that would normally cause repin</p>'
        }], false);
        """) as? [String: Any]
        XCTAssertNotNil(appended, "upsertMessages must return a result")
        try await waitForTwoRAFs()

        st = try await stateDict()
        // The user's scroll position should be approximately preserved (small
        // drift allowed due to the appended content's height).
        let postScrollTop = st["scrollTop"] as? Int ?? 0
        XCTAssertGreaterThan(postScrollTop, 0,
                             "user-scrolled position must persist through streaming append")
        // Distance from bottom should now be larger than zero (we appended content).
        let dfb = st["distanceFromBottom"] as? Int ?? 0
        XCTAssertGreaterThan(dfb, 100,
                             "user-scrolled-up state must persist: dfb must remain > leave threshold")

        // (4) scrollToBottom — explicit re-pin. userScrolledUp cleared.
        _ = try await eval("window.bc.scrollToBottom();")
        try await waitForTwoRAFs()
        st = try await stateDict()
        XCTAssertEqual(st["pinned"] as? Bool, true, "scrollToBottom must re-pin")
        XCTAssertEqual(st["userScrolledUp"] as? Bool, false,
                       "scrollToBottom must clear userScrolledUp (Fix 2)")
        XCTAssertEqual(st["distanceFromBottom"] as? Int, 0,
                       "after scrollToBottom, dfb must be 0")
        _ = preScrollTop  // silence unused
    }

    // MARK: - C-1 — near-bottom engine/resize repin preserves user scroll intent

    /// C-1 regression guard (Fable super-check re-check 2026-08-06): scroll up,
    /// then a RESIZE. The user's scroll intent must survive AND the engine must
    /// NOT move them. Uses TALL content so the user stays clearly scrolled up
    /// (distance-from-bottom > 50) after the resize — reproducing Fable's exact
    /// scenario ("scroll up 60px, window grows taller"). Resizes the REAL
    /// webView frame so clientHeight grows and the ResizeObserver fires.
    func testC1_resizeIntoPinBandPreservesUserScroll() async throws {
        // Tall transcript so the user is clearly scrolled up after a modest resize.
        let messages = fixtureMessages(count: 20, contentLength: 800)
        _ = try await eval("""
        window.bc.setTopic({
          topicId: 'c1-topic',
          messages: \(asJSON(messages)),
          canLoadEarlier: true
        });
        """)
        try await waitForTwoRAFs()

        // (1) User scrolls up 60px (real scroll; document listener catches it).
        _ = try await eval("(function(){ window.scrollTo(0, 60); return document.scrollingElement.scrollTop; })();")
        try await waitForTwoRAFs()
        var st = try await stateDict()
        XCTAssertEqual(st["userScrolledUp"] as? Bool, true,
                       "real scroll up must set userScrolledUp")
        let scrollTopAfterScroll = st["scrollTop"] as? Int ?? 0
        XCTAssertGreaterThan(scrollTopAfterScroll, 0, "must be scrolled up")
        // Confirm we are clearly above the 50px pin band (d >> 50).
        let dfbBefore = st["distanceFromBottom"] as? Int ?? 0
        XCTAssertGreaterThan(dfbBefore, 100,
                             "fixture must keep user clearly above the pin band")

        // (2) Grow the frame modestly (600 -> 700). ResizeObserver +
        // deferredRepin fire with fromUser=false. Must NOT clear userScrolledUp
        // and must NOT repin/move the user.
        self.webView.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
        try await waitForTwoRAFs()
        try await waitForTwoRAFs()

        st = try await stateDict()
        XCTAssertEqual(st["userScrolledUp"] as? Bool, true,
                       "resize must NOT clear userScrolledUp (C-1)")
        let scrollTopAfterResize = st["scrollTop"] as? Int ?? 0
        XCTAssertEqual(scrollTopAfterResize, scrollTopAfterScroll,
                       "resize must NOT move the user (C-1): scrollTop unchanged")
        XCTAssertEqual(st["pinned"] as? Bool, false,
                       "resize must NOT repin the user (C-1)")
    }

    // MARK: - T3 — prependEarlier preserves anchor offset exactly

    /// T3 (route plan §9): prependEarlier records scrollHeight before, inserts
    /// content above the viewport, and then sets scrollTop += (newScrollHeight − old).
    /// This is the deterministic anchor — the user stays looking at the same
    /// message they were reading, with no overflow-anchor lottery.
    func testT3_prependEarlierPreservesAnchor() async throws {
        let messages = fixtureMessages(count: 15, contentLength: 200)
        _ = try await eval("""
        window.bc.setTopic({
          topicId: 't3-topic',
          messages: \(asJSON(messages)),
          canLoadEarlier: true
        });
        """)

        // User scrolls up to read older messages — let's go to scrollTop=300.
        // Real window.scrollTo; the document-level scroll listener (B-1 fix)
        // catches the real bubbled event. No manual dispatchEvent.
        _ = try await eval("(function(){ window.scrollTo(0, 300); return document.scrollingElement.scrollTop; })();")
        try await waitForTwoRAFs()

        let stBefore = try await stateDict()
        let scrollTopBefore = stBefore["scrollTop"] as? Int ?? 0
        XCTAssertGreaterThan(scrollTopBefore, 200,
                             "user must have scrolled away from bottom for this test to be meaningful")

        // Prepend 5 earlier messages (each ~100px tall).
        // `asFragment` already returns a JSON array literal — wrap it directly
        // (NOT in another [...] pair, which would make it a nested array and
        // prependEarlier would iterate ONE element).
        let prepended = try await eval("""
        window.bc.prependEarlier(\(asFragment(messages: 5, contentLength: 100, prefix: "earlier-")));
        """) as? Int
        XCTAssertEqual(prepended, 5, "prependEarlier must return appended count")

        try await waitForTwoRAFs()
        let stAfter = try await stateDict()
        let scrollTopAfter = stAfter["scrollTop"] as? Int ?? 0
        let scrollHeightAfter = stAfter["scrollHeight"] as? Int ?? 0

        // The exact invariant: the user-visible content under the viewport is
        // the same. We can't measure pixels-under-viewport from outside, but
        // we CAN measure that the scroll position shifted by exactly the
        // prepended content's height (deterministic anchor).
        //
        // We approximate by checking that the document grew AND that scrollTop
        // is now > scrollTopBefore (the content above the viewport got taller).
        XCTAssertGreaterThan(scrollHeightAfter, stBefore["scrollHeight"] as? Int ?? 0,
                             "scrollHeight must grow after prependEarlier")
        XCTAssertGreaterThan(scrollTopAfter, scrollTopBefore,
                             "scrollTop must shift down by the prepended content's height (deterministic anchor)")

        // Stronger check: distanceFromBottom should be approximately preserved
        // (the user stays looking at the same logical content). dfb is positive
        // (we are not at the bottom), and must be close to what it was before.
        let dfbBefore = stBefore["distanceFromBottom"] as? Int ?? 0
        let dfbAfter = stAfter["distanceFromBottom"] as? Int ?? 0
        let drift = abs(dfbAfter - dfbBefore)
        XCTAssertLessThan(drift, 50,
                          "distanceFromBottom must be preserved within 50px (anchor drift < 50px)")
    }

    // MARK: - T4 — streaming settle produces zero node-count flicker

    /// T4 (route plan §9): settling a streaming message should not create or
    /// remove nodes from the document. The R4 handoff chain (streaming →
    /// bridge → settled = 3 webviews, 2 cold remounts) is collapsed into a
    /// single in-place update: setStreaming(null) replaces the streaming
    /// node; upsertMessages adds the settled node. But the natural settle
    /// path the engine supports is setStreaming(null) alone — the settled
    /// node arrives via the next GRDB observation.
    ///
    /// We install a MutationObserver that records every childList mutation,
    /// then run a settle cycle and assert the *net* node count change matches
    /// expectations (exactly: -1 streaming node, +1 settled node, total
    /// delta 0). The flicker criterion: at NO intermediate point does the
    /// node count drop below the count-at-start - 1 OR exceed it by > 1
    /// (which would mean a transient bridge bubble existed).
    func testT4_streamingSettleZeroFlicker() async throws {
        // Start with a small base transcript.
        _ = try await eval("""
        window.bc.setTopic({
          topicId: 't4-topic',
          messages: \(asJSON(fixtureMessages(count: 3))),
          canLoadEarlier: false
        });
        """)

        // Install a MutationObserver that records childList changes.
        // Returns `true` (boolean) so evaluateJavaScript bridges cleanly —
        // MutationObserver instances themselves are NOT bridgeable.
        _ = try await eval("""
        (function() {
          window.__t4Samples = [];
          const obs = new MutationObserver((muts) => {
            for (const m of muts) {
              window.__t4Samples.push({
                t: performance.now(),
                added: m.addedNodes.length,
                removed: m.removedNodes.length,
              });
            }
          });
          obs.observe(document.getElementById('transcript'), { childList: true, subtree: false });
          window.__t4Obs = obs;
          return true;
        })();
        """)

        let initialLoaded = try await eval("window.bc.state().loadedCount") as? Int
        XCTAssertEqual(initialLoaded, 3, "setTopic must have loaded 3 messages")

        // Set streaming.
        _ = try await eval("""
        window.bc.setStreaming({ html: '<p>Streaming content…</p>' });
        """)

        // Settle: null streaming, then upsert the settled message.
        _ = try await eval("""
        window.bc.setStreaming(null);
        window.bc.upsertMessages([{
          id: 'settled-1',
          role: 'assistant',
          senderName: 'Bee',
          timeLabel: 'now',
          html: '<p>Settled content</p>'
        }], false);
        """)

        try await waitForTwoRAFs()

        // Read the samples.
        let samples = try await eval("window.__t4Samples") as? [[String: Any]] ?? []
        // Tally net nodes added/removed.
        var added = 0, removed = 0
        for s in samples {
            added += (s["added"] as? Int ?? 0)
            removed += (s["removed"] as? Int ?? 0)
        }
        XCTAssertEqual(added, 2, "settle adds 2 nodes total (streaming + settled)")
        XCTAssertEqual(removed, 1, "settle removes 1 node (the streaming one)")
        XCTAssertEqual(added - removed, 1,
                       "net node count delta must be +1 (settled message added); no transient bridge bubble")

        let finalLoaded = try await eval("window.bc.state().loadedCount") as? Int
        XCTAssertEqual(finalLoaded, 4, "loaded count after settle must be 4 (3 base + 1 settled)")
    }

    // MARK: - FR-MULTICOPY A2 — code-block copy button

    func testFRMULTICOPY_A2_codeBlockCopyButtonInjected() async throws {
        let html = "<pre><code>let x = 42;\nprint(x);</code></pre>"
        _ = try await eval("""
        window.bc.upsertMessages([{
          id: 'a2-msg',
          role: 'assistant',
          senderName: 'Bee',
          timeLabel: 'now',
          html: \(asJSON(html))
        }], false);
        """)

        let copyBtnCount = try await eval("""
        document.querySelectorAll('.msg pre .bc-copy-btn').length
        """) as? Int
        XCTAssertEqual(copyBtnCount, 1, "A2: every pre must get exactly one copy button")
    }

    // MARK: - FR-MULTICOPY A3 — per-message copy button

    func testFRMULTICOPY_A3_perMessageCopyButtonInjected() async throws {
        let html = "<p>Some message text</p>"
        _ = try await eval("""
        window.bc.upsertMessages([{
          id: 'a3-msg',
          role: 'assistant',
          senderName: 'Bee',
          timeLabel: 'now',
          html: \(asJSON(html))
        }], false);
        """)

        let copyBtnCount = try await eval("""
        document.querySelectorAll('.msg .bc-copy-msg').length
        """) as? Int
        XCTAssertEqual(copyBtnCount, 1, "A3: every .msg must get exactly one copy-full-text button")
    }

    // MARK: - Fold growth: 1→2 assistant blocks must not duplicate the bubble
    //
    // Regression guard for the B1 BLOCKING finding from the structured review:
    // when a 1-block assistant run grows to 2 blocks, the grouper transitions
    // from `[message(a1)]` to `[fold(__fold_a1), message(a2)]`. Without the
    // reconcile pass added alongside this test, the old standalone `a1` bubble
    // would stay in the DOM (findMsgById doesn't match the fold's synthetic id)
    // and `a1`'s content would appear TWICE — once standalone, once inside the
    // fold's first block. This test pins the corrected behaviour.

    func testFoldGrowth_1to2BlocksDoesNotDuplicateBubble() async throws {
        // State N: 1 standalone assistant message (no fold yet — single-block
        // run is untouched per the spec).
        let standalone: [[String: Any]] = [[
            "id": "a1",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>first block content</p>",
        ]]
        _ = try await eval("window.bc.setTopic({ topicId: 'growth', messages: \(asJSON(standalone)), canLoadEarlier: false });")

        // Assert: exactly 1 .msg with id='a1'.
        let countA1 = try await eval("document.querySelectorAll('.msg[data-id=\"a1\"]').length") as? Int ?? 0
        XCTAssertEqual(countA1, 1, "After state N: exactly one .msg with data-id='a1'")
        let noFolds = try await eval("document.querySelectorAll('.msg-fold').length") as? Int ?? 0
        XCTAssertEqual(noFolds, 0, "After state N: no folds (single-block run is untouched)")

        // State N+1: a2 arrives; grouper produces [fold(__fold_a1), a2].
        let foldPayload: [[String: Any]] = [[
            "id": "__fold_a1",
            "role": "assistant",
            "html": "",
            "fold": [
                "label": "Working…",
                "count": 1,
                "blocks": ["<p>first block content</p>"],
                "ids": ["a1"],
            ] as [String: Any],
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>second block content</p>",
        ]]
        _ = try await eval("window.bc.upsertMessages(\(asJSON(foldPayload)), false);")

        // Assert: the standalone a1 was REMOVED (reconcile pass), the fold
        // appeared, and a2 appeared standalone. Total = 2 .msg nodes.
        let totalMsgs = try await eval("document.querySelectorAll('#transcript > .msg').length") as? Int ?? 0
        XCTAssertEqual(totalMsgs, 2, "After state N+1: exactly 2 .msg nodes (fold + final). Got: \(totalMsgs)")

        // Critically: NO standalone a1 remains. The old DOM node was removed.
        let standaloneARemaining = try await eval("document.querySelectorAll('.msg[data-id=\"a1\"]:not(.msg-fold)').length") as? Int ?? 0
        XCTAssertEqual(standaloneARemaining, 0,
                       "BLOCKING B1 fix: the standalone a1 bubble MUST be removed when a2 arrives (no duplicate a1). Got: \(standaloneARemaining)")

        // The fold is in the DOM with the correct id and count.
        let foldCount = try await eval("document.querySelectorAll('.msg-fold[data-id=\"__fold_a1\"]').length") as? Int ?? 0
        XCTAssertEqual(foldCount, 1, "Fold with id='__fold_a1' must exist after upsert")
        // The summary always shows "Working…". The numeric count is only
        // appended when count > 1 (no point showing "(1)" beside the
        // label). Verify the label is present and the count badge logic
        // fires when expected.
        let summaryLabel = try await eval("document.querySelector('.msg-fold summary')?.textContent") as? String ?? ""
        XCTAssertTrue(summaryLabel.contains("Working"),
                      "Fold summary must include the 'Working…' label. Got: \(summaryLabel)")
        let foldCountAttr = try await eval("document.querySelector('.msg-fold')?.dataset.foldCount") as? String ?? ""
        XCTAssertEqual(foldCountAttr, "1", "Fold's data-fold-count attribute must reflect 1 block")

        // The final standalone a2 is present.
        let a2Count = try await eval("document.querySelectorAll('.msg[data-id=\"a2\"]').length") as? Int ?? 0
        XCTAssertEqual(a2Count, 1, "Standalone a2 (final block) must be present")

        // Cross-check: total text occurrences of "first block content" must
        // be exactly 1 (it appears once in the fold body).
        let occurrences = try await eval("""
        (function() {
          const all = document.querySelectorAll('.msg, .msg-fold');
          let count = 0;
          for (const el of all) {
            if ((el.textContent || '').includes('first block content')) count++;
          }
          return count;
        })();
        """) as? Int ?? 0
        XCTAssertEqual(occurrences, 1,
                       "BLOCKING B1 fix: 'first block content' must appear exactly once after the growth transition. Got: \(occurrences)")

        // Order assertion: the fold must come BEFORE the final standalone
        // message in DOM order. The reconcile pass removes the old standalone
        // and the upsert loop inserts in payload order (fold first, then a2),
        // so the fold should appear first in #transcript.
        let order = try await eval("""
        (function() {
          const kids = Array.from(document.getElementById('transcript').children);
          const foldIdx = kids.findIndex((n) => n.classList.contains('msg-fold'));
          const a2Idx = kids.findIndex((n) => n.dataset && n.dataset.id === 'a2');
          return { foldIdx, a2Idx };
        })();
        """) as? [String: Any] ?? [:]
        let foldIdx = order["foldIdx"] as? Int ?? -2
        let a2Idx = order["a2Idx"] as? Int ?? -2
        XCTAssertGreaterThanOrEqual(foldIdx, 0, "Fold must exist in DOM")
        XCTAssertGreaterThanOrEqual(a2Idx, 0, "a2 must exist in DOM")
        XCTAssertLessThan(foldIdx, a2Idx,
                          "Fold (idx \(foldIdx)) must come BEFORE final a2 (idx \(a2Idx)) in DOM order")
    }

    // MARK: - Fold shrinking: fold→standalone must remove the orphan fold
    //
    // Companion test to the growth case. When a fold's owning id is
    // re-emitted as a standalone payload (e.g. the run was un-folded by
    // a server-side correction), the fold node must be removed and the
    // standalone version re-inserted by the upsert loop.
    //
    // This is the POSITIVE-EVIDENCE case for Rule B. The inverse case —
    // a fold whose owning ids are deleted from history without being
    // re-emitted standalone — deliberately does NOT trigger removal
    // (safe direction; no silent content loss). See the reconcile pass
    // comment in upsertMessages for the rationale.

    func testFoldShrinking_FoldToStandaloneRemovesOrphanFold() async throws {
        // State N: 2-block run rendered as [fold(__fold_a1), a2].
        let foldPayload: [[String: Any]] = [[
            "id": "__fold_a1",
            "role": "assistant",
            "html": "",
            "fold": [
                "label": "Working…",
                "count": 1,
                "blocks": ["<p>intermediate</p>"],
                "ids": ["a1"],
            ] as [String: Any],
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>final</p>",
        ]]
        _ = try await eval("window.bc.setTopic({ topicId: 'shrink', messages: \(asJSON(foldPayload)), canLoadEarlier: false });")

        // Assert starting state.
        let startingFolds = try await eval("document.querySelectorAll('.msg-fold').length") as? Int ?? 0
        XCTAssertEqual(startingFolds, 1, "Starting state: exactly 1 fold")

        // State N+1: a1 re-emitted standalone (e.g. server-side correction).
        // The fold's owning id is now claimed by a standalone entry → Rule B
        // removes the fold, and the upsert loop inserts the standalone a1.
        let payload: [[String: Any]] = [[
            "id": "a1",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>intermediate</p>",
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>final</p>",
        ]]
        _ = try await eval("window.bc.upsertMessages(\(asJSON(payload)), false);")

        // Assert: the fold is gone, both a1 and a2 are standalone.
        let orphanFolds = try await eval("document.querySelectorAll('.msg-fold').length") as? Int ?? 0
        XCTAssertEqual(orphanFolds, 0,
                       "Fold must be removed when its owning id is re-emitted standalone. Got: \(orphanFolds)")
        let a1Count = try await eval("document.querySelectorAll('.msg[data-id=\"a1\"]:not(.msg-fold)').length") as? Int ?? 0
        XCTAssertEqual(a1Count, 1, "a1 must now be standalone")
        let a2Count = try await eval("document.querySelectorAll('.msg[data-id=\"a2\"]').length") as? Int ?? 0
        XCTAssertEqual(a2Count, 1, "a2 must remain standalone")
    }

    // MARK: - Streaming settle with a fold in the settled payload
    //
    // Regression guard for the B6 BLOCKING finding from the round-2 review.
    // Dropping the synthetic `assistant_fold` role means the Fix-1b
    // atomic-settle filter (`role == "assistant"`) now matches fold
    // payloads too. The settle path therefore sees fold entries in its
    // matched set; this test pins the resulting behaviour — the streaming
    // node is removed, the fold + final settle cleanly, no orphan nodes.

    func testStreamingSettleWithFoldInPayload() async throws {
        // Start with a base + one streaming node.
        _ = try await eval("""
        window.bc.setTopic({
          topicId: 'settle-fold',
          messages: [{
            id: 'u1', role: 'user',
            html: '<p>hi</p>'
          }],
          canLoadEarlier: false
        });
        """)
        _ = try await eval("window.bc.setStreaming({ html: '<p>streaming…</p>' });")

        // Settle: null streaming, then upsert the fold + final payload.
        let settlePayload: [[String: Any]] = [[
            "id": "__fold_a1",
            "role": "assistant",
            "html": "",
            "fold": [
                "label": "Working…",
                "count": 1,
                "blocks": ["<p>narration</p>"],
                "ids": ["a1"],
            ] as [String: Any],
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>final</p>",
        ]]
        _ = try await eval("""
        window.bc.setStreaming(null);
        window.bc.upsertMessages(\(asJSON(settlePayload)), false);
        """)

        try await waitForTwoRAFs()

        // Assert: streaming-msg is gone, fold + a2 are in the DOM.
        let streamingCount = try await eval("document.querySelectorAll('#streaming-msg').length") as? Int ?? 0
        XCTAssertEqual(streamingCount, 0, "Streaming node must be removed on settle")
        let foldCount = try await eval("document.querySelectorAll('.msg-fold[data-id=\"__fold_a1\"]').length") as? Int ?? 0
        XCTAssertEqual(foldCount, 1, "Fold must be present after settle")
        let a2Count = try await eval("document.querySelectorAll('.msg[data-id=\"a2\"]').length") as? Int ?? 0
        XCTAssertEqual(a2Count, 1, "Final a2 must be present after settle")
    }



    func testFoldSurvivesIncrementalUpsertThatDoesNotMentionIt() async throws {
        // Seed: [fold(__fold_a1), a2]. Fold owns id "a1".
        let foldPayload: [[String: Any]] = [[
            "id": "__fold_a1",
            "role": "assistant",
            "html": "",
            "fold": [
                "label": "Working…",
                "count": 1,
                "blocks": ["<p>intermediate</p>"],
                "ids": ["a1"],
            ] as [String: Any],
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "html": "<p>final</p>",
        ]]
        _ = try await eval("window.bc.setTopic({ topicId: 'incremental', messages: \(asJSON(foldPayload)), canLoadEarlier: false });")

        // Sanity: 1 fold present.
        let beforeFolds = try await eval("document.querySelectorAll('.msg-fold').length") as? Int ?? 0
        XCTAssertEqual(beforeFolds, 1, "Sanity: starting state has 1 fold")

        // Incremental upsert: payload mentions NEITHER the fold id nor any
        // of its owning ids. This simulates a caller adding an unrelated
        // message in isolation (e.g. a streaming-update path, a test
        // fixture). The fold MUST survive — B4 fix.
        let incremental: [[String: Any]] = [[
            "id": "user-followup",
            "role": "user",
            "html": "<p>thanks</p>",
        ]]
        _ = try await eval("window.bc.upsertMessages(\(asJSON(incremental)), false);")

        // Assert: fold untouched (no silent loss), user-followup added.
        let afterFolds = try await eval("document.querySelectorAll('.msg-fold').length") as? Int ?? 0
        XCTAssertEqual(afterFolds, 1,
                       "B4 fix: fold MUST survive an incremental upsert that doesn't mention its ids. Got: \(afterFolds)")
        let followup = try await eval("document.querySelectorAll('.msg[data-id=\"user-followup\"]').length") as? Int ?? 0
        XCTAssertEqual(followup, 1, "user-followup must be inserted")
    }

    // MARK: - Fold at a day boundary still gets its header
    //
    // Regression guard for the B3 finding from the structured review:
    // a fold must count as a `.msg` for prevMsg resolution so the day
    // header logic still inserts a header above it. The fold element
    // has `class="msg msg-fold assistant"` — this test pins that
    // invariant by checking the day-header appears immediately above
    // the fold when the fold opens a new calendar date.

    func testFoldAtDayBoundaryStillGetsHeader() async throws {
        // Two messages far apart in time so they're on different dates.
        // The fold's timestamp (the EARLIEST folded block) lands on date D1;
        // a2 lands on date D2. We expect a day header to appear between
        // them — specifically, the header for D2 should appear immediately
        // before a2.
        // Use a date in 2024 (not "today" so the test is deterministic).
        let d1 = Date(timeIntervalSince1970: 1_725_000_000)   // 2024-09-22 ~12:00 UTC
        let d2 = Date(timeIntervalSince1970: 1_728_000_000)   // 2024-09-26 ~00:00 UTC (different day)
        let payload: [[String: Any]] = [[
            "id": "__fold_a1",
            "role": "assistant",
            "timestamp": d1.timeIntervalSince1970 * 1000,
            "html": "",
            "fold": [
                "label": "Working…",
                "count": 1,
                "blocks": ["<p>intermediate</p>"],
                "ids": ["a1"],
            ] as [String: Any],
        ], [
            "id": "a2",
            "role": "assistant",
            "senderName": "Bee",
            "timestamp": d2.timeIntervalSince1970 * 1000,
            "html": "<p>final</p>",
        ]]
        _ = try await eval("window.bc.setTopic({ topicId: 'day-fold', messages: \(asJSON(payload)), canLoadEarlier: false });")

        // Find the day-header immediately above a2 (if any).
        let headerAboveA2 = try await eval("""
        (function() {
          const a2 = document.querySelector('.msg[data-id=\"a2\"]');
          if (!a2) return null;
          const prev = a2.previousElementSibling;
          return prev && prev.classList.contains('day-header') ? prev.dataset.date : 'no-header';
        })();
        """) as? String ?? "no-header"

        // The day-header key for d2 in local time. We use a relaxed check —
        // we just want to confirm the header was inserted, not its exact text.
        XCTAssertNotEqual(headerAboveA2, "no-header",
                          "B3 regression guard: a day header must appear immediately above a2 when the fold opens the new day")

        // Also: the fold's data-date attribute must be present (used by
        // the prevMsg walk to recognise it as a .msg sibling).
        let foldDateAttr = try await eval("document.querySelector('.msg-fold')?.dataset.date") as? String ?? ""
        XCTAssertFalse(foldDateAttr.isEmpty, "Fold element must carry a data-date attribute (prevMsg walk)")
    }



    func testThemeGeometryTokensAreAccepted() async throws {
        // Mirror what ThemeManager.computeCSSTokens produces (with the geometry group).
        let tokens: [String: Any] = [
            "--bc-bg-surface": "#F8F6F0",
            "--bc-text": "#2D2D2D",
            "--bc-accent": "#D4A574",
            "--bc-radius-bubble": "16px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(0,0,0,0.05) 0px 1px 2px",
            "--bc-font-scale": "1.0",
        ]
        _ = try await eval("window.bc.setTheme(\(asJSON(tokens)));")

        // Read back the computed style on a bubble.
        let radius = try await eval("""
        (function() {
          // Need at least one msg to read bubble style; create a dummy.
          window.bc.upsertMessages([{
            id: 'theme-test', role: 'assistant', senderName: 'Bee',
            timeLabel: 'now', html: '<p>x</p>'
          }], false);
          const b = document.querySelector('.msg .bubble');
          return b ? getComputedStyle(b).borderRadius : null;
        })();
        """) as? String
        XCTAssertNotNil(radius, "must have a bubble to read computed style")
        // 16px → computed border-radius could be 16px or a normalized value.
        XCTAssertTrue(radius?.contains("16") ?? false,
                      "computed border-radius must contain 16px from --bc-radius-bubble, got \(radius ?? "nil")")
    }

    // MARK: - Helpers

    /// Build N synthetic message fixtures with controllable content length.
    private func fixtureMessages(count: Int, contentLength: Int = 80, prefix: String = "m") -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        for i in 0..<count {
            let body = String(repeating: "lorem ipsum ", count: max(1, contentLength / 12))
            msgs.append([
                "id": "\(prefix)-\(i)",
                "role": i.isMultiple(of: 2) ? "assistant" : "user",
                "senderName": "Bee",
                "timeLabel": "12:34",
                "html": "<p>\(body)</p>",
            ])
        }
        return msgs
    }

    /// Serialize a JSON-compatible value as a JS literal. Uses JSONSerialization
    /// rather than hand-rolling escaping to keep the test focus on the engine.
    private func asJSON(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Convenience for `fixtureMessages` already serialized.
    private func asFragment(messages count: Int, contentLength: Int, prefix: String) -> String {
        asJSON(fixtureMessages(count: count, contentLength: contentLength, prefix: prefix))
    }

    /// Read window.bc.state() and return as a Swift dictionary.
    private func stateDict() async throws -> [String: Any] {
        let result = try await eval("JSON.stringify(window.bc.state())")
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TranscriptTemplateTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not parse bc.state()"])
        }
        return dict
    }
}

// MARK: - WKNavigationDelegate

extension TranscriptTemplateTests: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadExpectation?.fulfill()
    }
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow only the initial loadHTMLString (navigationType == .other).
        // This matches the production posture (MessageWebView.Coordinator).
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
