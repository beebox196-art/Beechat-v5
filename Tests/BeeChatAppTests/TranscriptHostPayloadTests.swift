import XCTest
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - Transcript Host Payload Tests (WP-2I regression)
//
// Guards the `.web` host's message payload contract (route plan §4.3/§5):
// the template's `buildMessage` / `setStreaming` assign `bubble.innerHTML =
// html` directly, so `html` in the payload MUST be pre-rendered AND sanitized
// (markdown → HTML → sanitize).
//
// Regression: Q's first WP-2I build passed raw `msg.content` (markdown) as
// `html`, which (a) left the live transcript blank (raw markdown in
// innerHTML) and (b) skipped the sanitizer (security regression). Caught by
// Adam's smoke test 2026-08-06. Fixed via `TranscriptPayloadBuilder`.

final class TranscriptHostPayloadTests: XCTestCase {

    private func message(content: String, id: String = "m1") -> Message {
        Message(
            id: id,
            sessionId: "session-1",
            role: "assistant",
            content: content,
            senderName: "Bee",
            senderId: nil,
            agentId: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - messagePayload

    func testMarkdownIsConvertedToSanitizedHTMLInPayload() throws {
        let payload = TranscriptPayloadBuilder.messagePayload(
            message(content: "Hello **world** with [link](https://example.com)")
        )

        let html = payload["html"] as? String ?? ""

        // markdown → HTML conversion must have happened.
        XCTAssertTrue(html.contains("<strong>world</strong>"),
                      "Expected **world** to render as <strong>world</strong>, got: \(html)")
        // Link must be rendered with href.
        XCTAssertTrue(html.contains("href=\"https://example.com\""),
                      "Expected link to render with href, got: \(html)")
        // Raw markdown artifacts must not survive.
        XCTAssertFalse(html.contains("**"),
                       "Raw markdown asterisks must not reach the template, got: \(html)")
    }

    func testMessageContentIsSanitizedInPayload() throws {
        let payload = TranscriptPayloadBuilder.messagePayload(
            message(content: "<script>alert('xss')</script> plain text")
        )

        let html = payload["html"] as? String ?? ""
        XCTAssertFalse(html.localizedCaseInsensitiveContains("<script"),
                       "Script tags must be stripped before reaching the template, got: \(html)")
    }

    func testPlainTextMessageRenders() throws {
        let payload = TranscriptPayloadBuilder.messagePayload(
            message(content: "Just plain text, no formatting.")
        )

        let html = payload["html"] as? String ?? ""
        XCTAssertTrue(html.contains("Just plain text, no formatting."),
                      "Plain text content must survive conversion, got: \(html)")
    }

    func testPayloadCarriesIdentityFields() throws {
        let payload = TranscriptPayloadBuilder.messagePayload(
            message(content: "hi", id: "abc-123")
        )

        XCTAssertEqual(payload["id"] as? String, "abc-123")
        XCTAssertEqual(payload["role"] as? String, "assistant")
        XCTAssertEqual(payload["senderName"] as? String, "Bee")
    }

    // MARK: - sanitizedStreamingHTML

    func testStreamingContentIsSanitizedHTML() throws {
        let html = TranscriptPayloadBuilder.sanitizedStreamingHTML("Streaming **bold** now")
        XCTAssertTrue(html.contains("<strong>bold</strong>"),
                      "Streaming markdown must convert to HTML, got: \(html)")
        XCTAssertFalse(html.contains("**"), "Raw markdown must not reach setStreaming, got: \(html)")
    }

    func testStreamingContentIsSanitized() throws {
        let html = TranscriptPayloadBuilder.sanitizedStreamingHTML("<script>alert(1)</script> safe")
        XCTAssertFalse(html.localizedCaseInsensitiveContains("<script"),
                       "Streaming script tags must be stripped, got: \(html)")
    }
}
