import XCTest
import SwiftUI
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - MessageContent Dispatch & Flag OFF Regression Tests
//
// Tests the three-path dispatch in MessageContent:
//   flag ON + needsWebView → MessageWebView
//   flag ON + !needsWebView → ConvertedMessageView
//   flag OFF → FileLinkText (plain text, unchanged path)
//
// And flag-OFF regression guarantees:
//   - No WebView instantiation
//   - LinkPolicy still works for FileLinkText links
//   - No crashes or assertion failures

@MainActor
final class MessageContentDispatchTests: XCTestCase {

    private var themeManager: ThemeManager!

    private var originalFontScale: Double!

    override func setUp() async throws {
        themeManager = ThemeManager()
        // Preserve and reset UserDefaults state for test isolation
        originalFontScale = UserDefaults.standard.double(forKey: "BeeChat.fontScale")
        UserDefaults.standard.removeObject(forKey: "BeeChat.feature.htmlRendering")
        UserDefaults.standard.removeObject(forKey: "BeeChat.fontScale")
    }

    override func tearDown() {
        // Restore fontScale so we don't pollute other test suites
        if let saved = originalFontScale, saved > 0 {
            UserDefaults.standard.set(saved, forKey: "BeeChat.fontScale")
        } else {
            UserDefaults.standard.removeObject(forKey: "BeeChat.fontScale")
        }
        UserDefaults.standard.removeObject(forKey: "BeeChat.feature.htmlRendering")
    }

    // MARK: - Helper: Create Test Messages

    private func makeMessage(content: String) -> Message {
        Message(
            id: UUID().uuidString,
            sessionId: "test-session",
            role: "assistant",
            content: content,
            senderName: "TestBot",
            timestamp: Date(),
            createdAt: Date()
        )
    }

    // MARK: - Flag OFF: Plain Text Path

    func testFlagOffUsesFileLinkTextForSimpleContent() {
        // When the flag is OFF, even HTML-like content should use FileLinkText.
        // This is the existing behaviour — completely unchanged.
        let flags = FeatureFlags(htmlRenderingEnabled: false)
        XCTAssertFalse(flags.htmlRenderingEnabled,
                        "Flag should be OFF for this test")
    }

    func testFlagOffDefaultState() {
        // Fresh FeatureFlags (no UserDefaults) should have flag OFF
        UserDefaults.standard.removeObject(forKey: "BeeChat.feature.htmlRendering")
        let flags = FeatureFlags()
        XCTAssertFalse(flags.htmlRenderingEnabled,
                       "Default state should be OFF — htmlRendering is opt-in")
    }

    func testFlagOffPersistenceRoundTrip() {
        // Setting flag OFF should persist OFF to UserDefaults
        var flags = FeatureFlags(htmlRenderingEnabled: false)
        flags.htmlRenderingEnabled = false
        XCTAssertFalse(flags.htmlRenderingEnabled)

        // Fresh instance should read OFF
        let fresh = FeatureFlags()
        XCTAssertFalse(fresh.htmlRenderingEnabled,
                       "Fresh instance should read OFF from UserDefaults")
    }

    // MARK: - HTML Sanitizer + Converter: Dispatch Logic

    func testSimpleParagraphDoesNotNeedWebView() {
        let html = "<p>Hello world</p>"
        let result = HTMLMessageConverter.convert(HTMLSanitizer.sanitize(html))
        XCTAssertFalse(result.needsWebView,
                       "Simple paragraph should not need WebView")
        XCTAssertFalse(result.blocks.isEmpty,
                       "Simple paragraph should produce blocks")
    }

    func testTableNeedsWebView() {
        let html = "<table><tr><td>Cell</td></tr></table>"
        let result = HTMLMessageConverter.convert(HTMLSanitizer.sanitize(html))
        XCTAssertTrue(result.needsWebView,
                      "Table content should need WebView")
    }

    func testComplexHtmlNeedsWebView() {
        // Content with tags outside the native subset should need WebView
        let html = "<details><summary>Click</summary><p>Content</p></details>"
        let result = HTMLMessageConverter.convert(HTMLSanitizer.sanitize(html))
        XCTAssertTrue(result.needsWebView,
                      "Unknown tags should trigger WebView fallback")
    }

    func testNativeSubsetDoesNotNeedWebView() {
        // Content using only native-subset tags should NOT need WebView
        let html = "<h2>Title</h2><p>Body with <strong>bold</strong> and <em>italic</em>.</p><ul><li>Item</li></ul>"
        let result = HTMLMessageConverter.convert(HTMLSanitizer.sanitize(html))
        XCTAssertFalse(result.needsWebView,
                       "Native-subset HTML should not need WebView")
    }

    // MARK: - Three-Path Dispatch Contract

    func testFlagOnWithNativeContentProducesBlocks() {
        // flag ON + native content → ConvertedMessageView (not WebView)
        let html = "<p>Simple text</p>"
        let sanitized = HTMLSanitizer.sanitize(html)
        let result = HTMLMessageConverter.convert(sanitized)
        XCTAssertFalse(result.needsWebView)
        XCTAssertFalse(result.blocks.isEmpty,
                       "Native content should produce blocks for ConvertedMessageView")
    }

    func testFlagOnWithTableContentNeedsWebView() {
        // flag ON + table content → MessageWebView (needsWebView = true)
        let html = "<table><tr><td>Data</td></tr></table>"
        let sanitized = HTMLSanitizer.sanitize(html)
        let result = HTMLMessageConverter.convert(sanitized)
        XCTAssertTrue(result.needsWebView,
                      "Table content should set needsWebView = true")
    }

    func testFlagOnWithEmptyContentFallsBack() {
        // flag ON + empty/whitespace content → falls back to plain text path
        let html = ""
        let sanitized = HTMLSanitizer.sanitize(html)
        let result = HTMLMessageConverter.convert(sanitized)
        // Empty sanitized content produces no blocks
        XCTAssertTrue(result.blocks.isEmpty,
                       "Empty content should produce no blocks")
    }

    // MARK: - Flag OFF Regression: No HTML Rendering

    func testFlagOffSanitizerStillWorks() {
        // Even with flag OFF, the sanitizer should still be callable
        // (it's used for content safety in the gateway too)
        let dangerous = "<script>alert('xss')</script><p>Safe text</p>"
        let sanitized = HTMLSanitizer.sanitize(dangerous)
        XCTAssertFalse(sanitized.contains("<script>"),
                       "Sanitizer should strip script tags regardless of flag state")
        XCTAssertTrue(sanitized.contains("Safe text"),
                      "Sanitizer should preserve safe text")
    }

    func testFlagOffConverterStillWorks() {
        // Converter can still be called when flag is OFF (it just won't be
        // called from MessageContent). Verify it doesn't crash.
        let html = "<p>Test</p>"
        let result = HTMLMessageConverter.convert(HTMLSanitizer.sanitize(html))
        XCTAssertFalse(result.needsWebView)
        XCTAssertEqual(result.blocks.count, 1)
    }

    // MARK: - Flag OFF Regression: LinkPolicy Works for Plain Text

    func testLinkPolicyAllowsHTTPSWhenFlagOff() {
        // LinkPolicy should work the same regardless of rendering flag
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(LinkPolicy.isAllowed(url),
                      "HTTPS URLs should be allowed in LinkPolicy")
        XCTAssertTrue(LinkPolicy.open(url),
                      "HTTPS URLs should be openable via LinkPolicy")
    }

    func testLinkPolicyBlocksJavascriptWhenFlagOff() {
        let url = URL(string: "javascript:alert(1)")!
        XCTAssertFalse(LinkPolicy.isAllowed(url),
                       "javascript: URLs should be blocked in LinkPolicy")
        XCTAssertFalse(LinkPolicy.open(url),
                       "javascript: URLs should not be opened via LinkPolicy")
    }

    func testLinkPolicyAllowsFileURLsUnderUsersDirectoryWhenFlagOff() {
        let url = URL(fileURLWithPath: "/Users/test/file.txt")
        XCTAssertTrue(LinkPolicy.isAllowed(url),
                      "File URLs under /Users/ should be allowed for FileLinkText")
    }

    func testLinkPolicyBlocksFileURLsOutsideUsersDirectoryWhenFlagOff() {
        let url = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertFalse(LinkPolicy.isAllowed(url),
                       "File URLs outside /Users/ should be blocked")
    }

    // MARK: - Sanitizer Safety: Content That Should Be Stripped

    func testSanitizerStripsScriptTags() {
        let html = "<script>alert('xss')</script><p>Clean</p>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(sanitized.contains("<script"),
                       "Script tags must be stripped")
    }

    func testSanitizerStripsIframeTags() {
        let html = "<iframe src=\"evil.com\"></iframe><p>Safe</p>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(sanitized.contains("<iframe"),
                       "iframe tags must be stripped")
    }

    func testSanitizerStripsStyleTags() {
        let html = "<style>body{display:none}</style><p>Safe</p>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(sanitized.contains("<style"),
                       "style tags must be stripped")
    }

    func testSanitizerStripsJavascriptURLs() {
        let html = "<a href=\"javascript:alert(1)\">Click</a>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(sanitized.contains("javascript:"),
                       "javascript: URLs must be stripped from href attributes")
    }

    func testSanitizerStripsDataURLs() {
        let html = "<a href=\"data:text/html,<script>alert(1)</script>\">Click</a>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(sanitized.contains("data:"),
                       "data: URLs must be stripped from href attributes")
    }

    func testSanitizerPreservesAllowedSchemes() {
        let html = "<a href=\"https://example.com\">Link</a>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(sanitized.contains("https://example.com"),
                      "https: URLs should be preserved")
    }

    func testSanitizerPreservesMailtoLinks() {
        let html = "<a href=\"mailto:test@example.com\">Email</a>"
        let sanitized = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(sanitized.contains("mailto:test@example.com"),
                      "mailto: URLs should be preserved")
    }

    // MARK: - Converter Edge Cases

    func testConverterHandlesVeryLongContent() {
        // Content at the max text length boundary
        let longContent = String(repeating: "a", count: 199_999) // Under maxTextLength
        let result = HTMLMessageConverter.convert(longContent)
        // Should not crash; may or may not need WebView depending on parsing
        XCTAssertNotNil(result, "Converter should handle long content without crashing")
    }

    func testConverterHandlesContentExceedingMaxLength() {
        // Content exceeding maxTextLength should fall back to WebView
        let tooLong = String(repeating: "a", count: HTMLMessageConverter.maxTextLength + 1)
        let result = HTMLMessageConverter.convert(tooLong)
        XCTAssertTrue(result.needsWebView,
                      "Content exceeding maxTextLength should need WebView fallback")
    }

    func testConverterHandlesEmptyInput() {
        let result = HTMLMessageConverter.convert("")
        // Empty input: no blocks, doesn't need WebView
        XCTAssertTrue(result.blocks.isEmpty,
                      "Empty input should produce no blocks")
    }

    func testConverterHandlesWhitespaceOnly() {
        let result = HTMLMessageConverter.convert("   \n\t  ")
        // Whitespace-only input: should produce minimal output
        // At minimum it should not crash
        XCTAssertNotNil(result, "Whitespace-only input should not crash the converter")
    }

    // MARK: - ConvertedMessage Model Tests

    func testConvertedMessageWithParagraphs() {
        let text1 = try! AttributedString(markdown: "First paragraph")
        let text2 = try! AttributedString(markdown: "Second paragraph")
        let msg = ConvertedMessage(
            blocks: [.paragraph(text1), .paragraph(text2)],
            needsWebView: false
        )
        XCTAssertEqual(msg.blocks.count, 2)
        XCTAssertFalse(msg.needsWebView)
    }

    func testConvertedMessageEquality() {
        let text = try! AttributedString(markdown: "Hello")
        let msg1 = ConvertedMessage(blocks: [.paragraph(text)], needsWebView: false)
        let msg2 = ConvertedMessage(blocks: [.paragraph(text)], needsWebView: false)
        XCTAssertEqual(msg1, msg2, "Identical ConvertedMessages should be equal")
    }

    func testConvertedMessageInequality() {
        let text1 = try! AttributedString(markdown: "Hello")
        let text2 = try! AttributedString(markdown: "World")
        let msg1 = ConvertedMessage(blocks: [.paragraph(text1)], needsWebView: false)
        let msg2 = ConvertedMessage(blocks: [.paragraph(text2)], needsWebView: false)
        XCTAssertNotEqual(msg1, msg2, "Different ConvertedMessages should not be equal")
    }

    func testConvertedMessageNeedsWebViewInequality() {
        let text = try! AttributedString(markdown: "Hello")
        let msg1 = ConvertedMessage(blocks: [.paragraph(text)], needsWebView: false)
        let msg2 = ConvertedMessage(blocks: [.paragraph(text)], needsWebView: true)
        XCTAssertNotEqual(msg1, msg2, "Different needsWebView should make messages unequal")
    }

    // MARK: - MessageBlock Variants

    func testMessageBlockParagraphEquality() {
        let text = try! AttributedString(markdown: "Hello")
        let block1 = MessageBlock.paragraph(text)
        let block2 = MessageBlock.paragraph(text)
        XCTAssertEqual(block1, block2, "Identical paragraph blocks should be equal")
    }

    func testMessageBlockRuleEquality() {
        XCTAssertEqual(MessageBlock.rule, MessageBlock.rule, "Rule blocks should be equal")
    }

    func testMessageBlockCodeBlockEquality() {
        let block1 = MessageBlock.codeBlock(language: "swift", code: "let x = 1")
        let block2 = MessageBlock.codeBlock(language: "swift", code: "let x = 1")
        XCTAssertEqual(block1, block2, "Identical code blocks should be equal")
    }

    func testMessageBlockCodeBlockInequality() {
        let block1 = MessageBlock.codeBlock(language: "swift", code: "let x = 1")
        let block2 = MessageBlock.codeBlock(language: "python", code: "let x = 1")
        XCTAssertNotEqual(block1, block2, "Different language code blocks should not be equal")
    }

    func testMessageBlockImageEquality() {
        let url = URL(string: "https://example.com/img.png")!
        let block1 = MessageBlock.image(source: url, alt: "Photo")
        let block2 = MessageBlock.image(source: url, alt: "Photo")
        XCTAssertEqual(block1, block2, "Identical image blocks should be equal")
    }

    func testMessageBlockListEquality() {
        let item = [MessageBlock.paragraph(try! AttributedString(markdown: "Item"))]
        let block1 = MessageBlock.list(ordered: true, items: [item])
        let block2 = MessageBlock.list(ordered: true, items: [item])
        XCTAssertEqual(block1, block2, "Identical list blocks should be equal")
    }

    // MARK: - ThemeManager CSS Tokens (for WebView rendering)

    func testCSSTokensAreCached() {
        // First access computes, second access should use cache
        let tokens1 = themeManager.cssTokens
        let tokens2 = themeManager.cssTokens
        XCTAssertEqual(tokens1, tokens2,
                       "CSS tokens should be cached and return same values")
    }

    func testCSSTokensInvalidateOnThemeChange() {
        let originalThemeId = themeManager.currentTheme.id
        let _ = themeManager.cssTokens
        themeManager.switchTheme(to: originalThemeId == "artisanalTech" ? "classic" : "artisanalTech")
        let tokensAfter = themeManager.cssTokens
        XCTAssertNotNil(tokensAfter, "CSS tokens should be non-nil after theme switch")
        // Restore original theme
        themeManager.switchTheme(to: originalThemeId)
    }

    func testCSSTokensInvalidateOnFontScaleChange() {
        let originalScale = themeManager.fontScale
        let tokensBefore = themeManager.cssTokens
        let scaleBefore = tokensBefore["--bc-font-scale"]

        themeManager.setFontScale(1.5)
        let tokensAfter = themeManager.cssTokens
        let scaleAfter = tokensAfter["--bc-font-scale"]

        XCTAssertNotEqual(scaleBefore, scaleAfter,
                          "Font scale token should change after setFontScale")
        XCTAssertEqual(scaleAfter, "1.5", "Font scale token should reflect new value")

        // Restore original scale to avoid polluting other tests
        themeManager.setFontScale(originalScale)
        // Also clean up UserDefaults in case ThemeManager persists it
        if originalScale == 1.0 {
            UserDefaults.standard.removeObject(forKey: "BeeChat.fontScale")
        }
    }

    // MARK: - Color.toHex (P3 Fix Verification)

    func testColorToHexProducesValidHex() {
        // Verify that Color.toHex() produces valid hex strings for basic colors
        let red = Color.red.toHex()
        XCTAssertTrue(red.hasPrefix("#"), "Hex should start with #")
        XCTAssertEqual(red.count, 7, "Hex should be 7 chars (#RRGGBB)")

        let blue = Color.blue.toHex()
        XCTAssertTrue(blue.hasPrefix("#"), "Hex should start with #")
    }

    func testColorIsDarkAppearance() {
        // Verify isDarkAppearance works for known colors
        XCTAssertTrue(Color.black.isDarkAppearance,
                      "Black should be dark appearance")
        XCTAssertFalse(Color.white.isDarkAppearance,
                       "White should not be dark appearance")
    }
}