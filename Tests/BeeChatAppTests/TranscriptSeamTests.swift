import XCTest
import WebKit
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - Transcript Seam Tests (E10)
//
// WHY THIS FILE EXISTS
//
// On 2026-08-06 the `.web` transcript shipped fatally broken while 321 tests
// were green. `TranscriptTemplate.html:743` declares
// `upsertMessages(messages, canLoadEarlier)` — POSITIONAL — while the host
// emitted a single object `{messages, canLoadEarlier}`. Every upsert threw
// `TypeError` in the live app.
//
// Neither existing suite could catch it:
//
//   - `TranscriptJSBuilderTests` asserts the host's emitted STRING
//     (`statements[0].contains("window.bc.upsertMessages")`) and never
//     executes it. Argument shape is invisible to it.
//   - `TranscriptFixtureTests` / `TranscriptTemplateTests` DO execute real JS
//     in a real WKWebView — but they hand-write the call in the correct
//     positional form. They prove the template works; they say nothing about
//     what the host sends.
//
// Two correct halves, an untested contract between them.
//
// E10 — SEAM EXECUTION RULE: every host→document call must have at least one
// test that takes the string the host ACTUALLY EMITS and evaluates it against
// the real template, asserting no JS exception is raised.
//
// That is the only thing this file does. It deliberately does NOT re-test
// template behaviour (TranscriptTemplateTests owns that) or host diff logic
// (TranscriptJSBuilderTests owns that). It tests the join.
//
// HOW TO EXTEND: any new `window.bc.*` call added to `TranscriptJSBuilder`
// must gain a scenario here. `testEverySeamStatementIsExecutable` is the
// backstop — it fails on any statement this file has not exercised.

@MainActor
final class TranscriptSeamTests: XCTestCase {

    private var webView: WKWebView!

    // MARK: - Harness

    override func setUp() async throws {
        try await super.setUp()
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600),
                            configuration: config)
        webView.loadHTMLString(TranscriptTemplate.html, baseURL: nil)

        // Poll for the bridge rather than depending on a navigation delegate —
        // `window.bc` is the only readiness signal the seam cares about.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let ready = try? await raw("typeof window.bc !== 'undefined'") as? Bool, ready {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("window.bc never became available — template failed to load")
    }

    override func tearDown() async throws {
        webView = nil
        try await super.tearDown()
    }

    @discardableResult
    private func raw(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    /// Execute a builder plan EXACTLY as `WebTranscriptView.Coordinator` does:
    /// statements joined with `;` into one `evaluateJavaScript` call.
    /// Any JS exception fails the test with the offending script attached.
    @discardableResult
    private func executePlan(_ plan: TranscriptJSBuilder.Plan,
                             _ label: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) async -> Any? {
        let script = plan.statements.joined(separator: ";")
        guard !script.isEmpty else { return nil }
        do {
            return try await webView.evaluateJavaScript(script)
        } catch {
            XCTFail("""
            SEAM BREAK — \(label)
            The host emitted JS the template cannot execute.
            error:  \(error.localizedDescription)
            script: \(script.prefix(400))
            """, file: file, line: line)
            return nil
        }
    }

    private func msgCount() async throws -> Int {
        (try await raw("document.querySelectorAll('.msg').length") as? Int) ?? -1
    }

    // MARK: - Fixtures

    private func message(id: String,
                         role: String,
                         content: String = "hello **world**") -> Message {
        Message(
            id: id,
            sessionId: "session-1",
            role: role,
            content: content,
            senderName: role == "user" ? nil : "Bee",
            senderId: nil,
            agentId: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func state(_ messages: [Message],
                       topicId: String?,
                       streaming: String = "",
                       isStreaming: Bool = false,
                       thinking: ThinkingState = .idle,
                       canLoadEarlier: Bool = false) -> TranscriptState {
        TranscriptState(
            messages: messages,
            isStreaming: isStreaming,
            streamingContent: streaming,
            completedContent: "",
            thinkingState: thinking,
            canLoadEarlier: canLoadEarlier,
            topicId: topicId
        )
    }

    /// The REAL payload builder the host uses — not a test-local imitation.
    /// If `messagePayload`'s shape drifts from the template's expectations,
    /// these tests break.
    private func payloads(_ messages: [Message]) -> [[String: Any]] {
        messages.map { TranscriptPayloadBuilder.messagePayload($0) }
    }

    private func plan(applied: TranscriptState?, next: TranscriptState) -> TranscriptJSBuilder.Plan {
        TranscriptJSBuilder.build(
            applied: applied,
            next: next,
            messagesPayload: payloads(next.messages)
        )
    }

    // MARK: - Scenario 1: first load / topic switch → setTopic

    func testSetTopicSeamExecutes() async throws {
        let msgs = [message(id: "u1", role: "user"), message(id: "a1", role: "assistant")]
        let next = state(msgs, topicId: "topic-A")

        await executePlan(plan(applied: nil, next: next), "first load → setTopic")

        let count = try await msgCount()
        XCTAssertEqual(count, 2, "setTopic must render both messages into the DOM")
    }

    // MARK: - Scenario 2: same-topic new message → upsertMessages
    //
    // THE REGRESSION GUARD. This is the exact call that threw in production.

    func testUpsertMessagesSeamExecutes() async throws {
        let first = [message(id: "u1", role: "user")]
        let applied = state(first, topicId: "topic-A")
        await executePlan(plan(applied: nil, next: applied), "setup → setTopic")

        let grown = first + [message(id: "a1", role: "assistant", content: "reply")]
        let next = state(grown, topicId: "topic-A")

        let p = plan(applied: applied, next: next)
        XCTAssertTrue(p.statements.contains(where: { $0.contains("window.bc.upsertMessages") }),
                      "precondition: this scenario must exercise upsertMessages")

        await executePlan(p, "same-topic new message → upsertMessages")

        let count = try await msgCount()
        XCTAssertEqual(count, 2, "upsertMessages must append the new assistant message")
    }

    // MARK: - Scenario 3: atomic settle → setStreaming(null);upsertMessages
    //
    // Adam's reported symptom: the response appears while streaming and
    // vanishes the instant it completes. Mechanism: statement 1 removes the
    // streaming node, statement 2 throws, nothing replaces it. Both statements
    // run in ONE eval, so a throw in the second leaves the DOM stripped.

    func testAtomicSettleSeamExecutes() async throws {
        let userMsg = [message(id: "u1", role: "user")]
        let settled = state(userMsg, topicId: "topic-A")
        await executePlan(plan(applied: nil, next: settled), "setup → setTopic")

        // Streaming in progress.
        let streamingState = state(userMsg, topicId: "topic-A",
                                   streaming: "partial answer",
                                   isStreaming: true,
                                   thinking: .streaming)
        await executePlan(plan(applied: settled, next: streamingState), "stream start → setStreaming")
        let duringStream = try await raw("!!document.querySelector('#streaming-msg')") as? Bool
        XCTAssertEqual(duringStream, true, "streaming node must be present mid-stream")

        // Stream ends and the settled assistant message arrives in one state.
        let withAssistant = userMsg + [message(id: "a1", role: "assistant", content: "partial answer")]
        let settledState = state(withAssistant, topicId: "topic-A")

        let p = plan(applied: streamingState, next: settledState)
        XCTAssertEqual(p.statements.count, 2,
                       "precondition: atomic settle must emit setStreaming(null) + upsertMessages")

        await executePlan(p, "atomic settle → setStreaming(null);upsertMessages")

        let afterStream = try await raw("!!document.querySelector('#streaming-msg')") as? Bool
        XCTAssertEqual(afterStream, false, "streaming node must be gone after settle")
        let count = try await msgCount()
        XCTAssertEqual(count, 2,
                       "the settled assistant message must REPLACE the streaming node — "
                       + "if this is 1, the response vanished (the production symptom)")
    }

    // MARK: - Scenario 4: thinking state → setThinking

    func testSetThinkingSeamExecutes() async throws {
        let msgs = [message(id: "u1", role: "user")]
        let applied = state(msgs, topicId: "topic-A")
        await executePlan(plan(applied: nil, next: applied), "setup → setTopic")

        let thinking = state(msgs, topicId: "topic-A", thinking: .thinking)
        let p = plan(applied: applied, next: thinking)
        XCTAssertTrue(p.statements.contains(where: { $0.contains("setThinking") }),
                      "precondition: this scenario must exercise setThinking")
        await executePlan(p, "thinking → setThinking")
    }

    // MARK: - Backstop: no builder statement escapes seam execution
    //
    // Collects every distinct `window.bc.<fn>` the builder can emit across the
    // scenarios above and asserts the set matches what this file executes. A
    // new call added to TranscriptJSBuilder without a scenario here fails.

    func testEverySeamStatementIsExecutable() async throws {
        var emitted = Set<String>()

        func collect(_ p: TranscriptJSBuilder.Plan) {
            for s in p.statements {
                if let name = s.split(separator: "(").first.map(String.init) {
                    emitted.insert(name.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        let msgs = [message(id: "u1", role: "user")]
        let a = state(msgs, topicId: "topic-A")
        collect(plan(applied: nil, next: a))

        let grown = msgs + [message(id: "a1", role: "assistant")]
        let b = state(grown, topicId: "topic-A")
        collect(plan(applied: a, next: b))

        let streamingState = state(grown, topicId: "topic-A",
                                   streaming: "partial", isStreaming: true, thinking: .streaming)
        collect(plan(applied: b, next: streamingState))

        let settledGrown = grown + [message(id: "a2", role: "assistant", content: "partial")]
        collect(plan(applied: streamingState, next: state(settledGrown, topicId: "topic-A")))

        // Scenario 5: head-extension → prependEarlier.
        // Regression guard for Issue 1: when older messages arrive at the head
        // (load-earlier), the builder must emit `prependEarlier(older)` rather
        // than `upsertMessages(full)`. Without this scenario in the backstop,
        // a future builder refactor that drops the head-extension branch would
        // pass `testEverySeamStatementIsExecutable` vacuously (the test would
        // see no new emit, but also nothing in `covered` to demand it).
        let m3 = message(id: "m3", role: "user", content: "third message")
        let m4 = message(id: "m4", role: "assistant", content: "fourth message")
        let appliedHead = state([m3, m4], topicId: "topic-A", canLoadEarlier: true)
        let m1 = message(id: "m1", role: "user", content: "first message")
        let m2 = message(id: "m2", role: "assistant", content: "second message")
        let nextHead = state([m1, m2, m3, m4], topicId: "topic-A", canLoadEarlier: false)
        let headPlan = plan(applied: appliedHead, next: nextHead)
        // Sanity: this scenario must actually exercise prependEarlier — if it
        // doesn't, the backstop is lying about coverage and we'd rather fail
        // loud here than in production.
        XCTAssertTrue(headPlan.statements.contains(where: { $0.contains("prependEarlier") }),
                      "head-extension scenario must emit prependEarlier (backstop self-check)")
        collect(headPlan)

        // Every call this suite has a scenario for.
        let covered: Set<String> = [
            "window.bc.setTopic",
            "window.bc.upsertMessages",
            "window.bc.setStreaming",
            "window.bc.setThinking",
            "window.bc.prependEarlier",
        ]

        let uncovered = emitted.subtracting(covered)
        XCTAssertTrue(uncovered.isEmpty, """
        E10 VIOLATION — TranscriptJSBuilder emits calls with no seam test: \(uncovered.sorted())
        Add a scenario to TranscriptSeamTests that executes the emitted string
        against the real template, then add the call to `covered`.
        """)

        // Guard the inverse too: if a covered call stops being emitted, the
        // scenario above is dead weight and should be removed knowingly.
        let missing = covered.subtracting(emitted)
        XCTAssertTrue(missing.isEmpty,
                      "seam scenarios exist for calls the builder no longer emits: \(missing.sorted())")
    }

    // MARK: - Issue 1: load-earlier routes through prependEarlier
    //
    // REGRESSION GUARD for the documented gap (was testLoadEarlierRoutesThroughUpsertNotPrependEarlier_KNOWN_GAP
    // in the previous commit). The host now detects head extension and emits
    // `prependEarlier(older)` instead of `upsertMessages(full)`, so older
    // messages land at the TOP in chronological order with deterministic
    // scroll anchoring (T3). Exercises the actual JS in a real WKWebView
    // to assert: (a) no JS exception, (b) DOM order matches chronological
    // (oldest first), (c) `loadedCount` reflects the total.
    func testLoadEarlierHeadExtensionRoutesThroughPrependEarlier() async throws {
        // Setup: 2 messages already applied (the recent suffix of a longer history).
        let m3 = message(id: "m3", role: "user", content: "third message")
        let m4 = message(id: "m4", role: "assistant", content: "fourth message")
        let applied = state([m3, m4], topicId: "topic-A", canLoadEarlier: true)

        // Push the applied state into the live template.
        await executePlan(plan(applied: nil, next: applied), "setup → setTopic")
        let setupCount = try await msgCount()
        XCTAssertEqual(setupCount, 2, "setup must render 2 messages")

        // Now: window expands — older m1, m2 arrive at the head.
        let m1 = message(id: "m1", role: "user", content: "first message")
        let m2 = message(id: "m2", role: "assistant", content: "second message")
        let next = state([m1, m2, m3, m4], topicId: "topic-A", canLoadEarlier: false)

        let p = plan(applied: applied, next: next)
        XCTAssertTrue(p.statements.contains(where: { $0.contains("prependEarlier") }),
                      "head extension MUST emit prependEarlier (was a documented KNOWN GAP)")
        XCTAssertFalse(p.statements.contains(where: { $0.contains("upsertMessages") }),
                       "head-only extension must NOT route through upsertMessages")

        // Execute against the live template.
        await executePlan(p, "loadEarlier → prependEarlier")

        // Verify DOM order: oldest first.
        let orderJSON = try await raw("""
        JSON.stringify(
          Array.from(document.querySelectorAll('.msg[data-id]'))
               .map(n => n.dataset.id)
        )
        """) as? String ?? "[]"
        let ids = (try? JSONSerialization.jsonObject(with: Data(orderJSON.utf8)) as? [String]) ?? []
        XCTAssertEqual(ids, ["m1", "m2", "m3", "m4"],
                       "load-earlier must place older messages at the TOP in chronological order, got: \(ids)")

        let finalCount = try await msgCount()
        XCTAssertEqual(finalCount, 4,
                       "all 4 messages must be in the DOM after load-earlier")
    }
}
