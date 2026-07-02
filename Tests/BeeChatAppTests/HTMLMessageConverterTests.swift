import XCTest
@testable import BeeChatApp
import SwiftSoup

// MARK: - HTMLMessageConverter Tests

final class HTMLMessageConverterTests: XCTestCase {

    // MARK: - Paragraph Conversion

    func testConvertsSimpleParagraph() {
        let html = "<p>Hello world</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView, "Simple paragraph should not need WebView")
        XCTAssertEqual(result.blocks.count, 1)

        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(String(text.characters), "Hello world")
    }

    func testConvertsBareText() {
        let html = "Just some plain text"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        XCTAssertEqual(result.blocks.count, 1)

        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph block for bare text")
            return
        }
        XCTAssertTrue(String(text.characters).contains("plain text"),
                      "Bare text should be wrapped in a paragraph")
    }

    func testConvertsMultipleParagraphs() {
        let html = "<p>First</p><p>Second</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        XCTAssertEqual(result.blocks.count, 2)
    }

    // MARK: - Headings

    func testConvertsHeadings() {
        for level in 1...6 {
            let html = "<h\(level)>Heading \(level)</h\(level)>"
            let result = HTMLMessageConverter.convert(html)
            XCTAssertFalse(result.needsWebView, "h\(level) should not need WebView")
            XCTAssertEqual(result.blocks.count, 1)

            guard case .heading(let hLevel, _) = result.blocks.first else {
                XCTFail("Expected heading block for h\(level)")
                return
            }
            XCTAssertEqual(hLevel, level, "Heading level should be \(level)")
        }
    }

    func testHeadingLevelMapsCorrectly() {
        let html = "<h2>Title</h2>"
        let result = HTMLMessageConverter.convert(html)
        guard case .heading(let level, let text) = result.blocks.first else {
            XCTFail("Expected heading block")
            return
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(String(text.characters), "Title")
    }

    // MARK: - Inline Formatting

    func testConvertsBold() {
        let html = "<p><b>bold</b> text</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        // Verify bold inline intent is present
        let hasBold = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBold, "Bold text should have stronglyEmphasized intent")
    }

    func testConvertsItalic() {
        let html = "<p><i>italic</i> text</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasItalic = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.emphasized) == true
        }
        XCTAssertTrue(hasItalic, "Italic text should have emphasized intent")
    }

    func testConvertsStrikethrough() {
        let html = "<p><s>deleted</s> text</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasStrikethrough = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.strikethrough) == true
        }
        XCTAssertTrue(hasStrikethrough, "Strikethrough text should have strikethrough intent")
    }

    func testConvertsInlineCode() {
        let html = "<p>Use <code>swift build</code> to compile</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasCode = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertTrue(hasCode, "Inline code should have code intent")
    }

    func testConvertsLink() {
        let html = "<p>Visit <a href=\"https://example.com\">our site</a></p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasLink = text.runs.contains { run in
            run.link != nil
        }
        XCTAssertTrue(hasLink, "Link should be preserved in AttributedString")
    }

    func testConvertsUnderline() {
        let html = "<p><u>underlined</u> text</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasUnderline = text.runs.contains { run in
            run.underlineStyle == .single
        }
        XCTAssertTrue(hasUnderline, "Underlined text should have underlineStyle .single")
    }

    func testConvertsBoldItalic() {
        let html = "<p><b><i>bold italic</i></b></p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasBoldItalic = text.runs.contains { run in
            let intent = run.inlinePresentationIntent
            return intent?.contains(.stronglyEmphasized) == true && intent?.contains(.emphasized) == true
        }
        XCTAssertTrue(hasBoldItalic, "Bold+italic should have both intents unioned")
    }

    // MARK: - Code Blocks

    func testConvertsCodeBlock() {
        let html = "<pre><code class=\"language-swift\">let x = 1</code></pre>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .codeBlock(let lang, let code) = result.blocks.first else {
            XCTFail("Expected codeBlock")
            return
        }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    func testConvertsCodeBlockWithoutLanguage() {
        let html = "<pre><code>plain code</code></pre>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .codeBlock(let lang, let code) = result.blocks.first else {
            XCTFail("Expected codeBlock")
            return
        }
        XCTAssertNil(lang, "Code block without language class should have nil language")
        XCTAssertEqual(code, "plain code")
    }

    func testConvertsPreWithoutCode() {
        let html = "<pre>raw preformatted text</pre>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .codeBlock(let lang, let code) = result.blocks.first else {
            XCTFail("Expected codeBlock for <pre> without <code>")
            return
        }
        XCTAssertNil(lang)
        XCTAssertEqual(code, "raw preformatted text")
    }

    // MARK: - Lists

    func testConvertsUnorderedList() {
        let html = "<ul><li>Item 1</li><li>Item 2</li></ul>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .list(let ordered, let items) = result.blocks.first else {
            XCTFail("Expected list block")
            return
        }
        XCTAssertFalse(ordered, "Should be unordered list")
        XCTAssertEqual(items.count, 2)
    }

    func testConvertsOrderedList() {
        let html = "<ol><li>First</li><li>Second</li></ol>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .list(let ordered, let items) = result.blocks.first else {
            XCTFail("Expected list block")
            return
        }
        XCTAssertTrue(ordered, "Should be ordered list")
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - Blockquote

    func testConvertsBlockquote() {
        let html = "<blockquote><p>Quoted text</p></blockquote>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .quote(let blocks) = result.blocks.first else {
            XCTFail("Expected quote block")
            return
        }
        XCTAssertEqual(blocks.count, 1)
        guard case .paragraph(let text) = blocks.first else {
            XCTFail("Quote should contain a paragraph")
            return
        }
        XCTAssertEqual(String(text.characters), "Quoted text")
    }

    // MARK: - Images

    func testConvertsImage() {
        let html = "<img src=\"https://example.com/photo.jpg\" alt=\"A photo\">"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .image(let source, let alt) = result.blocks.first else {
            XCTFail("Expected image block")
            return
        }
        XCTAssertEqual(source.absoluteString, "https://example.com/photo.jpg")
        XCTAssertEqual(alt, "A photo")
    }

    func testConvertsImageWithInvalidSrc() {
        let html = "<img src=\"data:image/png;base64,abc\" alt=\"fallback\">"
        let result = HTMLMessageConverter.convert(html)
        // data: URLs are not in allowedLinkSchemes for images, so should degrade
        XCTAssertFalse(result.needsWebView)
        // Should fall back to alt text as paragraph
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Invalid image src should degrade to paragraph with alt text")
            return
        }
        XCTAssertEqual(String(text.characters), "fallback")
    }

    // MARK: - Horizontal Rule

    func testConvertsHorizontalRule() {
        let html = "<p>Before</p><hr><p>After</p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        XCTAssertEqual(result.blocks.count, 3)
        guard case .rule = result.blocks[1] else {
            XCTFail("Expected rule block")
            return
        }
    }

    // MARK: - needsWebView (fallback triggers)

    func testNeedsWebViewForTable() {
        let html = "<table><tr><td>Cell</td></tr></table>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertTrue(result.needsWebView, "Tables should trigger WebView fallback")
    }

    func testNeedsWebViewForUnknownTag() {
        let html = "<marquee>scrolling text</marquee>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertTrue(result.needsWebView, "Unknown tags should trigger WebView fallback")
    }

    func testNeedsWebViewForExceedingMaxTextLength() {
        let html = String(repeating: "a", count: HTMLMessageConverter.maxTextLength + 1)
        let result = HTMLMessageConverter.convert(html)
        XCTAssertTrue(result.needsWebView, "Exceeding maxTextLength should trigger WebView fallback")
        XCTAssertTrue(result.blocks.isEmpty, "Over-cap content should produce empty blocks")
    }

    func testNeedsWebViewForEmptyInput() {
        // Note: SwiftSoup parseBodyFragment("") returns an empty body, which
        // produces zero blocks and needsWebView = false (no unknown tags)
        let html = ""
        let result = HTMLMessageConverter.convert(html)
        // Empty input produces 0 blocks but no unknown tag — not needsWebView
        XCTAssertFalse(result.needsWebView, "Empty input has no unknown tags")
        XCTAssertTrue(result.blocks.isEmpty, "Empty input should produce no blocks")
    }

    // MARK: - Mixed Content

    func testConvertsMixedContent() {
        let html = """
        <h2>Title</h2>
        <p>Paragraph with <b>bold</b> and <i>italic</i>.</p>
        <pre><code class="language-swift">let x = 1</code></pre>
        <ul><li>Item</li></ul>
        <blockquote><p>Quote</p></blockquote>
        <hr>
        <p>After rule</p>
        """
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView, "Mixed native content should not need WebView")

        // Check block types in order
        guard result.blocks.count >= 6 else {
            XCTFail("Expected at least 6 blocks, got \(result.blocks.count)")
            return
        }

        guard case .heading = result.blocks[0] else { XCTFail("Block 0 should be heading"); return }
        guard case .paragraph = result.blocks[1] else { XCTFail("Block 1 should be paragraph"); return }
        guard case .codeBlock = result.blocks[2] else { XCTFail("Block 2 should be codeBlock"); return }
        guard case .list = result.blocks[3] else { XCTFail("Block 3 should be list"); return }
        guard case .quote = result.blocks[4] else { XCTFail("Block 4 should be quote"); return }
        guard case .rule = result.blocks[5] else { XCTFail("Block 5 should be rule"); return }
    }

    // MARK: - Whitespace Handling

    func testWhitespaceCollapsedInParagraphs() {
        let html = "<p>  multiple   spaces   here  </p>"
        let result = HTMLMessageConverter.convert(html)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let desc = String(text.characters)
        // HTML whitespace: leading/trailing should be trimmed, multiple spaces collapsed
        XCTAssertFalse(desc.contains("  "), "Multiple spaces should be collapsed: '\(desc)'")
    }

    func testPreWhitespacePreserved() {
        let html = "<pre><code>  indented\n  code\n</code></pre>"
        let result = HTMLMessageConverter.convert(html)
        guard case .codeBlock(_, let code) = result.blocks.first else {
            XCTFail("Expected codeBlock")
            return
        }
        XCTAssertTrue(code.contains("  indented"), "Whitespace in <pre> should be preserved")
        XCTAssertTrue(code.contains("\n"), "Newlines in <pre> should be preserved")
    }

    // MARK: - Line Break

    func testConvertsLineBreak() {
        let html = "<p>Line 1<br>Line 2</p>"
        let result = HTMLMessageConverter.convert(html)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let desc = String(text.characters)
        XCTAssertTrue(desc.contains("\n"), "BR should produce newline in text")
    }

    // MARK: - Deep Nesting

    func testConvertsNestedFormatting() {
        let html = "<p><b><i><s>bold italic strike</s></i></b></p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let hasAllThree = text.runs.contains { run in
            let intent = run.inlinePresentationIntent
            return intent?.contains(.stronglyEmphasized) == true
                && intent?.contains(.emphasized) == true
                && intent?.contains(.strikethrough) == true
        }
        XCTAssertTrue(hasAllThree, "Nested bold+italic+strikethrough should have all three intents")
    }

    // MARK: - Passthrough Tags (sub, sup, small, mark, span)

    func testPassthroughTagsPreserveContent() {
        // sub, sup, small, mark are in nativeTags but have no inline presentation effect
        // They should pass through transparently, keeping their text content
        let html = "<p>H<sub>2</sub>O and E=mc<sup>2</sup></p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView, "sub/sup should not trigger WebView")
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        let desc = String(text.characters)
        XCTAssertTrue(desc.contains("2"), "Subscript content should be preserved")
        XCTAssertTrue(desc.contains("2"), "Superscript content should be preserved")
    }

    func testSpanIsTransparent() {
        let html = "<p><span>span content</span></p>"
        let result = HTMLMessageConverter.convert(html)
        XCTAssertFalse(result.needsWebView)
        guard case .paragraph(let text) = result.blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        XCTAssertEqual(String(text.characters), "span content")
    }

    // MARK: - Conversion Result Equality

    func testConvertedMessageEquality() {
        let a = ConvertedMessage(blocks: [.paragraph(AttributedString("hello"))], needsWebView: false)
        let b = ConvertedMessage(blocks: [.paragraph(AttributedString("hello"))], needsWebView: false)
        XCTAssertEqual(a, b, "Identical ConvertedMessages should be equal")
    }

    func testConvertedMessageInequality() {
        let a = ConvertedMessage(blocks: [.paragraph(AttributedString("hello"))], needsWebView: false)
        let b = ConvertedMessage(blocks: [.paragraph(AttributedString("world"))], needsWebView: false)
        XCTAssertNotEqual(a, b, "Different ConvertedMessages should not be equal")
    }

    func testMessageBlockEquality() {
        let a: MessageBlock = .paragraph(AttributedString("test"))
        let b: MessageBlock = .paragraph(AttributedString("test"))
        XCTAssertEqual(a, b, "Identical MessageBlocks should be equal")
    }

    func testCodeBlockEquality() {
        let a: MessageBlock = .codeBlock(language: "swift", code: "let x = 1")
        let b: MessageBlock = .codeBlock(language: "swift", code: "let x = 1")
        XCTAssertEqual(a, b, "Identical code blocks should be equal")
    }

    func testRuleEquality() {
        let a: MessageBlock = .rule
        let b: MessageBlock = .rule
        XCTAssertEqual(a, b, "Two rules should be equal")
    }
}