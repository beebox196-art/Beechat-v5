import XCTest
@testable import BeeChatApp

// MARK: - MessageTemplate Tests
//
// Tests for MessageTemplate.html resolution chain:
// SPM resource bundle → flat Bundle.main → embedded fallback constant.
// In unit test context, neither resource bundle nor flat file exists,
// so the embedded fallback is the expected resolution path.

final class MessageTemplateTests: XCTestCase {

    // MARK: - Embedded Fallback

    func testEmbeddedTemplateIsNonEmpty() {
        // The embedded fallback constant must be non-empty — it's the
        // guaranteed-available path for hand-assembled app bundles.
        let html = MessageTemplate.html
        XCTAssertFalse(html.isEmpty,
                       "MessageTemplate.html must never be empty — embedded fallback is guaranteed")
    }

    func testEmbeddedTemplateContainsHTMLStructure() {
        let html = MessageTemplate.html
        // Verify the template contains the essential HTML scaffolding
        XCTAssertTrue(html.contains("<!DOCTYPE html>"),
                      "Template should contain DOCTYPE")
        XCTAssertTrue(html.contains("<html"),
                      "Template should contain html tag")
        XCTAssertTrue(html.contains("</html>"),
                      "Template should contain closing html tag")
        XCTAssertTrue(html.contains("<head>"),
                      "Template should contain head tag")
        XCTAssertTrue(html.contains("</head>"),
                      "Template should contain closing head tag")
        XCTAssertTrue(html.contains("<body"),
                      "Template should contain body tag")
        XCTAssertTrue(html.contains("</body>"),
                      "Template should contain closing body tag")
    }

    func testEmbeddedTemplateContainsContentDiv() {
        let html = MessageTemplate.html
        XCTAssertTrue(html.contains("id=\"content\""),
                      "Template must have #content div for message injection")
    }

    func testEmbeddedTemplateContainsBeechatJSAPI() {
        let html = MessageTemplate.html
        // The JS bridge is essential for the WebView to communicate back
        XCTAssertTrue(html.contains("window.beechat"),
                      "Template must expose window.beechat JS API")
        XCTAssertTrue(html.contains("setContent"),
                      "Template must have setContent function")
        XCTAssertTrue(html.contains("setTheme"),
                      "Template must have setTheme function")
        XCTAssertTrue(html.contains("setFontScale"),
                      "Template must have setFontScale function")
    }

    func testEmbeddedTemplateContainsBridgeHandlers() {
        let html = MessageTemplate.html
        // WebKit message handlers registered in MessageWebView
        XCTAssertTrue(html.contains("bcReady"),
                      "Template should reference bcReady bridge handler")
        XCTAssertTrue(html.contains("bcHeight"),
                      "Template should reference bcHeight bridge handler")
        XCTAssertTrue(html.contains("bcLink"),
                      "Template should reference bcLink bridge handler")
    }

    func testEmbeddedTemplateContainsCSSVariables() {
        let html = MessageTemplate.html
        // CSS custom properties that ThemeManager.cssTokens writes to
        XCTAssertTrue(html.contains("--bc-font-base"),
                      "Template should define --bc-font-base")
        XCTAssertTrue(html.contains("--bc-font-scale"),
                      "Template should define --bc-font-scale")
        XCTAssertTrue(html.contains("--bc-accent"),
                      "Template should define --bc-accent")
        XCTAssertTrue(html.contains("--bc-text"),
                      "Template should define --bc-text")
    }

    func testEmbeddedTemplateContainsDarkModeMediaQuery() {
        let html = MessageTemplate.html
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"),
                      "Template should have dark mode media query")
        XCTAssertTrue(html.contains("color-scheme: light dark"),
                      "Template should declare color-scheme meta")
    }

    // MARK: - Resolution Chain Guarantees

    func testResolutionNeverCrashes() {
        // Accessing MessageTemplate.html must never crash, regardless of
        // bundle state. This is the core guarantee of the embedded fallback.
        let html = MessageTemplate.html
        XCTAssertFalse(html.isEmpty,
                       "Accessing MessageTemplate.html must never crash or return empty")
    }

    func testResolutionIsIdempotent() {
        // Multiple accesses should return the same value
        let first = MessageTemplate.html
        let second = MessageTemplate.html
        XCTAssertEqual(first, second,
                       "Multiple accesses to MessageTemplate.html should return identical content")
    }

    // MARK: - Template Content Integrity

    func testEmbeddedTemplateContainsResizeObserver() {
        let html = MessageTemplate.html
        XCTAssertTrue(html.contains("ResizeObserver"),
                      "Template should use ResizeObserver for height reporting")
    }

    func testEmbeddedTemplateContainsClickHandler() {
        let html = MessageTemplate.html
        // The click handler intercepts link clicks and routes through bcLink
        XCTAssertTrue(html.contains("addEventListener('click'"),
                      "Template should have click event listener")
    }

    func testEmbeddedTemplateContainsContextmenuBlocker() {
        let html = MessageTemplate.html
        // Context menus are suppressed in WebView — bubble menus are native
        XCTAssertTrue(html.contains("contextmenu"),
                      "Template should suppress context menu")
    }

    func testEmbeddedTemplateContainsTableWrapping() {
        let html = MessageTemplate.html
        // Tables should be wrapped in scroll containers
        XCTAssertTrue(html.contains("bc-scroll-x"),
                      "Template should wrap tables in bc-scroll-x container")
    }

    func testEmbeddedTemplateContainsImageErrorHandling() {
        let html = MessageTemplate.html
        // Broken images should get fallback treatment
        XCTAssertTrue(html.contains("bc-broken"),
                      "Template should handle broken images with bc-broken class")
    }

    // MARK: - Template Size Bounds

    func testEmbeddedTemplateSizeIsReasonable() {
        let html = MessageTemplate.html
        // The template should be compact (< 20 KB). If it grows beyond this,
        // something may have gone wrong with embedding.
        XCTAssertLessThan(html.utf8.count, 20_000,
                           "Embedded template should stay compact (< 20 KB)")
        // Also verify it's not trivially small (was once ~8 KB)
        XCTAssertGreaterThan(html.utf8.count, 2_000,
                             "Embedded template should contain substantial CSS/JS content")
    }
}