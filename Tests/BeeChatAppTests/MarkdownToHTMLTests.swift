import XCTest
@testable import BeeChatApp
import SwiftSoup

final class MarkdownToHTMLTests: XCTestCase {

    // MARK: - CommonMark Basics

    func testHeadings() {
        let input = "# Heading 1\n## Heading 2\n### Heading 3\n#### Heading 4\n##### Heading 5\n###### Heading 6"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<h1>"), "Should produce h1 tag. Result: \(result)")
        XCTAssertTrue(result.contains("<h2>"), "Should produce h2 tag")
        XCTAssertTrue(result.contains("<h3>"), "Should produce h3 tag")
        XCTAssertTrue(result.contains("<h4>"), "Should produce h4 tag")
        XCTAssertTrue(result.contains("<h5>"), "Should produce h5 tag")
        XCTAssertTrue(result.contains("<h6>"), "Should produce h6 tag")
        XCTAssertTrue(result.contains("Heading 1"), "Should preserve heading text")
    }

    func testBold() {
        let result = MarkdownToHTML.convert("**bold text**")
        XCTAssertTrue(result.contains("<strong>"), "Should produce strong tag. Result: \(result)")
        XCTAssertTrue(result.contains("bold text"), "Should preserve bold text")
    }

    func testItalic() {
        let result = MarkdownToHTML.convert("*italic text*")
        XCTAssertTrue(result.contains("<em>"), "Should produce em tag. Result: \(result)")
        XCTAssertTrue(result.contains("italic text"), "Should preserve italic text")
    }

    func testInlineCode() {
        let result = MarkdownToHTML.convert("Use `let x = 1` to declare")
        XCTAssertTrue(result.contains("<code>"), "Should produce code tag. Result: \(result)")
        XCTAssertTrue(result.contains("let x = 1"), "Should preserve code content")
    }

    func testFencedCodeBlock() {
        let input = "```swift\nlet x = 1\n```"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<pre"), "Should produce pre tag. Result: \(result)")
        XCTAssertTrue(result.contains("<code"), "Should produce code tag inside pre")
        XCTAssertTrue(result.contains("language-swift"), "Should include language class from info string")
        XCTAssertTrue(result.contains("let x = 1"), "Should preserve code content")
    }

    func testFencedCodeBlockNoLanguage() {
        let input = "```\nsome code\n```"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<pre"), "Should produce pre tag. Result: \(result)")
        XCTAssertTrue(result.contains("<code"), "Should produce code tag inside pre")
        XCTAssertTrue(result.contains("some code"), "Should preserve code content")
    }

    func testLinks() {
        let result = MarkdownToHTML.convert("[Example](https://example.com)")
        XCTAssertTrue(result.contains("<a href=\"https://example.com\">"), "Should produce link tag. Result: \(result)")
        XCTAssertTrue(result.contains("Example</a>"), "Should preserve link text")
    }

    func testBlockquotes() {
        let result = MarkdownToHTML.convert("> This is a quote")
        XCTAssertTrue(result.contains("<blockquote>"), "Should produce blockquote tag. Result: \(result)")
        XCTAssertTrue(result.contains("This is a quote"), "Should preserve quote text")
    }

    func testUnorderedList() {
        let input = "- Item 1\n- Item 2\n- Item 3"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<ul>"), "Should produce ul tag. Result: \(result)")
        XCTAssertTrue(result.contains("<li>"), "Should produce li tags")
        XCTAssertTrue(result.contains("Item 1"), "Should preserve list items")
    }

    func testOrderedList() {
        let input = "1. First\n2. Second\n3. Third"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<ol>"), "Should produce ol tag. Result: \(result)")
        XCTAssertTrue(result.contains("<li>"), "Should produce li tags")
        XCTAssertTrue(result.contains("First"), "Should preserve list items")
    }

    func testHorizontalRule() {
        let result = MarkdownToHTML.convert("---")
        XCTAssertTrue(result.contains("<hr"), "Should produce hr tag. Result: \(result)")
    }

    // MARK: - GFM Extensions

    func testTable() {
        let input = "| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<table"), "Should produce table tag. Result: \(result)")
        XCTAssertTrue(result.contains("<th"), "Should produce th tag for headers")
        XCTAssertTrue(result.contains("<td"), "Should produce td tag for cells")
        XCTAssertTrue(result.contains("Header 1"), "Should preserve header text")
        XCTAssertTrue(result.contains("Cell 1"), "Should preserve cell text")
    }

    func testStrikethrough() {
        let result = MarkdownToHTML.convert("~~deleted text~~")
        XCTAssertTrue(result.contains("<del>"), "Should produce del tag for strikethrough. Result: \(result)")
        XCTAssertTrue(result.contains("deleted text"), "Should preserve strikethrough text")
    }

    func testAutolink() {
        let result = MarkdownToHTML.convert("Visit https://example.com for more info")
        XCTAssertTrue(result.contains("<a href=\"https://example.com\">"), "Should autolink bare URLs. Result: \(result)")
    }

    func testTaskList() {
        let input = "- [x] Task 1\n- [ ] Task 2"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<li"), "Should produce list items. Result: \(result)")
        XCTAssertTrue(result.contains("Task 1"), "Should preserve task text")
        XCTAssertTrue(result.contains("Task 2"), "Should preserve task text")
    }

    // MARK: - CMARK_OPT_UNSAFE (Raw HTML Pass-Through)

    func testRawHTMLPassesThrough() {
        // With CMARK_OPT_UNSAFE, raw HTML in markdown passes through cmark
        let input = "Hello <b>world</b> from markdown"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<b>"), "Raw HTML should pass through with UNSAFE. Result: \(result)")
        XCTAssertTrue(result.contains("world"), "Raw HTML content should survive")
    }

    func testRawHTMLScriptTagPassesThrough() {
        // Raw HTML script tags pass through cmark with UNSAFE
        // This is intentional — safety is enforced downstream by HTMLSanitizer
        let input = "Check this <script>alert('xss')</script> out"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<script>"), "Script tags pass through cmark UNSAFE — sanitizer catches them. Result: \(result)")
    }

    func testRawHTMLDivElementPassesThrough() {
        let input = "Here is a <div class=\"note\">div element</div>"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<div"), "Div should pass through UNSAFE. Result: \(result)")
        XCTAssertTrue(result.contains("div element"), "Div content should survive")
    }

    // MARK: - End-to-End Security (MarkdownToHTML → HTMLSanitizer)

    func testEndToEndSanitizerCatchesDangerousContentFromCmark() {
        // The whole point of UNSAFE in cmark is that the sanitizer is the
        // security choke point. Verify that dangerous HTML from cmark is
        // caught by HTMLSanitizer.
        let markdown = "Click <script>alert('xss')</script> here"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertFalse(sanitized.contains("<script"), "Sanitizer should strip script tags from cmark output")
        XCTAssertFalse(sanitized.contains("alert"), "Sanitizer should strip script content from cmark output")
        XCTAssertTrue(sanitized.contains("Click"), "Safe text before script should survive")
        XCTAssertTrue(sanitized.contains("here"), "Safe text after script should survive")
    }

    func testEndToEndSanitizerCatchesIframeFromCmark() {
        let markdown = "See <iframe src=\"https://evil.com\"></iframe> content"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertFalse(sanitized.contains("<iframe"), "Sanitizer should strip iframes from cmark output")
        XCTAssertTrue(sanitized.contains("See"), "Safe text should survive")
        XCTAssertTrue(sanitized.contains("content"), "Safe text should survive")
    }

    func testEndToEndSanitizerCatchesStyleFromCmark() {
        let markdown = "Text <style>body{color:red}</style> more"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertFalse(sanitized.contains("<style"), "Sanitizer should strip style tags from cmark output")
        XCTAssertTrue(sanitized.contains("Text"), "Safe text should survive")
        XCTAssertTrue(sanitized.contains("more"), "Safe text should survive")
    }

    func testEndToEndSanitizerCatchesJavascriptURLFromCmark() {
        let markdown = "[click](javascript:alert('xss'))"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertFalse(sanitized.contains("javascript:"), "Sanitizer should strip javascript: URLs from cmark output")
    }

    func testEndToEndSafeHTMLPreserved() {
        // Safe HTML that passes through cmark should survive sanitization
        let markdown = "Use **bold** and <em>emphasis</em> and [links](https://example.com)"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertTrue(sanitized.contains("<strong>bold</strong>"), "Bold should survive full pipeline")
        XCTAssertTrue(sanitized.contains("<em>emphasis</em>"), "Emphasis should survive full pipeline")
        XCTAssertTrue(sanitized.contains("https://example.com"), "Link URL should survive full pipeline")
    }

    func testEndToEndTableSurvives() {
        let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let htmlFromCmark = MarkdownToHTML.convert(markdown)
        let sanitized = HTMLSanitizer.sanitize(htmlFromCmark)

        XCTAssertTrue(sanitized.contains("<table"), "Table should survive full pipeline")
        XCTAssertTrue(sanitized.contains("<th"), "Table headers should survive full pipeline")
        XCTAssertTrue(sanitized.contains("<td"), "Table cells should survive full pipeline")
    }

    // MARK: - Idempotency (HTML Input Not Corrupted)

    func testHTMLInputPassesThrough() {
        // When content is already HTML, cmark with UNSAFE should pass it through
        // largely intact. This is the P0 "treat everything as markdown" approach.
        let htmlInput = "<p>This is <strong>already HTML</strong></p>"
        let result = MarkdownToHTML.convert(htmlInput)
        XCTAssertTrue(result.contains("<p>"), "HTML paragraphs should pass through. Result: \(result)")
        XCTAssertTrue(result.contains("<strong>"), "HTML strong tags should pass through")
        XCTAssertTrue(result.contains("already HTML"), "Content should survive")
    }

    func testDoubleProcessingDoesNotMangle() {
        // Running convert twice should not corrupt content excessively
        let markdown = "Hello **world**"
        let first = MarkdownToHTML.convert(markdown)
        let second = MarkdownToHTML.convert(first)

        // Second pass should not strip the bold or add extra wrapping
        XCTAssertTrue(second.contains("<strong>"), "Bold should survive double processing. Result: \(second)")
        XCTAssertTrue(second.contains("world"), "Text should survive double processing")
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        let result = MarkdownToHTML.convert("")
        XCTAssertEqual(result, "", "Empty input should produce empty output")
    }

    func testPureTextInput() {
        let result = MarkdownToHTML.convert("Just some plain text with no formatting")
        XCTAssertTrue(result.contains("Just some plain text"), "Plain text should survive. Result: \(result)")
    }

    func testMixedMarkdownAndHTML() {
        let input = "**bold** and <em>italic</em> mixed"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<strong>"), "Markdown bold should convert. Result: \(result)")
        XCTAssertTrue(result.contains("<em>"), "HTML emphasis should pass through")
        XCTAssertTrue(result.contains("bold"), "Bold text should survive")
        XCTAssertTrue(result.contains("italic"), "Italic text should survive")
    }

    func testMultipleParagraphs() {
        let input = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<p>"), "Should produce paragraph tags. Result: \(result)")
        XCTAssertTrue(result.contains("First paragraph"), "Should preserve first paragraph")
        XCTAssertTrue(result.contains("Second paragraph"), "Should preserve second paragraph")
        XCTAssertTrue(result.contains("Third paragraph"), "Should preserve third paragraph")
    }

    func testNestedFormatting() {
        let input = "**bold and *italic* inside**"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<strong>"), "Should produce strong tag. Result: \(result)")
        XCTAssertTrue(result.contains("<em>"), "Should produce em tag inside strong")
    }

    func testCodeBlockWithLanguageClass() {
        // This is the "happy coincidence" — cmark emits fenced code as
        // <pre><code class="language-swift">, which the converter/sanitizer
        // already handle natively.
        let input = "```swift\nfunc hello() {\n    print(\"hi\")\n}\n```"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("language-swift"), "Should include language class. Result: \(result)")
        XCTAssertTrue(result.contains("<pre>"), "Should produce pre tag")
        XCTAssertTrue(result.contains("<code"), "Should produce code tag")
        XCTAssertTrue(result.contains("func hello()"), "Should preserve code content")
    }

    func testSmartPunctuationOff() {
        // With CMARK_OPT_SMART off, straight quotes should NOT become curly
        let input = "He said \"hello\" and it's fine"
        let result = MarkdownToHTML.convert(input)
        // Smart punctuation would turn "..." into "…" and "hello" into
        // curly quotes. With SMART off, straight quotes should remain.
        XCTAssertFalse(result.contains("\u{201C}"), "Should not produce left curly double quote. Result: \(result)")
        XCTAssertFalse(result.contains("\u{201D}"), "Should not produce right curly double quote")
    }

    func testLineBreaks() {
        // CommonMark: hard break requires two trailing spaces or backslash
        let input = "Line one\n\nLine two"
        let result = MarkdownToHTML.convert(input)
        XCTAssertTrue(result.contains("<p>"), "Should produce paragraph tags. Result: \(result)")
    }
}