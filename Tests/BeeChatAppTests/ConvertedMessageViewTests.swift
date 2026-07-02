import XCTest
import SwiftUI
@testable import BeeChatApp

// MARK: - ConvertedMessageView Tests
//
// Note: ConvertedMessageView is a SwiftUI View, so full rendering tests require
// a view host. These tests verify the structural contract (block types produce
// correct views, theme tokens are used, fontScale works) at the model level.
// View-body inspection is limited since SwiftUI views are opaque at runtime.

@MainActor
final class ConvertedMessageViewTests: XCTestCase {

    private var themeManager: ThemeManager!

    override func setUp() async throws {
        themeManager = ThemeManager()
    }

    // MARK: - Theme Token Verification

    func testThemeManagerProvidesFontTokens() {
        // Verify theme tokens are accessible (not nil/hardcoded)
        let bodyFont = themeManager.font(.body)
        XCTAssertNotNil(bodyFont, "body font token should resolve")

        let monoFont = themeManager.font(.mono)
        XCTAssertNotNil(monoFont, "mono font token should resolve")

        let headingFont = themeManager.font(.heading)
        XCTAssertNotNil(headingFont, "heading font token should resolve")
    }

    func testThemeManagerProvidesColorTokens() {
        let bgColor = themeManager.color(.bgPanel)
        XCTAssertNotNil(bgColor, "bgPanel color token should resolve")

        let borderColor = themeManager.color(.borderSubtle)
        XCTAssertNotNil(borderColor, "borderSubtle color token should resolve")

        let accentColor = themeManager.color(.accentPrimary)
        XCTAssertNotNil(accentColor, "accentPrimary color token should resolve")
    }

    func testThemeManagerProvidesSpacingTokens() {
        let sm = themeManager.spacing(.sm)
        XCTAssertEqual(sm, 8, "sm spacing should be 8pt")

        let md = themeManager.spacing(.md)
        XCTAssertEqual(md, 12, "md spacing should be 12pt")

        let lg = themeManager.spacing(.lg)
        XCTAssertEqual(lg, 16, "lg spacing should be 16pt")
    }

    func testThemeManagerProvidesRadiusTokens() {
        let md = themeManager.radius(.md)
        XCTAssertEqual(md, 8, "md radius should be 8pt")

        let sm = themeManager.radius(.sm)
        XCTAssertEqual(sm, 4, "sm radius should be 4pt")
    }

    // MARK: - FontScale

    func testFontScaleAffectsFontSpecs() {
        let spec = FontSpec(size: 14, weight: .regular)
        XCTAssertEqual(spec.scaledSize(for: 1.0), 14, "1.0 scale should be base size")
        XCTAssertEqual(spec.scaledSize(for: 1.5), 21, "1.5 scale should be 21pt")
        XCTAssertEqual(spec.scaledSize(for: 2.0), 28, "2.0 scale should be 28pt")
    }

    func testFontScaleClamping() {
        themeManager.setFontScale(3.0)
        XCTAssertEqual(themeManager.fontScale, 2.0, "Font scale should clamp to 2.0 max")

        themeManager.setFontScale(0.3)
        XCTAssertEqual(themeManager.fontScale, 0.7, accuracy: 0.01, "Font scale should clamp to 0.7 min")
    }

    func testMonoFontSpecPreservesMono() {
        let mono = FontSpec(size: 14, weight: .regular, isMono: true)
        XCTAssertTrue(mono.isMono, "Mono spec should have isMono = true")
        XCTAssertEqual(mono.scaledSize(for: 1.5), 21, "Mono scaled size should be 21pt at 1.5x")
    }

    // MARK: - ConvertedMessage Block Structure

    func testParagraphBlockCreation() {
        let text = AttributedString("Hello world")
        let block = MessageBlock.paragraph(text)
        if case .paragraph(let content) = block {
            XCTAssertEqual(String(content.characters), "Hello world")
        } else {
            XCTFail("Expected paragraph block")
        }
    }

    func testHeadingBlockCreation() {
        let text = AttributedString("Title")
        let block = MessageBlock.heading(level: 2, text: text)
        if case .heading(let level, let content) = block {
            XCTAssertEqual(level, 2)
            XCTAssertEqual(String(content.characters), "Title")
        } else {
            XCTFail("Expected heading block")
        }
    }

    func testCodeBlockCreation() {
        let block = MessageBlock.codeBlock(language: "swift", code: "let x = 1")
        if case .codeBlock(let lang, let code) = block {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1")
        } else {
            XCTFail("Expected codeBlock")
        }
    }

    func testQuoteBlockCreation() {
        let inner = MessageBlock.paragraph(AttributedString("Quoted"))
        let block = MessageBlock.quote(blocks: [inner])
        if case .quote(let blocks) = block {
            XCTAssertEqual(blocks.count, 1)
        } else {
            XCTFail("Expected quote block")
        }
    }

    func testListBlockCreation() {
        let item1 = [MessageBlock.paragraph(AttributedString("First"))]
        let item2 = [MessageBlock.paragraph(AttributedString("Second"))]
        let block = MessageBlock.list(ordered: true, items: [item1, item2])
        if case .list(let ordered, let items) = block {
            XCTAssertTrue(ordered)
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected list block")
        }
    }

    func testImageBlockCreation() {
        let url = URL(string: "https://example.com/img.png")!
        let block = MessageBlock.image(source: url, alt: "Photo")
        if case .image(let source, let alt) = block {
            XCTAssertEqual(source, url)
            XCTAssertEqual(alt, "Photo")
        } else {
            XCTFail("Expected image block")
        }
    }

    func testRuleBlockCreation() {
        let block = MessageBlock.rule
        if case .rule = block {
            // Expected
        } else {
            XCTFail("Expected rule block")
        }
    }

    // MARK: - ConvertedMessage Composition

    func testConvertedMessageWithMultipleBlocks() {
        let message = ConvertedMessage(blocks: [
            .heading(level: 1, text: AttributedString("Title")),
            .paragraph(AttributedString("Intro")),
            .codeBlock(language: "swift", code: "print(42)"),
            .rule,
            .paragraph(AttributedString("After rule")),
        ], needsWebView: false)

        XCTAssertEqual(message.blocks.count, 5)
        XCTAssertFalse(message.needsWebView)
    }

    func testConvertedMessageNeedsWebViewFlag() {
        let message = ConvertedMessage(blocks: [], needsWebView: true)
        XCTAssertTrue(message.needsWebView, "needsWebView should be true when set")
        XCTAssertTrue(message.blocks.isEmpty, "WebView fallback should have empty blocks")
    }

    // MARK: - Accessibility Heading Level

    func testAccessibilityHeadingLevels() {
        // Verify heading level mapping matches expectations
        XCTAssertEqual(headingLevel(for: 1), AccessibilityHeadingLevel.h1)
        XCTAssertEqual(headingLevel(for: 2), AccessibilityHeadingLevel.h2)
        XCTAssertEqual(headingLevel(for: 3), AccessibilityHeadingLevel.h3)
        XCTAssertEqual(headingLevel(for: 4), AccessibilityHeadingLevel.h4)
        XCTAssertEqual(headingLevel(for: 5), AccessibilityHeadingLevel.h5)
        XCTAssertEqual(headingLevel(for: 6), AccessibilityHeadingLevel.h6)
        XCTAssertEqual(headingLevel(for: 0), AccessibilityHeadingLevel.h6)
        XCTAssertEqual(headingLevel(for: 99), AccessibilityHeadingLevel.h6)
    }

    // MARK: - Integration: Converter → View Model

    func testConverterOutputFeedsIntoConvertedMessage() {
        let html = "<h2>Title</h2><p>Body text</p>"
        let converted = HTMLMessageConverter.convert(html)

        XCTAssertFalse(converted.needsWebView)
        XCTAssertEqual(converted.blocks.count, 2)

        guard case .heading(let level, _) = converted.blocks[0] else {
            XCTFail("First block should be a heading")
            return
        }
        XCTAssertEqual(level, 2)

        guard case .paragraph = converted.blocks[1] else {
            XCTFail("Second block should be a paragraph")
            return
        }
    }

    func testConverterOutputWithWebViewFallback() {
        let html = "<table><tr><td>Cell</td></tr></table>"
        let converted = HTMLMessageConverter.convert(html)
        XCTAssertTrue(converted.needsWebView, "Tables should need WebView")
        // View layer should use MessageWebView for this, not ConvertedMessageView
    }

    // MARK: - Theme CSS Token Export

    func testCSSTokensIncludeFontScale() {
        let tokens = themeManager.cssTokens
        XCTAssertNotNil(tokens["--bc-font-scale"], "CSS tokens should include font scale")
        XCTAssertEqual(tokens["--bc-font-scale"], "1.0", "Default font scale should be 1.0")
    }

    func testCSSTokensIncludeAppearance() {
        let tokens = themeManager.cssTokens
        XCTAssertNotNil(tokens["--bc-appearance"], "CSS tokens should include appearance")
        XCTAssertTrue(["light", "dark"].contains(tokens["--bc-appearance"]),
                       "Appearance should be light or dark")
    }

    func testCSSTokensIncludeColors() {
        let tokens = themeManager.cssTokens
        XCTAssertNotNil(tokens["--bc-text"], "CSS tokens should include text color")
        XCTAssertNotNil(tokens["--bc-accent"], "CSS tokens should include accent color")
        XCTAssertNotNil(tokens["--bc-bg-surface"], "CSS tokens should include bg surface color")
    }
}