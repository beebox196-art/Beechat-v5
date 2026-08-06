import XCTest
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - Transcript JS Builder Tests (WP-2I smoke-test fix coverage)
//
// Pure-function tests for `TranscriptJSBuilder` — the seam introduced to
// make the .web host's JS emit strategy unit-testable without a live
// WKWebView. These tests guard the three smoke-test fixes:
//
//   Fix 1a — defer setTopic when topic changes but messages are empty.
//   Fix 1b — atomic settle: setStreaming(null) + upsertMessages([settled])
//            in ONE JS task.
//   Fix 2a — template width (lives in HTML, not builder — no test here).
//
// Each test asserts:
//   - Plan.statements (the ordered JS calls to emit)
//   - Plan.holdsTopicTransition (deferred setTopic signal)
//   - Statement string content (so accidental string drift surfaces)
//
// Tests run serially (no real WKWebView dependency).

final class TranscriptJSBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func message(
        id: String,
        role: String,
        content: String = "x",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id,
            sessionId: "session-1",
            role: role,
            content: content,
            senderName: role == "user" ? nil : "Bee",
            senderId: nil,
            agentId: nil,
            timestamp: timestamp
        )
    }

    /// Pre-rendered message payload (markdown→sanitized). Mirrors the
    /// `TranscriptPayloadBuilder.messagePayload` contract.
    private func payload(for msg: Message) -> [String: Any] {
        [
            "id": msg.id,
            "role": msg.role,
            "html": "<p>\(msg.content ?? "")</p>",
        ]
    }

    // MARK: - First-load (appliedState == nil) → setTopic

    func testFirstLoadEmitsSetTopic() {
        let user1 = message(id: "u1", role: "user")
        let asst1 = message(id: "a1", role: "assistant")
        let msgs = [user1, asst1]
        let payloads = msgs.map { payload(for: $0) }

        let next = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: nil,
            next: next,
            messagesPayload: payloads
        )

        XCTAssertFalse(plan.holdsTopicTransition,
                       "first load must NOT hold the transition")
        // First load emits setTopic + setThinking (initial state for both).
        XCTAssertEqual(plan.statements.count, 2,
                       "first load emits 2 statements: setTopic + setThinking")
        XCTAssertTrue(plan.statements[0].contains("window.bc.setTopic"),
                      "first statement must be setTopic, got: \(plan.statements[0])")
        XCTAssertTrue(plan.statements[0].contains("\"topicId\":\"topic-A\""),
                      "setTopic payload must include topicId, got: \(plan.statements[0])")
        XCTAssertTrue(plan.statements[1].contains("setThinking"),
                      "second statement must be setThinking (initial state), got: \(plan.statements[1])")
    }

    // MARK: - Fix 1a: defer setTopic when topic changes but messages are empty

    func testFix1a_topicSwitchWithEmptyMessagesHoldsTransition() {
        // Applied state: topic A with 2 messages.
        let userA = message(id: "uA", role: "user")
        let asstA = message(id: "aA", role: "assistant")
        let applied = TranscriptState(
            messages: [userA, asstA],
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        // Next state: topic B, empty messages (the transient from
        // MessageListObserver.startObserving clearing messages=[] before
        // the stream delivers).
        let next = TranscriptState(
            messages: [],
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-B"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: []
        )

        XCTAssertTrue(plan.holdsTopicTransition,
                      "Fix 1a: topic switch with empty messages MUST hold the transition")
        XCTAssertEqual(plan.statements.count, 0,
                       "Fix 1a: held transition emits NO statements")
    }

    func testFix1a_nextApplyWithMessagesEmitsSetTopic() {
        // Simulates: held transition → user picks a topic → stream delivers
        // messages → next apply should now emit setTopic (atomic swap).
        let userB = message(id: "uB", role: "user")
        let asstB = message(id: "aB", role: "assistant")
        let msgs = [userB, asstB]
        let payloads = msgs.map { payload(for: $0) }

        // After Fix 1a, the Coordinator resets appliedState to nil when
        // holding — so the next apply looks like a first-load with the new
        // topic. The builder should emit setTopic as if it's a fresh load.
        let next = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-B"
        )

        let plan = TranscriptJSBuilder.build(
            applied: nil,  // Coordinator reset this after holding
            next: next,
            messagesPayload: payloads
        )

        XCTAssertFalse(plan.holdsTopicTransition)
        // 2 statements: setTopic + setThinking (initial state)
        XCTAssertEqual(plan.statements.count, 2)
        XCTAssertTrue(plan.statements[0].contains("setTopic"))
        XCTAssertTrue(plan.statements[0].contains("topic-B"))
    }

    func testFix1a_topicSwitchWithMessagesEmitsSetTopicImmediately() {
        // No transient: the messages arrive synchronously with the topic change.
        let userB = message(id: "uB", role: "user")
        let asstB = message(id: "aB", role: "assistant")
        let msgs = [userB, asstB]
        let payloads = msgs.map { payload(for: $0) }

        let applied = TranscriptState(
            messages: [],
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let next = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-B"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: payloads
        )

        XCTAssertFalse(plan.holdsTopicTransition,
                       "non-empty messages on topic switch should NOT hold")
        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("setTopic"))
    }

    // MARK: - Fix 1b: atomic settle (streaming-end + message-arrival)

    func testFix1b_atomicSettleWhenStreamingEndsAndAssistantArrives() {
        // Applied state: we WERE streaming (partial assistant text).
        let user1 = message(id: "u1", role: "user")
        let applied = TranscriptState(
            messages: [user1],
            isStreaming: true,
            streamingContent: "partial **response**",
            completedContent: "",
            thinkingState: .streaming,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        // Next state: streaming ended; GRDB delivered the settled assistant message.
        let asst1 = message(id: "a1", role: "assistant", content: "full response")
        let next = TranscriptState(
            messages: [user1, asst1],
            isStreaming: false,
            streamingContent: "",
            completedContent: "full response",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let payloads = [payload(for: user1), payload(for: asst1)]

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: payloads
        )

        XCTAssertFalse(plan.holdsTopicTransition)
        // Atomic settle: 2 statements, in the right order.
        XCTAssertEqual(plan.statements.count, 2,
                       "Fix 1b: atomic settle must emit exactly 2 statements (setStreaming(null) + upsertMessages)")
        XCTAssertTrue(plan.statements[0].contains("window.bc.setStreaming(null)"),
                      "Fix 1b: first statement must be setStreaming(null), got: \(plan.statements[0])")
        XCTAssertTrue(plan.statements[1].contains("window.bc.upsertMessages"),
                      "Fix 1b: second statement must be upsertMessages, got: \(plan.statements[1])")
        XCTAssertTrue(plan.statements[1].contains("\"a1\""),
                      "Fix 1b: upsertMessages payload must include the new assistant id")
    }

    func testFix1b_doesNotCollapseWhenStillStreaming() {
        // Streaming continues — no settle, no message arrival. Should emit
        // setStreaming(update) only.
        let user1 = message(id: "u1", role: "user")
        let applied = TranscriptState(
            messages: [user1],
            isStreaming: true,
            streamingContent: "partial **response**",
            completedContent: "",
            thinkingState: .streaming,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let next = TranscriptState(
            messages: [user1],
            isStreaming: true,
            streamingContent: "partial **response** with more",
            completedContent: "",
            thinkingState: .streaming,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: [payload(for: user1)]
        )

        XCTAssertFalse(plan.holdsTopicTransition)
        // Streaming update: just one setStreaming with the new content.
        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("setStreaming"))
        XCTAssertFalse(plan.statements[0].contains("setStreaming(null)"),
                       "still-streaming must NOT be setStreaming(null)")
        XCTAssertFalse(plan.statements[0].contains("upsertMessages"),
                       "still-streaming must NOT upsertMessages")
    }

    func testFix1b_doesNotCollapseWhenStreamingEndedButNoNewAssistant() {
        // Streaming ended (e.g. aborted) but no settled message arrived.
        // Should NOT collapse — emit setStreaming(null) only.
        let user1 = message(id: "u1", role: "user")
        let applied = TranscriptState(
            messages: [user1],
            isStreaming: true,
            streamingContent: "partial",
            completedContent: "",
            thinkingState: .streaming,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let next = TranscriptState(
            messages: [user1],
            isStreaming: false,
            streamingContent: "",
            completedContent: "partial",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: [payload(for: user1)]
        )

        XCTAssertFalse(plan.holdsTopicTransition)
        // Streaming ended + thinkingState changed (.streaming → .idle) → 2 statements.
        XCTAssertEqual(plan.statements.count, 2)
        XCTAssertTrue(plan.statements[0].contains("setStreaming(null)"))
        XCTAssertTrue(plan.statements[1].contains("setThinking"))
        XCTAssertFalse(plan.statements.contains(where: { $0.contains("upsertMessages") }),
                       "no new assistant message means no upsertMessages")
    }

    // MARK: - Normal same-topic paths

    func testNormalSameTopicNoChangeEmitsNothing() {
        let user1 = message(id: "u1", role: "user")
        let asst1 = message(id: "a1", role: "assistant")
        let msgs = [user1, asst1]
        let payloads = msgs.map { payload(for: $0) }

        let state = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: state,
            next: state,
            messagesPayload: payloads
        )

        XCTAssertFalse(plan.holdsTopicTransition)
        XCTAssertEqual(plan.statements.count, 0,
                       "no state change emits no statements (skip round-trip)")
    }

    func testNewUserMessageArrivesEmitsUpsert() {
        let user1 = message(id: "u1", role: "user")
        let asst1 = message(id: "a1", role: "assistant")
        let applied = TranscriptState(
            messages: [user1],
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let next = TranscriptState(
            messages: [user1, asst1],
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: [payload(for: user1), payload(for: asst1)]
        )

        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("upsertMessages"))
        XCTAssertTrue(plan.statements[0].contains("\"a1\""))
    }

    func testThinkingStateChangeEmitsSetThinking() {
        let user1 = message(id: "u1", role: "user")
        let msgs = [user1]
        let payloads = [payload(for: user1)]

        let applied = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .idle,
            canLoadEarlier: false,
            topicId: "topic-A"
        )
        let next = TranscriptState(
            messages: msgs,
            isStreaming: false,
            streamingContent: "",
            completedContent: "",
            thinkingState: .thinking,
            canLoadEarlier: false,
            topicId: "topic-A"
        )

        let plan = TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: payloads
        )

        XCTAssertEqual(plan.statements.count, 1)
        XCTAssertTrue(plan.statements[0].contains("setThinking"))
        XCTAssertTrue(plan.statements[0].contains("\"thinking\""))
    }

    // MARK: - JSON encoder edge cases (sanity)

    func testJsonStringEncodesStringCorrectly() {
        let result = TranscriptJSBuilder.jsonString("hello")
        XCTAssertEqual(result, "\"hello\"")
    }

    func testJsonStringEncodesNestedDictionary() {
        let dict: [String: Any] = ["a": 1, "b": "two"]
        let result = TranscriptJSBuilder.jsonString(dict)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
        XCTAssertTrue(result.contains("\"a\":1"))
        XCTAssertTrue(result.contains("\"b\":\"two\""))
    }
}