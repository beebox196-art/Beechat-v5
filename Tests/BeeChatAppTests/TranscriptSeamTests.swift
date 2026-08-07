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
                         content: String = "hello **world**",
                         timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Message {
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

    // MARK: - WP-2I day-headers: setTopic across boundary
    //
    // REGRESSION GUARD for the day-header insertion on setTopic.
    // Spec: Docs/Specs/Active/WP-2I-day-headers.md §"Per-call insertion logic".
    // When setTopic is given messages spanning two calendar days, exactly
    // one .day-header must be inserted between them, labelled with the
    // second message's date. The first message gets no header (iMessage
    // convention).
    func testDayHeaderInsertedOnSetTopicAcrossBoundary() async throws {
        // Construct two messages on different calendar days. Use noon UTC
        // to avoid DST / timezone edge cases in label computation — the
        // template uses local time, so we anchor to a stable timezone in
        // the assertions below.
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // m1 on yesterday, m2 on today → exactly one header between them.
        let m1 = message(id: "d1m1", role: "user",
                         content: "yesterday msg",
                         timestamp: yesterday.addingTimeInterval(60 * 60 * 12))  // noon
        let m2 = message(id: "d1m2", role: "assistant",
                         content: "today msg",
                         timestamp: today.addingTimeInterval(60 * 60 * 12))     // noon
        let st = state([m1, m2], topicId: "topic-headers")
        await executePlan(plan(applied: nil, next: st), "setTopic → day headers")

        // Query DOM for .day-header elements.
        let headersJSON = try await raw("""
        JSON.stringify(
          Array.from(document.querySelectorAll('.day-header')).map(h => ({
            date: h.dataset.date, text: h.textContent
          }))
        )
        """) as? String ?? "[]"
        let headers = (try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8)) as? [[String: String]]) ?? []
        XCTAssertEqual(headers.count, 1,
                       "exactly one day-header between two messages on different days, got: \(headers)")

        // The single header must be labelled with today's date (since it
        // sits before today's message).
        if let only = headers.first {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let todayKey = df.string(from: today)
            XCTAssertEqual(only["date"], todayKey,
                           "header data-date must be today's local date, got: \(only)")
            // Label should be 'Today' (we constructed messages at noon local).
            XCTAssertEqual(only["text"], "Today",
                           "header text should be 'Today' for current day, got: \(only)")
        }

        // Position check: the header must sit between the two messages
        // (sibling of .msg, child of #transcript). Filter out the
        // persistent #load-earlier button and #thinking node so we
        // assert only the message-and-header sequence.
        let betweenOrder = try await raw("""
        (function() {
          const ids = Array.from(document.querySelectorAll('#transcript > *'))
            .filter(n => n.classList.contains('msg') || n.classList.contains('day-header'))
            .map(n => n.dataset.id || ('HDR(' + n.dataset.date + ')'));
          return JSON.stringify(ids);
        })()
        """) as? String ?? "[]"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let todayKey = df.string(from: today)
        let expectedOrder = "[\"d1m1\",\"HDR(\(todayKey))\",\"d1m2\"]"
        XCTAssertEqual(betweenOrder, expectedOrder,
                       "header must sit between d1m1 and d1m2 in #transcript, got: \(betweenOrder)")

        // Sanity: messages on the same day get NO header.
        let sameDay = message(id: "d1m3", role: "user",
                              content: "same day as m2",
                              timestamp: today.addingTimeInterval(60 * 60 * 13))
        let stSame = state([m1, m2, sameDay], topicId: "topic-headers")
        await executePlan(plan(applied: st, next: stSame), "setTopic → same day")
        let headersAfterSame = try await raw("document.querySelectorAll('.day-header').length") as? Int ?? -1
        XCTAssertEqual(headersAfterSame, 1,
                       "messages on the same day must NOT add a header, got \(headersAfterSame)")
    }

    // MARK: - WP-2I day-headers: upsertMessages across boundary
    //
    // REGRESSION GUARD for the day-header insertion on upsertMessages.
    // When upsertMessages appends a message whose date differs from the
    // last existing message, a header must be inserted before the new
    // message. When upserting to the same date, no header.
    func testDayHeaderInsertedOnUpsertMessagesAcrossBoundary() async throws {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Initial topic: a single message on yesterday.
        let m1 = message(id: "u1m1", role: "user",
                         content: "yesterday",
                         timestamp: yesterday.addingTimeInterval(60 * 60 * 12))
        let initial = state([m1], topicId: "topic-upsert")
        await executePlan(plan(applied: nil, next: initial), "setTopic → yesterday")

        // Now upsert a message on today. Expect a header before it.
        let m2 = message(id: "u1m2", role: "assistant",
                         content: "today",
                         timestamp: today.addingTimeInterval(60 * 60 * 12))
        let after = state([m1, m2], topicId: "topic-upsert")
        await executePlan(plan(applied: initial, next: after), "upsert → today")

        // Exactly one header, between m1 and m2.
        let headersJSON = try await raw("""
        JSON.stringify(
          Array.from(document.querySelectorAll('.day-header')).map(h => ({
            date: h.dataset.date, text: h.textContent
          }))
        )
        """) as? String ?? "[]"
        let headers = (try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8)) as? [[String: String]]) ?? []
        XCTAssertEqual(headers.count, 1,
                       "upsert across day boundary must insert exactly one header, got: \(headers)")

        // Now upsert another message on today. Expect NO additional header.
        let m3 = message(id: "u1m3", role: "user",
                         content: "today again",
                         timestamp: today.addingTimeInterval(60 * 60 * 13))
        let after3 = state([m1, m2, m3], topicId: "topic-upsert")
        await executePlan(plan(applied: after, next: after3), "upsert → same day")
        let headersAfterSame = try await raw("document.querySelectorAll('.day-header').length") as? Int ?? -1
        XCTAssertEqual(headersAfterSame, 1,
                       "upsert on same day must NOT add another header, got \(headersAfterSame)")
    }

    // MARK: - WP-2I day-headers: prependEarlier across boundary
    //
    // REGRESSION GUARD for the day-header insertion when load-earlier
    // prepends older messages across a date boundary. This is the test
    // Kieran called out as a must-have: without it, this is exactly the
    // kind of 'obvious JS' that breaks the E10 backstop vacuously.
    //
    // Construct: setTopic with [msg on today], then prependEarlier with
    // [msg on 2-days-ago, msg on yesterday]. Expect:
    //   - One header before the first prepended message (date 2-days-ago)
    //   - One header between the two prepended messages (date yesterday)
    //   - One header between the last prepended (yesterday) and the
    //     first existing (today) — labelled with today's date.
    //   - Total: 3 headers, in correct positions.
    func testDayHeaderCorrectnessWhenPrependEarlierSpansBoundary() async throws {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!

        // Step 1: setTopic with a single message on today.
        let m_today = message(id: "p1_today", role: "user",
                              content: "today msg",
                              timestamp: today.addingTimeInterval(60 * 60 * 12))
        let applied = state([m_today], topicId: "topic-prepend-headers", canLoadEarlier: true)
        await executePlan(plan(applied: nil, next: applied), "setTopic → today")

        // Step 2: prependEarlier with 2 messages: one on 2-days-ago, one on yesterday.
        // Construct the next state so the builder emits prependEarlier.
        let m_2days = message(id: "p1_2days", role: "assistant",
                              content: "2 days ago",
                              timestamp: twoDaysAgo.addingTimeInterval(60 * 60 * 12))
        let m_yest = message(id: "p1_yest", role: "user",
                             content: "yesterday",
                             timestamp: yesterday.addingTimeInterval(60 * 60 * 12))
        let next = state([m_2days, m_yest, m_today], topicId: "topic-prepend-headers", canLoadEarlier: false)
        let p = plan(applied: applied, next: next)
        XCTAssertTrue(p.statements.contains(where: { $0.contains("prependEarlier") }),
                      "precondition: head extension must emit prependEarlier")
        await executePlan(p, "prependEarlier → spans 2 days + yesterday")

        // Read the DOM order, filtering out the persistent #load-earlier button
        // and #thinking node so the assertion is about message-and-header
        // sequence only.
        let orderJSON = try await raw("""
        (function() {
          return JSON.stringify(
            Array.from(document.querySelectorAll('#transcript > *'))
              .filter(n => n.classList.contains('msg') || n.classList.contains('day-header'))
              .map(n => {
                if (n.classList.contains('day-header')) return 'HDR(' + n.dataset.date + ')=' + n.textContent;
                return n.dataset.id;
              })
          );
        })()
        """) as? String ?? "[]"

        // Build expected headers from the local-timezone keys.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let k2 = df.string(from: twoDaysAgo)
        let ky = df.string(from: yesterday)
        let kt = df.string(from: today)
        let labelFor2 = dayHeaderLabel(for: twoDaysAgo)
        let labelForY = dayHeaderLabel(for: yesterday)
        let labelForT = dayHeaderLabel(for: today)
        let expected = "[\"HDR(\(k2))=\(labelFor2)\",\"p1_2days\",\"HDR(\(ky))=\(labelForY)\",\"p1_yest\",\"HDR(\(kt))=\(labelForT)\",\"p1_today\"]"

        XCTAssertEqual(orderJSON, expected,
                       "prepend-earlier across 2 date boundaries must insert 3 headers in correct positions.\nexpected: \(expected)\nactual:   \(orderJSON)")

        // Count check.
        let headerCount = try await raw("document.querySelectorAll('.day-header').length") as? Int ?? -1
        XCTAssertEqual(headerCount, 3,
                       "exactly 3 day-headers after prepend across 2 boundaries, got \(headerCount)")

        // The T3 scroll-anchor invariant must still hold (the headers
        // contribute to scrollHeight, so the host's T3 math still works).
        // We don't assert specific scrollHeight here — just that no JS
        // exception was thrown during the prepend (caught by executePlan).
    }

    /// Compute the day-header label for a given date, matching the template's
    /// dayHeaderLabel() logic so the test can assert expected text. Kept in
    /// lockstep with TranscriptTemplate.html:dateKey/dayHeaderLabel.
    private func dayHeaderLabel(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let targetKey = df.string(from: target)
        let todayKey = df.string(from: today)
        if targetKey == todayKey { return "Today" }
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        if targetKey == df.string(from: yesterday) { return "Yesterday" }
        let diffDays = cal.dateComponents([.day], from: target, to: today).day ?? 0
        if diffDays < 7 && diffDays >= 0 {
            let wf = DateFormatter()
            wf.dateFormat = "EEEE"
            wf.locale = Locale(identifier: "en_US_POSIX")
            return wf.string(from: target)
        }
        let sameYear = cal.component(.year, from: target) == cal.component(.year, from: today)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if sameYear {
            fmt.dateFormat = "EEE d MMM"
        } else {
            fmt.dateFormat = "EEE d MMM yyyy"
        }
        return fmt.string(from: target)
    }
}
