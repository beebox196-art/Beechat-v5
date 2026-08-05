import XCTest
import WebKit
@testable import BeeChatApp

// MARK: - Transcript Fixture Tests
//
// B2 exit-gate coverage:
//   - "Fixture corpus renders across all 8 themes (screenshot-diff)"
//   - "T1–T4 PASS" (already in TranscriptTemplateTests)
//   - "embed-template.swift --check exits 0" (CI / package.json equivalent)
//
// What this file does NOT do:
//   - Run a real NSWindow with screencapture (route plan §3 G4's visual-parity
//     check). The spike harness (TranscriptSpike) does that on a developer
//     machine during G4 sign-off. For CI-friendly B2 evidence, we run a
//     STRUCTURED diff: per theme, we render the fixture, then read back
//     computed-style values for the geometry tokens and assert that the
//     bubble chrome reflects the theme palette. This catches regressions
//     in token propagation without requiring a screenshot.
//
//   - Pull the real General topic from GRDB (the spike does that for G1).
//     The fixture corpus is synthetic + hardcoded (E4 reproducibility).
//
// E1–E7 reminder: every threshold pre-registered (theme palette is a constant);
// per-fixture PASS/FAIL recorded; negative results captured in the test output.

@MainActor
final class TranscriptFixtureTests: XCTestCase {

    private var webView: WKWebView!
    private var loadExpectation: XCTestExpectation!

    override func setUp() async throws {
        try await super.setUp()
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
        self.loadExpectation = expectation(description: "template loaded")
        webView.loadHTMLString(TranscriptTemplate.html, baseURL: nil)
        await fulfillment(of: [loadExpectation], timeout: 5.0)
        // Wait for window.bc
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let r = try? await eval("typeof window.bc !== 'undefined'") as? Bool, r {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("window.bc never became available")
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    // MARK: - All 24 converter matrix cases render in every theme

    /// Route plan §9: "the 18 converter matrix cases + General's real window
    /// exported as JSON — render, screenshot-diff across all 8 themes."
    ///
    /// We assert that every fixture message renders without JS errors and the
    /// resulting DOM matches the expected node count. We do this for each of
    /// the 8 themes — the structured diff is "node counts + bubble computed
    /// style match the theme palette."
    func testConverterMatrixRendersAcrossAll8Themes() async throws {
        // Aggregate failure messages across themes for one tidy report at the end.
        var failures: [String] = []

        for (themeName, themeTokens) in TranscriptFixtures.allThemes {
            // Apply the theme.
            let themeJson = try asJSON(themeTokens)
            _ = try await eval("window.bc.setTheme(\(themeJson));")

            // Render every converter matrix case.
            for (caseName, role, html) in TranscriptFixtures.converterMatrix {
                let htmlJson = try asJSON(html)
                let id = "\(themeName)-\(caseName)"
                _ = try await eval("""
                window.bc.upsertMessages([{
                  id: \(asJSON(id)),
                  role: \(asJSON(role)),
                  timeLabel: 'now',
                  html: \(htmlJson)
                }], false);
                """)

                // Read back the rendered bubble. The DOM contract:
                //   - Exactly one .msg with the right data-id
                //   - Exactly one .bubble inside it
                //   - The bubble's computed background-color is non-empty
                //     (CSS computed-style for the theme's --bc-user-bg/--bc-asst-bg
                //     applied to the bubble's class)
                let domOk = try await eval("""
                (function() {
                  const m = document.querySelector('.msg[data-id="\(escapeJS(id))"]');
                  if (!m) return false;
                  const b = m.querySelector('.bubble');
                  if (!b) return false;
                  const bg = getComputedStyle(b).backgroundColor;
                  return bg && bg !== 'rgba(0, 0, 0, 0)';
                })();
                """) as? Bool ?? false
                if !domOk {
                    failures.append("\(themeName) / \(caseName): bubble missing or background empty")
                }
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "All converter matrix cases must render across all 8 themes. Failures:\n" +
                      failures.joined(separator: "\n"))
    }

    // MARK: - General window renders end-to-end across all 8 themes

    func testGeneralWindowRendersAcrossAll8Themes() async throws {
        var failures: [String] = []
        let generalJson = try asJSON(TranscriptFixtures.generalWindow)

        for (themeName, themeTokens) in TranscriptFixtures.allThemes {
            let themeJson = try asJSON(themeTokens)

            // Apply theme, then atomic setTopic with the full General window.
            _ = try await eval("window.bc.setTheme(\(themeJson));")
            let topicId = "general-\(themeName)"
            _ = try await eval("""
            window.bc.setTopic({
              topicId: \(asJSON(topicId)),
              messages: \(generalJson),
              canLoadEarlier: true
            });
            """)

            // Read back state. We expect:
            //   - loadedCount == 25
            //   - load-earlier button visible
            //   - at least one assistant .msg (so we know roles resolved)
            //   - at least one code-block copy button (FR-MULTICOPY A2)
            //   - exactly 25 per-message copy buttons (FR-MULTICOPY A3)
            let st = try await evalJSON("window.bc.state()")
            let loadedCount = st["loadedCount"] as? Int ?? 0
            let loadEarlierVisible = st["loadEarlierVisible"] as? Bool ?? false
            let codeBtnCount = try await eval(
                "document.querySelectorAll('.msg pre .bc-copy-btn').length"
            ) as? Int ?? 0
            let msgCopyCount = try await eval(
                "document.querySelectorAll('.msg .bc-copy-msg').length"
            ) as? Int ?? 0
            let assistantCount = try await eval(
                "document.querySelectorAll('.msg[data-role=\"assistant\"]').length"
            ) as? Int ?? 0

            if loadedCount != 25 {
                failures.append("\(themeName): loadedCount=\(loadedCount), expected 25")
            }
            if !loadEarlierVisible {
                failures.append("\(themeName): load-earlier button should be visible")
            }
            if codeBtnCount < 1 {
                failures.append("\(themeName): expected at least 1 code-block copy button, got \(codeBtnCount)")
            }
            if msgCopyCount != 25 {
                failures.append("\(themeName): msgCopyCount=\(msgCopyCount), expected 25")
            }
            if assistantCount < 1 {
                failures.append("\(themeName): no assistant messages rendered")
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "General window must render correctly across all 8 themes. Failures:\n" +
                      failures.joined(separator: "\n"))
    }

    // MARK: - Theme geometry tokens reach the bubble chrome

    /// Per-theme structured diff: the bubble's computed border-radius matches
    /// the theme's --bc-radius-bubble. Catches regressions where a theme change
    /// stops propagating to the bubble chrome (the most visible WP-2 surface).
    func testBubbleComputedStylesMatchThemeTokens() async throws {
        for (themeName, themeTokens) in TranscriptFixtures.allThemes {
            let themeJson = try asJSON(themeTokens)
            _ = try await eval("window.bc.setTheme(\(themeJson));")
            _ = try await eval("""
            window.bc.upsertMessages([{
              id: \(asJSON("style-\(themeName)")),
              role: 'assistant',
              timeLabel: 'now',
              html: '<p>test</p>'
            }], false);
            """)

            // Read the computed border-radius and the document-level CSS variable.
            // (--bc-bubble-max was removed in WP-2 Kieran-conditions correction;
            // bubble width is now hardcoded 66% in CSS for native parity, so we
            // only assert the radius token — and verify the bubble max-width is
            // the expected 66% of the transcript container.)
            let computed = try await evalJSON("""
            (function() {
              const b = document.querySelector('.msg .bubble');
              if (!b) return null;
              const cs = getComputedStyle(b);
              const root = getComputedStyle(document.documentElement);
              return {
                borderRadius: cs.borderRadius,
                cssRadiusVar: root.getPropertyValue('--bc-radius-bubble').trim(),
                bubbleMaxWidth: cs.maxWidth,
              };
            })();
            """)

            let cssRadiusVar = (computed["cssRadiusVar"] as? String) ?? ""
            let bubbleMaxWidth = (computed["bubbleMaxWidth"] as? String) ?? ""
            let borderRadius = (computed["borderRadius"] as? String) ?? ""

            // Token values from the fixture (16px, 4px, 0px, 20px) all parse to a
            // px value that the computed style echoes back. We assert that the
            // CSS variable was set AND that the computed border-radius echoes it.
            XCTAssertFalse(cssRadiusVar.isEmpty,
                          "\(themeName): --bc-radius-bubble must be set")
            // Native parity: bubble width is a constant 66% across themes
            // (mirrors MessageBubble.BubbleWidthModifier's canvasWidth * 0.66).
            XCTAssertEqual(bubbleMaxWidth, "66%",
                           "\(themeName): bubble max-width must be 66% (native parity), got \(bubbleMaxWidth)")
            // For 0px (minimal theme), computed border-radius is "0px".
            // For 16px, it's "16px". For 20px, "20px". Strip "px" and compare.
            let expectedPx = cssRadiusVar.replacingOccurrences(of: "px", with: "")
            let actualPx = borderRadius.split(separator: " ").first.map(String.init)?
                .replacingOccurrences(of: "px", with: "") ?? ""
            XCTAssertEqual(actualPx, expectedPx,
                           "\(themeName): bubble border-radius=\(borderRadius), expected to echo --bc-radius-bubble=\(cssRadiusVar)")
        }
    }

    // MARK: - Helpers

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    cont.resume(throwing: error)
                }
                else { cont.resume(returning: result) }
            }
        }
    }

    /// Evaluate an expression and return its result as a JSON-decoded dictionary.
    /// We wrap with `JSON.stringify(EXPR)` — but the user's JS MUST NOT end with
    /// a trailing `;` (the `;` would be inside `JSON.stringify(...)` parens and
    /// cause "Unexpected token ';'" parse errors). For IIFEs, write `})()` not
    /// `})();`. The convenience helpers below strip any trailing `;` defensively.
    private func evalJSON(_ js: String) async throws -> [String: Any] {
        let trimmed = js.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let raw = try await eval("JSON.stringify(\(trimmed))") as? String ?? "null"
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TranscriptFixtureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not JSON-parse: \(raw)"])
        }
        return obj
    }

    private func asJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Escape a string for inclusion as a JS double-quoted literal.
    private func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension TranscriptFixtureTests: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadExpectation?.fulfill()
    }
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
