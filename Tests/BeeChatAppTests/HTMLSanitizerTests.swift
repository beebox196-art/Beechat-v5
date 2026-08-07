import XCTest
@testable import BeeChatApp
import SwiftSoup

final class HTMLSanitizerTests: XCTestCase {

    // MARK: - Allowed Tags Pass Through

    func testAllowedTagsPassThrough() {
        let allowedTagCases: [(String, String)] = [
            ("<p>Hello</p>", "<p>Hello</p>"),
            ("<br>", "<br>"),
            ("<hr>", "<hr>"),
            ("<h1>Title</h1>", "<h1>Title</h1>"),
            ("<h2>Sub</h2>", "<h2>Sub</h2>"),
            ("<h3>Sub</h3>", "<h3>Sub</h3>"),
            ("<h4>Sub</h4>", "<h4>Sub</h4>"),
            ("<h5>Sub</h5>", "<h5>Sub</h5>"),
            ("<h6>Sub</h6>", "<h6>Sub</h6>"),
            ("<b>bold</b>", "<b>bold</b>"),
            ("<strong>strong</strong>", "<strong>strong</strong>"),
            ("<i>italic</i>", "<i>italic</i>"),
            ("<em>emphasized</em>", "<em>emphasized</em>"),
            ("<s>strike</s>", "<s>strike</s>"),
            ("<del>deleted</del>", "<del>deleted</del>"),
            ("<u>underline</u>", "<u>underline</u>"),
            ("<code>code</code>", "<code>code</code>"),
            ("<span>text</span>", "<span>text</span>"),
            ("<sub>sub</sub>", "<sub>sub</sub>"),
            ("<sup>sup</sup>", "<sup>sup</sup>"),
            ("<ul><li>item</li></ul>", "<ul><li>item</li></ul>"),
            ("<ol><li>item</li></ol>", "<ol><li>item</li></ol>"),
            ("<blockquote>quote</blockquote>", "<blockquote>quote</blockquote>"),
            ("<pre>code block</pre>", "<pre>code block</pre>"),
            ("<a href=\"https://example.com\">link</a>", "<a href=\"https://example.com\">link</a>"),
            ("<img src=\"https://example.com/img.png\" alt=\"pic\">", "<img src=\"https://example.com/img.png\" alt=\"pic\">"),
            ("<div>content</div>", "<div>content</div>"),
        ]

        for (input, expected) in allowedTagCases {
            let result = HTMLSanitizer.sanitize(input)
            XCTAssertEqual(result, expected, "Failed for input: \(input)")
        }
    }

    func testTableTagsPassThrough() {
        let html = "<table><thead><tr><th>Header</th></tr></thead><tbody><tr><td>Cell</td></tr></tbody></table>"
        let result = HTMLSanitizer.sanitize(html)
        // SwiftSoup normalizes HTML structure; just verify all tags survive
        XCTAssertTrue(result.contains("<table>"), "table tag should survive")
        XCTAssertTrue(result.contains("<thead>"), "thead tag should survive")
        XCTAssertTrue(result.contains("<th>"), "th tag should survive")
        XCTAssertTrue(result.contains("<tbody>"), "tbody tag should survive")
        XCTAssertTrue(result.contains("<td>"), "td tag should survive")
        XCTAssertTrue(result.contains("Header"), "Header text should survive")
        XCTAssertTrue(result.contains("Cell"), "Cell text should survive")
    }

    func testDetailsAndSummary() {
        let html = "<details><summary>Click me</summary><p>Hidden content</p></details>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<details>"), "details tag should survive")
        XCTAssertTrue(result.contains("<summary>"), "summary tag should survive")
        XCTAssertTrue(result.contains("Click me"), "summary text should survive")
        XCTAssertTrue(result.contains("Hidden content"), "hidden content should survive")
    }

    // MARK: - Unknown Tags Get Unwrapped

    func testUnknownTagsUnwrapped() {
        // Unknown tags should be removed but their text content preserved
        let cases: [(String, String)] = [
            ("<custom>Hello</custom>", "Hello"),
            ("<blink>text</blink>", "text"),
            ("<marquee>scrolling</marquee>", "scrolling"),
            ("<font color=\"red\">colored</font>", "colored"),
            ("<center>centered</center>", "centered"),
        ]
        for (input, expectedContent) in cases {
            let result = HTMLSanitizer.sanitize(input)
            XCTAssertTrue(result.contains(expectedContent),
                          "Unknown tag should unwrap, keeping content. Input: \(input), Result: \(result)")
            // The tag itself should not be in the output
            XCTAssertFalse(result.contains("<custom"), "Unknown tag <custom> should be removed. Result: \(result)")
        }
    }

    func testNestedUnknownTagUnwrapped() {
        let html = "<div><custom>inner text</custom></div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<div>"), "div should be kept")
        XCTAssertTrue(result.contains("inner text"), "inner text should be preserved")
        XCTAssertFalse(result.contains("<custom"), "custom tag should be removed")
    }

    // MARK: - Dangerous Tags Removed With Content

    func testDangerousTagsRemovedWithContent() {
        let dangerousTagCases = [
            "<script>alert('xss')</script>",
            "<style>body{color:red}</style>",
            "<iframe src=\"evil.com\"></iframe>",
            "<object data=\"evil.swf\"></object>",
            "<embed src=\"evil.swf\">",
            "<form action=\"evil\"><input type=\"text\"></form>",
            "<input type=\"text\">",
            "<textarea>evil</textarea>",
            "<select><option>evil</option></select>",
            "<button>click</button>",
            "<meta http-equiv=\"refresh\" content=\"0;url=evil\">",
            "<link rel=\"stylesheet\" href=\"evil.css\">",
            "<noscript>fallback</noscript>",
        ]

        for html in dangerousTagCases {
            let result = HTMLSanitizer.sanitize(html)
            // The output should be empty or stripped of all dangerous content
            XCTAssertFalse(result.contains("<script"), "script should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<style"), "style should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<iframe"), "iframe should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<object"), "object should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<embed"), "embed should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<form"), "form should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<input"), "input should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<textarea"), "textarea should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<select"), "select should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<button"), "button should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<meta"), "meta should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<link"), "link should be removed. Input: \(html)")
            XCTAssertFalse(result.contains("<noscript"), "noscript should be removed. Input: \(html)")
        }
    }

    func testScriptTagContentRemoved() {
        let html = "<p>Safe text</p><script>alert('xss')</script><p>More safe</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("Safe text"), "Text before script should survive")
        XCTAssertTrue(result.contains("More safe"), "Text after script should survive")
        XCTAssertFalse(result.contains("<script"), "script tag should be removed")
        XCTAssertFalse(result.contains("alert"), "script content should be removed")
    }

    func testStyleTagContentRemoved() {
        let html = "<p>Text</p><style>body{background:red}</style><p>More</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("Text"))
        XCTAssertTrue(result.contains("More"))
        XCTAssertFalse(result.contains("<style"))
        XCTAssertFalse(result.contains("background"))
    }

    func testNestedDangerousContentRemoved() {
        // Script inside an allowed tag
        let html = "<p><script>alert('xss')</script>Hello</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"), "nested script should be removed")
        XCTAssertFalse(result.contains("alert"), "script content should be removed")
        XCTAssertTrue(result.contains("Hello"), "text around script should be preserved")
    }

    func testIframeRemovedWithAllContent() {
        let html = "<p>Before</p><iframe src=\"https://evil.com\"><p>Inside iframe</p></iframe><p>After</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<iframe"), "iframe should be removed")
        XCTAssertFalse(result.contains("evil.com"), "iframe content should be removed")
        XCTAssertTrue(result.contains("Before"))
        XCTAssertTrue(result.contains("After"))
    }

    // MARK: - Attribute Allowlisting

    func testAllowedAttributesKept() {
        // a with href and title
        let linkResult = HTMLSanitizer.sanitize("<a href=\"https://example.com\" title=\"Example\">link</a>")
        XCTAssertTrue(linkResult.contains("href=\"https://example.com\""), "href should survive on <a>. Result: \(linkResult)")
        XCTAssertTrue(linkResult.contains("title=\"Example\""), "title should survive on <a>. Result: \(linkResult)")

        // img with src and alt
        let imgResult = HTMLSanitizer.sanitize("<img src=\"https://example.com/img.png\" alt=\"An image\">")
        XCTAssertTrue(imgResult.contains("src=\"https://example.com/img.png\""), "src should survive on <img>. Result: \(imgResult)")
        XCTAssertTrue(imgResult.contains("alt=\"An image\""), "alt should survive on <img>. Result: \(imgResult)")

        // pre with class (language hint)
        let preResult = HTMLSanitizer.sanitize("<pre class=\"language-swift\">let x = 1</pre>")
        XCTAssertTrue(preResult.contains("class=\"language-swift\""), "class should survive on <pre>. Result: \(preResult)")

        // code with class
        let codeResult = HTMLSanitizer.sanitize("<code class=\"language-python\">print()</code>")
        XCTAssertTrue(codeResult.contains("class=\"language-python\""), "class should survive on <code>. Result: \(codeResult)")
    }

    func testGlobalClassAndIdAttributesKept() {
        let html = "<div class=\"highlight\" id=\"section1\">content</div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("class=\"highlight\""), "class attribute should survive on div")
        XCTAssertTrue(result.contains("id=\"section1\""), "id attribute should survive on div")
    }

    func testDisallowedAttributesStripped() {
        let html = "<p onclick=\"alert('xss')\" style=\"color:red\" data-foo=\"bar\">Hello</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("Hello"), "Text content should survive")
        XCTAssertFalse(result.contains("onclick"), "onclick handler should be stripped")
        XCTAssertFalse(result.contains("style"), "style attribute should be stripped")
        XCTAssertFalse(result.contains("data-foo"), "data attributes should be stripped")
    }

    func testEventHandlerAttributesStripped() {
        let handlers = [
            "onclick", "onload", "onerror", "onmouseover", "onfocus", "onblur",
            "onkeydown", "onkeyup", "onsubmit",
        ]
        for handler in handlers {
            let html = "<div \(handler)=\"alert('xss')\">text</div>"
            let result = HTMLSanitizer.sanitize(html)
            XCTAssertFalse(result.contains(handler),
                           "\(handler) event handler should be stripped. Result: \(result)")
        }
    }

    func testStyleAttributeStripped() {
        let html = "<p style=\"color: red; background: blue\">styled text</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("style="), "style attribute should be stripped")
        XCTAssertTrue(result.contains("styled text"), "text content should survive")
    }

    // MARK: - URL Scheme Validation

    func testAllowedURLSchemes() {
        let allowedURLs = [
            "https://example.com",
            "http://example.com",
            "mailto:user@example.com",
        ]

        for url in allowedURLs {
            let html = "<a href=\"\(url)\">link</a>"
            let result = HTMLSanitizer.sanitize(html)
            XCTAssertTrue(result.contains(url),
                          "Allowed URL scheme should survive: \(url). Result: \(result)")
        }
    }

    func testDisallowedURLSchemesStripped() {
        let disallowedURLs = [
            "javascript:alert('xss')",
            "JAVASCRIPT:alert('xss')",
            "data:text/html,<script>alert('xss')</script>",
            "vbscript:msgbox",
            "file:///etc/passwd",
        ]

        for url in disallowedURLs {
            let html = "<a href=\"\(url)\">link</a>"
            let result = HTMLSanitizer.sanitize(html)
            XCTAssertFalse(result.contains(url.lowercased()),
                           "Disallowed URL should be stripped: \(url). Result: \(result)")
        }
    }

    func testEntityDecodedJavascriptSchemeBlocked() {
        // Entity-encoded javascript: scheme should be decoded and blocked
        let html = "<a href=\"&#106;avascript:alert('xss')\">click</a>"
        let result = HTMLSanitizer.sanitize(html)
        // The href should be stripped because the entity-decoded URL has a javascript: scheme
        XCTAssertFalse(result.contains("javascript"), "Entity-decoded javascript: should be blocked. Result: \(result)")
    }

    func testHexEntityDecodedJavascriptSchemeBlocked() {
        // Hex entity-encoded javascript: scheme
        let html = "<a href=\"&#x6A;avascript:alert('xss')\">click</a>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("javascript"), "Hex entity-decoded javascript: should be blocked. Result: \(result)")
    }

    func testImgSrcJavascriptBlocked() {
        let html = "<img src=\"javascript:alert('xss')\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("javascript"), "javascript: in img src should be blocked")
        // img tag should still be present but without the dangerous src
        XCTAssertTrue(result.contains("<img"), "img tag should survive without dangerous src")
    }

    /// WP-2I sanitizer-CSP alignment: `http://` on `<img src>` MUST be stripped.
    ///
    /// Regression guard for the silent drift where `srcSchemes` allowed `http`
    /// even though the CSP `img-src https: data:` would block it at render time.
    /// The mismatch meant an agent returning `http://example.com/img.png` would
    /// survive sanitization, reach the document, and then fail to render — with
    /// the failure attributed to CSP rather than the real cause (sanitizer drift).
    /// Now the sanitizer strips `http` at sanitize time, matching the contract.
    ///
    /// `href` URLs are unaffected: `hrefSchemes` still allows `http` per the
    /// WP-2 CSP handoff (`https:`, `http:`, `mailto:` for `href`).
    func testHttpImgSrcStripped() {
        let html = "<img src=\"http://example.com/photo.jpg\" alt=\"an http image\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("http://example.com"),
                       "http:// on img src MUST be stripped (CSP would block it anyway). Result: \(result)")
        XCTAssertFalse(result.contains("src=\"http:"),
                       "src attribute with http: scheme MUST be removed. Result: \(result)")
        // The img tag may survive (sans src) or be removed entirely depending on
        // the sanitizer's behaviour; either is correct. We only require the
        // dangerous src is gone.
        XCTAssertTrue(result.contains("alt=\"an http image\"") || !result.contains("<img"),
                      "img with stripped src should either keep alt or be removed. Result: \(result)")

        // Sanity: http: on href is still allowed (different scheme list).
        let hrefResult = HTMLSanitizer.sanitize(
            "<a href=\"http://example.com/page\">link</a>"
        )
        XCTAssertTrue(hrefResult.contains("http://example.com/page"),
                      "http:// on href MUST still be allowed. Result: \(hrefResult)")
    }

    func testRelativeURLsAllowed() {
        let cases = [
            "<a href=\"/path/to/page\">link</a>",
            "<a href=\"#anchor\">link</a>",
            "<a href=\"?query=value\">link</a>",
            "<a href=\"page.html\">link</a>",
        ]

        for html in cases {
            let result = HTMLSanitizer.sanitize(html)
            XCTAssertTrue(result.contains("href="),
                          "Relative URL should be allowed. Input: \(html), Result: \(result)")
        }
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        XCTAssertEqual(HTMLSanitizer.sanitize(""), "")
    }

    func testPlainTextInput() {
        let text = "Just some plain text with no HTML tags"
        let result = HTMLSanitizer.sanitize(text)
        // Plain text should pass through (may be wrapped in <p> by SwiftSoup)
        XCTAssertTrue(result.contains("Just some plain text"), "Plain text should survive")
    }

    func testPlainTextWithAngleBrackets() {
        let text = "5 > 3 and 2 < 4"
        let result = HTMLSanitizer.sanitize(text)
        // The comparison operators may be interpreted as HTML or escaped
        XCTAssertTrue(result.contains("5"), "Numbers should survive")
        XCTAssertTrue(result.contains("3"), "Numbers should survive")
    }

    func testDeeplyNestedAllowedTags() {
        let html = "<div><p><strong><em>deeply nested</em></strong></p></div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<div>"))
        XCTAssertTrue(result.contains("<p>"))
        XCTAssertTrue(result.contains("<strong>"))
        XCTAssertTrue(result.contains("<em>"))
        XCTAssertTrue(result.contains("deeply nested"))
    }

    func testDeeplyNestedDangerousInAllowed() {
        let html = "<div><p><script>evil()</script>Safe text</p></div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"), "script should be removed")
        XCTAssertFalse(result.contains("evil"), "script content should be removed")
        XCTAssertTrue(result.contains("Safe text"), "Safe text should be preserved")
    }

    func testMixedContent() {
        let html = """
        <p>Hello world</p>
        <script>alert('xss')</script>
        <div class="content">Some <em>important</em> text</div>
        <style>.evil { display: none; }</style>
        <a href="https://example.com" onclick="steal()">Click me</a>
        <img src="javascript:alert(1)" alt="bad img">
        <custom>Unknown tag text</custom>
        """

        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("Hello world"))
        XCTAssertTrue(result.contains("Some"))
        XCTAssertTrue(result.contains("important"))
        XCTAssertTrue(result.contains("Click me"))
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("alert"))
        XCTAssertFalse(result.contains("<style"))
        XCTAssertFalse(result.contains("onclick"))
        XCTAssertFalse(result.contains("javascript:"))
        XCTAssertTrue(result.contains("Unknown tag text"), "Unknown tag content should be unwrapped")
        XCTAssertFalse(result.contains("<custom"), "custom tag should be removed")
    }

    func testImgWithAllowedAttributes() {
        let html = "<img src=\"https://example.com/photo.jpg\" alt=\"A photo\" width=\"300\" height=\"200\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("src=\"https://example.com/photo.jpg\""), "src should survive")
        XCTAssertTrue(result.contains("alt=\"A photo\""), "alt should survive")
        XCTAssertTrue(result.contains("width=\"300\""), "width should survive")
        XCTAssertTrue(result.contains("height=\"200\""), "height should survive")
    }

    func testImgWithDisallowedAttributes() {
        let html = "<img src=\"https://example.com/photo.jpg\" alt=\"photo\" onclick=\"alert(1)\" style=\"border:1px\">"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("src=\"https://example.com/photo.jpg\""), "src should survive")
        XCTAssertTrue(result.contains("alt=\"photo\""), "alt should survive")
        XCTAssertFalse(result.contains("onclick"), "onclick should be stripped")
        XCTAssertFalse(result.contains("style"), "style should be stripped")
    }

    func testOrderedListAttributes() {
        let html = "<ol start=\"3\" type=\"A\"><li>item</li></ol>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("start=\"3\""), "start attribute should survive on ol")
        XCTAssertTrue(result.contains("type=\"A\""), "type attribute should survive on ol")
    }

    func testTableCellAttributes() {
        let html = "<table><tr><td colspan=\"2\" rowspan=\"3\">cell</td></tr></table>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("colspan=\"2\""), "colspan should survive on td")
        XCTAssertTrue(result.contains("rowspan=\"3\""), "rowspan should survive on td")
    }

    func testDetailsOpenAttribute() {
        let html = "<details open><summary>Click</summary><p>Content</p></details>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("open"), "open attribute should survive on details")
    }

    // MARK: - Length Cap

    func testMaxTextLengthTruncation() {
        let longHTML = String(repeating: "a", count: 250_000)
        let result = HTMLSanitizer.sanitize(longHTML)
        // The result should not be longer than maxTextLength characters
        // (after HTML escaping it could be slightly different, but should be capped)
        XCTAssertTrue(result.count <= HTMLSanitizer.maxTextLength + 1000,
                      "Result should be roughly within the max text length cap")
    }

    // MARK: - Self-Closing Tags

    func testSelfClosingBrTag() {
        let html = "<p>Line 1<br>Line 2</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<br>"), "br should be self-closing")
        XCTAssertTrue(result.contains("Line 1"), "Line 1 text should survive")
        XCTAssertTrue(result.contains("Line 2"), "Line 2 text should survive")
    }

    func testSelfClosingImgTag() {
        let html = "<p>See <img src=\"https://example.com/img.png\" alt=\"pic\"> image</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<img"), "img should be self-closing")
        XCTAssertTrue(result.contains("src=\"https://example.com/img.png\""), "src should survive")
    }

    func testSelfClosingHrTag() {
        let html = "<p>Section 1</p><hr><p>Section 2</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("<hr>"), "hr should be self-closing")
        XCTAssertTrue(result.contains("Section 1"))
        XCTAssertTrue(result.contains("Section 2"))
    }

    // MARK: - Comments Stripped

    func testHTMLCommentsStripped() {
        let html = "<p>Hello<!-- hidden comment -->World</p>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<!--"), "HTML comments should be stripped")
        XCTAssertFalse(result.contains("hidden comment"), "Comment content should be stripped")
    }

    // MARK: - Multiple Dangerous Elements

    func testMultipleScriptTagsRemoved() {
        let html = "<script>evil1()</script><p>Safe</p><script>evil2()</script>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("evil"))
        XCTAssertTrue(result.contains("Safe"))
    }

    func testScriptTagWithAttributes() {
        let html = "<script type=\"text/javascript\" src=\"evil.js\">alert(1)</script>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<script"), "script with attributes should be removed")
        XCTAssertFalse(result.contains("alert"), "script content should be removed")
    }

    // MARK: - Attribute on Wrong Tag

    func testHrefOnNonAnchorTagStripped() {
        // href is only allowed on <a>, not on <div>
        let html = "<div href=\"https://example.com\">text</div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("href="), "href should be stripped from non-anchor tags")
        XCTAssertTrue(result.contains("text"), "content should survive")
    }

    func testSrcOnNonImgTagStripped() {
        // src is only allowed on <img>, not on <div>
        let html = "<div src=\"https://example.com/evil.png\">text</div>"
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("src="), "src should be stripped from non-img tags")
        XCTAssertTrue(result.contains("text"), "content should survive")
    }

    // MARK: - Integration: Complex Real-World Input

    func testComplexRealWorldInput() {
        let html = """
        <div class="message">
            <h2>Important Update</h2>
            <p>Please read the <a href="https://example.com/docs" title="Documentation">documentation</a>.</p>
            <script>document.cookie</script>
            <p>Here's a code example:</p>
            <pre class="language-swift"><code class="language-swift">let x = 1</code></pre>
            <img src="https://example.com/screenshot.png" alt="Screenshot" width="600" height="400">
            <details>
                <summary>Click for details</summary>
                <p>Hidden content here</p>
            </details>
        </div>
        """

        let result = HTMLSanitizer.sanitize(html)
        // Allowed content should survive
        XCTAssertTrue(result.contains("Important Update"))
        XCTAssertTrue(result.contains("documentation"))
        XCTAssertTrue(result.contains("https://example.com/docs"))
        XCTAssertTrue(result.contains("let x = 1"))
        XCTAssertTrue(result.contains("Screenshot"))
        XCTAssertTrue(result.contains("Click for details"))

        // Dangerous content should be removed
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("document.cookie"))

        // Allowed tags should be present
        XCTAssertTrue(result.contains("<div"))
        XCTAssertTrue(result.contains("<h2>"))
        XCTAssertTrue(result.contains("<a "))
        XCTAssertTrue(result.contains("<pre"))
        XCTAssertTrue(result.contains("<code"))
        XCTAssertTrue(result.contains("<img"))
        XCTAssertTrue(result.contains("<details>"))
        XCTAssertTrue(result.contains("<summary>"))
    }

    func testFormElementsCompletelyRemoved() {
        let html = """
        <form action="/submit" method="POST">
            <input type="text" name="field1">
            <textarea name="field2">default</textarea>
            <select name="field3"><option>opt1</option></select>
            <button type="submit">Submit</button>
        </form>
        <p>Safe content outside form</p>
        """

        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("<form"), "form should be removed")
        XCTAssertFalse(result.contains("<input"), "input should be removed")
        XCTAssertFalse(result.contains("<textarea"), "textarea should be removed")
        XCTAssertFalse(result.contains("<select"), "select should be removed")
        XCTAssertFalse(result.contains("<button"), "button should be removed")
        XCTAssertFalse(result.contains("default"), "form content should be removed")
        XCTAssertTrue(result.contains("Safe content outside form"))
    }

    // MARK: - WP-2I §3.2: per-attribute scheme allow-list (`data:` for img src only)

    /// WP-2I §3.2 / §5 B2I-2: `data:image/png;base64,...` MUST survive on `<img src>`.
    /// Inline base64 images are common in markdown renderers and the CSP contract
    /// (`WP-2-csp-handoff.md` line 125) explicitly allows them.
    /// This is the positive test that was missing pre-WP-2I.
    func testDataImagePNGAllowedOnImgSrc() {
        let html = #"<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=" alt="dot">"#
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("src=\"data:image/png;base64,"),
                      "data:image/png must survive on img src. Result: \(result)")
        XCTAssertTrue(result.contains("<img"), "img tag must remain")
        XCTAssertTrue(result.contains("alt=\"dot\""), "alt attribute must survive")
    }

    /// WP-2I §3.2: `data:image/jpeg;base64,...` MUST also survive (model providers
    /// emit PNG, JPEG, and GIF in their base64 emissions — cover all three).
    func testDataImageJPEGAllowedOnImgSrc() {
        let html = #"<img src="data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAA==" alt="jpg">"#
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("src=\"data:image/jpeg;base64,"),
                      "data:image/jpeg must survive on img src. Result: \(result)")
    }

    /// WP-2I §3.2: `data:image/gif;base64,...` MUST also survive.
    func testDataImageGIFAllowedOnImgSrc() {
        let html = #"<img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" alt="gif">"#
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.contains("src=\"data:image/gif;base64,"),
                      "data:image/gif must survive on img src. Result: \(result)")
    }

    /// WP-2I §3.2: `data:text/html,<script>...</script>` MUST still be stripped on
    /// `<a href>` even though `data:` is allowed on `src`. This is the XSS guard —
    /// a clickable navigation to `data:` is the dangerous path; an inline image is not.
    func testDataTextHtmlStillBlockedOnHref() {
        let html = #"<a href="data:text/html,<script>alert('xss')</script>">click me</a>"#
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertFalse(result.contains("data:text/html"),
                       "data:text/html MUST be stripped from href. Result: \(result)")
        XCTAssertFalse(result.contains("<script"),
                       "No script content may reach the document. Result: \(result)")
        // The link tag itself stays; only the dangerous href is removed.
        XCTAssertTrue(result.contains("click me"), "link text must survive")
    }

    /// WP-2I §3.2: `data:` in any attribute other than `src` (e.g. a synthetic
    /// `data:` in a non-standard attribute) MUST still be rejected — the per-attribute
    /// allow-list is strict; only `href` and `src` get the relaxed treatment.
    /// The `data:` scheme is special-cased only for `src`.
    func testDataSchemeOnlyAllowedOnSrcNotOnHref() {
        // data: in href → blocked (XSS)
        let hrefResult = HTMLSanitizer.sanitize(#"<a href="data:text/html,safe">x</a>"#)
        XCTAssertFalse(hrefResult.contains("href=\"data:"),
                       "data: in href must be blocked. Result: \(hrefResult)")
        // data: in src → allowed
        let srcResult = HTMLSanitizer.sanitize(#"<img src="data:image/png;base64,abc">"#)
        XCTAssertTrue(srcResult.contains("src=\"data:"),
                      "data: in src must be allowed. Result: \(srcResult)")
    }
}