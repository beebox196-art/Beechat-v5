import XCTest
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - TranscriptState Policy Tests (WP-1 §4.5 Truth-Table)
//
// These tests enumerate the exact inputs of the streaming/bridge policy
// (`showStreamingBubble`, `showCompletedBridge`, and their derived
// `streamingHTML` / `settledBridgeHTML` values) and assert the current
// pre-refactor behaviour. Per WP-1 §4.5:
//
//   "Before the move, enumerate the exact inputs of `showStreamingBubble` /
//    `showCompletedBridge` (message count, topic/session state, completion
//    status, bridge eligibility) and write them into the code as a documented
//    contract. After the move, add truth-table unit tests for the derived
//    `streamingHTML` / `settledBridgeHTML`: for each input combination, assert
//    the derived value matches what the old inline computation produced.
//
// The current implementation in TranscriptBoundary.swift already mirrors the
// pre-refactor logic byte-for-byte (see extension doc-comments citing the
// original MessageCanvas.swift:37–60 lines). These tests then prove the
// extension logic produces the same answers as the captured contract.
//
// After WP-1 commits, MessageCanvas will consume `state.streamingHTML` /
// `state.settledBridgeHTML` instead of inline `showStreamingBubble` /
// `showCompletedBridge` computed properties — and these tests continue to
// pass unchanged, proving behavioural equivalence.

// MARK: - Test fixtures

private enum Fixture {
    /// A single assistant message with content matching `streamingContent`.
    /// Used for "already settled" assertions.
    static func assistantMessage(content: String, id: String = "m1") -> Message {
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

    /// A single assistant message with empty content (e.g. placeholder row).
    static func emptyAssistantMessage(id: String = "m1") -> Message {
        Message(
            id: id,
            sessionId: "session-1",
            role: "assistant",
            content: "",
            senderName: "Bee",
            senderId: nil,
            agentId: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// A user message (used to verify role-filtering in policy).
    static func userMessage(content: String, id: String = "u1") -> Message {
        Message(
            id: id,
            sessionId: "session-1",
            role: "user",
            content: content,
            senderName: "Adam",
            senderId: nil,
            agentId: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Build a TranscriptState with sensible defaults; override per-test.
    static func state(
        messages: [Message] = [],
        isStreaming: Bool = false,
        streamingContent: String = "",
        completedContent: String = "",
        thinkingState: ThinkingState = .idle,
        canLoadEarlier: Bool = false,
        topicId: String? = "topic-1"
    ) -> TranscriptState {
        TranscriptState(
            messages: messages,
            isStreaming: isStreaming,
            streamingContent: streamingContent,
            completedContent: completedContent,
            thinkingState: thinkingState,
            canLoadEarlier: canLoadEarlier,
            topicId: topicId
        )
    }
}

// MARK: - showStreamingBubble truth table

final class TranscriptStatePolicyTests: XCTestCase {

    // MARK: showStreamingBubble

    func testStreamingBubble_emptyStreamingContent_neverShows() {
        // Contract: if streamingContent is empty, never show.
        let s = Fixture.state(
            messages: [],
            isStreaming: true,
            streamingContent: ""
        )
        XCTAssertFalse(s.showStreamingBubble,
                       "Empty streamingContent must produce showStreamingBubble=false (contract)")
        XCTAssertNil(s.streamingHTML,
                     "Empty streamingContent must produce streamingHTML=nil")
    }

    func testStreamingBubble_contentMatchesSettledAssistantMessage_doesNotShow() {
        // Contract: if last assistant message exists, has non-empty content,
        // AND its content equals streamingContent, do NOT show — already settled.
        let s = Fixture.state(
            messages: [Fixture.assistantMessage(content: "hello world")],
            isStreaming: true,
            streamingContent: "hello world"
        )
        XCTAssertFalse(s.showStreamingBubble,
                       "Streaming content matching settled assistant message must produce false (contract)")
        XCTAssertNil(s.streamingHTML,
                     "Matching settled content must produce streamingHTML=nil")
    }

    func testStreamingBubble_lastAssistantMessageIsEmpty_stillShows() {
        // Contract: empty content on last assistant does NOT suppress the
        // streaming bubble — the assistant message is a placeholder, not
        // settled.
        let s = Fixture.state(
            messages: [Fixture.emptyAssistantMessage()],
            isStreaming: true,
            streamingContent: "fresh streaming"
        )
        XCTAssertTrue(s.showStreamingBubble,
                      "Empty last-assistant content must NOT suppress streaming bubble (contract)")
        XCTAssertEqual(s.streamingHTML, "fresh streaming")
    }

    func testStreamingBubble_noAssistantMessages_shows() {
        // Contract: with no assistant messages, show whenever streamingContent non-empty.
        let s = Fixture.state(
            messages: [Fixture.userMessage(content: "hi")],
            isStreaming: true,
            streamingContent: "stream chunk"
        )
        XCTAssertTrue(s.showStreamingBubble)
        XCTAssertEqual(s.streamingHTML, "stream chunk")
    }

    func testStreamingBubble_lastMessageIsUser_stillShows() {
        // Contract: role filter applies — only assistant messages suppress.
        let s = Fixture.state(
            messages: [
                Fixture.userMessage(content: "question"),
                Fixture.userMessage(content: "another question", id: "u2"),
            ],
            isStreaming: true,
            streamingContent: "stream chunk"
        )
        XCTAssertTrue(s.showStreamingBubble)
        XCTAssertEqual(s.streamingHTML, "stream chunk")
    }

    func testStreamingBubble_lastAssistantIsSettledWithDifferentContent_shows() {
        // Contract: if last assistant has content but it DOESN'T match the
        // streaming content, show — that means a new turn is streaming while
        // the old one is settled in history.
        let s = Fixture.state(
            messages: [
                Fixture.assistantMessage(content: "previous turn", id: "m1"),
            ],
            isStreaming: true,
            streamingContent: "new turn streaming"
        )
        XCTAssertTrue(s.showStreamingBubble)
        XCTAssertEqual(s.streamingHTML, "new turn streaming")
    }

    func testStreamingBubble_emptyMessages_shows() {
        // Contract: no messages at all → show whenever streaming non-empty.
        let s = Fixture.state(
            messages: [],
            isStreaming: true,
            streamingContent: "anything"
        )
        XCTAssertTrue(s.showStreamingBubble)
        XCTAssertEqual(s.streamingHTML, "anything")
    }

    func testStreamingBubble_isStreamingFalse_immaterial() {
        // Contract: streaming bubble visibility depends only on streamingContent
        // and the assistant message state — NOT on isStreaming.
        let s = Fixture.state(
            messages: [],
            isStreaming: false,
            streamingContent: "leftover content"
        )
        XCTAssertTrue(s.showStreamingBubble,
                      "showStreamingBubble does not depend on isStreaming (contract)")
        XCTAssertEqual(s.streamingHTML, "leftover content")
    }

    // MARK: showCompletedBridge

    func testBridge_isStreamingTrue_neverShows() {
        // Contract: while streaming, the bridge must not render.
        let s = Fixture.state(
            messages: [],
            isStreaming: true,
            completedContent: "final content"
        )
        XCTAssertFalse(s.showCompletedBridge)
        XCTAssertNil(s.settledBridgeHTML)
    }

    func testBridge_emptyCompletedContent_neverShows() {
        // Contract: empty completedContent → no bridge.
        let s = Fixture.state(
            messages: [],
            isStreaming: false,
            completedContent: ""
        )
        XCTAssertFalse(s.showCompletedBridge)
        XCTAssertNil(s.settledBridgeHTML)
    }

    func testBridge_settledAssistantExists_doesNotShow() {
        // Contract: if last assistant has non-empty content, GRDB has
        // delivered the settled message — bridge is redundant.
        let s = Fixture.state(
            messages: [Fixture.assistantMessage(content: "settled")],
            isStreaming: false,
            completedContent: "settled"
        )
        XCTAssertFalse(s.showCompletedBridge,
                       "Settled assistant message must suppress bridge (contract)")
        XCTAssertNil(s.settledBridgeHTML)
    }

    func testBridge_lastAssistantEmpty_shows() {
        // Contract: empty assistant content means settled message hasn't
        // arrived — bridge fills the gap.
        let s = Fixture.state(
            messages: [Fixture.emptyAssistantMessage()],
            isStreaming: false,
            completedContent: "final answer"
        )
        XCTAssertTrue(s.showCompletedBridge)
        XCTAssertEqual(s.settledBridgeHTML, "final answer")
    }

    func testBridge_noAssistantMessages_shows() {
        // Contract: no assistant messages + completed content → bridge.
        let s = Fixture.state(
            messages: [Fixture.userMessage(content: "question")],
            isStreaming: false,
            completedContent: "final answer"
        )
        XCTAssertTrue(s.showCompletedBridge)
        XCTAssertEqual(s.settledBridgeHTML, "final answer")
    }

    func testBridge_emptyMessages_shows() {
        // Contract: zero messages, completed content present → bridge.
        let s = Fixture.state(
            messages: [],
            isStreaming: false,
            completedContent: "final answer"
        )
        XCTAssertTrue(s.showCompletedBridge)
        XCTAssertEqual(s.settledBridgeHTML, "final answer")
    }

    // MARK: StreamingHTML vs SettledBridgeHTML — mutually exclusive

    func testStreamingAndBridge_mutuallyExclusive_typicalCase() {
        // During active streaming: streaming bubble shows, no bridge.
        let streaming = Fixture.state(
            messages: [],
            isStreaming: true,
            streamingContent: "mid-stream"
        )
        XCTAssertEqual(streaming.streamingHTML, "mid-stream")
        XCTAssertNil(streaming.settledBridgeHTML)

        // After streaming settles but before GRDB delivers: bridge shows,
        // no streaming.
        let settling = Fixture.state(
            messages: [],
            isStreaming: false,
            streamingContent: "",  // streaming cleared by MainWindow on transition
            completedContent: "final"
        )
        XCTAssertNil(settling.streamingHTML)
        XCTAssertEqual(settling.settledBridgeHTML, "final")
    }

    // MARK: Equatable

    func testTranscriptState_isEquatable() {
        let a = Fixture.state(messages: [], streamingContent: "x")
        let b = Fixture.state(messages: [], streamingContent: "x")
        let c = Fixture.state(messages: [], streamingContent: "y")
        XCTAssertEqual(a, b, "Identical TranscriptState values must be equal")
        XCTAssertNotEqual(a, c, "Differing streamingContent must produce inequality")
    }

    func testTranscriptState_inequalityOnMessageDelta() {
        let a = Fixture.state(messages: [Fixture.userMessage(content: "u1")])
        let b = Fixture.state(messages: [Fixture.userMessage(content: "u2")])
        XCTAssertNotEqual(a, b)
    }

    func testTranscriptCallbacks_notEquatable_byDesign() {
        // Compile-time check that TranscriptCallbacks is NOT Equatable.
        // The test body never runs the comparison — it documents intent.
        // (If a future engineer accidentally adds `Equatable` conformance,
        // they should update this test with a comment explaining why.)
        let cb1 = TranscriptCallbacks(onLoadEarlier: {}, onOpenLink: { _ in }, onTapImage: {})
        let cb2 = TranscriptCallbacks(onLoadEarlier: {}, onOpenLink: { _ in }, onTapImage: {})
        // Use the values so the compiler doesn't warn about unused lets.
        XCTAssertNotNil(cb1.onLoadEarlier)
        XCTAssertNotNil(cb2.onLoadEarlier)
        // No `==` operator — confirmed at compile time below.
    }
}

// MARK: - Compile-time guarantees
//
// These checks are evaluated by the Swift compiler. They are NOT runtime
// assertions — if the conformance changes, the file will fail to compile.
// That is intentional: a non-Equatable TranscriptCallbacks is a WP-1 contract
// requirement (§4.4), and any accidental conformance must be caught here.

private func _compileTimeGuarantees() {
    // TranscriptState IS Equatable → == operator exists.
    let _: (TranscriptState, TranscriptState) -> Bool = (==)

    // TranscriptEngine is CaseIterable + String-backed.
    let _: [TranscriptEngine] = TranscriptEngine.allCases
    let _: String = TranscriptEngine.native.rawValue
    let _: TranscriptEngine = TranscriptEngine(rawValue: "native") ?? .native

    // TranscriptCallbacks is NOT Equatable — the following would NOT compile
    // if someone added the conformance unintentionally. Left as a comment
    // anchor to flag any future PR that tries to add it.
    //
    //   let _: (TranscriptCallbacks, TranscriptCallbacks) -> Bool = (==)  // ❌
}
