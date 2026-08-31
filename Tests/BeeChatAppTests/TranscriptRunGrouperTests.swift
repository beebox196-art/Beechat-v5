import XCTest
@testable import BeeChatApp
import BeeChatPersistence

// MARK: - TranscriptRunGrouper Tests
//
// Unit tests for the fold-intermediate-assistant-blocks display grouping
// logic. The grouper is pure (no I/O, no UI), so these tests don't need a
// live WKWebView — they assert the Swift-side group shape directly.
//
// Three behavioural contracts are pinned (per Adam's spec 2026-08-31):
//
//   1. **Multi-block run folds intermediates** — 2 narration blocks + 1 final
//      in a single run produces (fold[2], final).
//   2. **Single-assistant run is untouched** — no fold when only 1 assistant
//      block exists between user messages (the final block renders as today).
//   3. **Two runs separated by a user message are NOT merged** — each run
//      is grouped independently; the user message is the boundary.
//
// All three requirements are guarded by separate tests below so any future
// regression fails fast and loud.

final class TranscriptRunGrouperTests: XCTestCase {

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

    // MARK: - Requirement 1: 2 narration + 1 final → folded

    /// A run with two intermediate assistant blocks plus a final block must
    /// produce ONE fold covering the two intermediates and ONE standalone
    /// message for the final block. The fold's count is 2.
    func testTwoNarrationPlusFinalFoldsIntermediates() {
        let user1 = message(id: "u1", role: "user", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let asst1 = message(id: "a1", role: "assistant", content: "Thinking step 1",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_001))
        let asst2 = message(id: "a2", role: "assistant", content: "Thinking step 2",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_002))
        let asst3 = message(id: "a3", role: "assistant", content: "Final answer",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_003))

        let items = TranscriptRunGrouper.group([user1, asst1, asst2, asst3])

        // Three items: user, fold(a1, a2), message(a3).
        XCTAssertEqual(items.count, 3, "Expected 3 items: user, fold(2), final. Got: \(items)")
        // Item 0: the user message — standalone.
        guard case .message(let userMsg) = items[0] else {
            XCTFail("Item 0 should be the user message standalone. Got: \(items[0])")
            return
        }
        XCTAssertEqual(userMsg.id, "u1")
        // Item 1: the fold containing the two intermediate assistant blocks.
        guard case .folded(let group) = items[1] else {
            XCTFail("Item 1 should be a fold with 2 messages. Got: \(items[1])")
            return
        }
        XCTAssertEqual(group.count, 2, "Fold must contain 2 intermediate messages")
        XCTAssertEqual(group.messages.map { $0.id }, ["a1", "a2"],
                       "Fold must hold the intermediates in source order, got: \(group.messages.map { $0.id })")
        // Item 2: the final assistant message — standalone (renders exactly as today).
        guard case .message(let finalMsg) = items[2] else {
            XCTFail("Item 2 should be the final message standalone. Got: \(items[2])")
            return
        }
        XCTAssertEqual(finalMsg.id, "a3",
                       "Final block must render as a standalone message (unchanged from today)")
    }

    // MARK: - Requirement 2: single-assistant run → untouched

    /// A run with exactly ONE assistant message between user messages must
    /// render as a single standalone message — no fold entry, no extra
    /// chrome. The output count equals the input count for this case.
    func testSingleAssistantRunIsUntouched() {
        let user1 = message(id: "u1", role: "user")
        let asst1 = message(id: "a1", role: "assistant", content: "Only one block")
        let user2 = message(id: "u2", role: "user")

        let items = TranscriptRunGrouper.group([user1, asst1, user2])

        XCTAssertEqual(items.count, 3,
                       "Single-assistant run must NOT introduce a fold; count must equal input. Got: \(items)")
        // All three items are .message (no .folded).
        XCTAssertTrue(items.allSatisfy { item in
            if case .message = item { return true } else { return false }
        }, "Single-block run produces no fold entries. Got: \(items)")
        // The assistant id is preserved verbatim.
        if case .message(let m) = items[1] {
            XCTAssertEqual(m.id, "a1")
            XCTAssertEqual(m.content, "Only one block")
        } else {
            XCTFail("Middle item must be the assistant message")
        }
    }

    // MARK: - Requirement 3: two runs separated by a user message are NOT merged

    /// Two assistant runs separated by a user message must remain two
    /// independent runs — the user message is the boundary. Folds MUST NOT
    /// bleed across the user boundary.
    func testTwoRunsSeparatedByUserAreNotMerged() {
        // Run 1: 1 user + 3 assistant (a1, a2, a3) → fold(a1, a2), final(a3)
        // Boundary: u2
        // Run 2: 1 user + 2 assistant (a4, a5) → fold(a4), final(a5)
        let user1 = message(id: "u1", role: "user",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let a1 = message(id: "a1", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        let a2 = message(id: "a2", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_020))
        let a3 = message(id: "a3", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_030))
        let user2 = message(id: "u2", role: "user",
                            timestamp: Date(timeIntervalSince1970: 1_700_000_100))
        let a4 = message(id: "a4", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_110))
        let a5 = message(id: "a5", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_120))

        let items = TranscriptRunGrouper.group([user1, a1, a2, a3, user2, a4, a5])

        // Expected: u1, fold(a1, a2), a3, u2, fold(a4), a5 → 6 items.
        XCTAssertEqual(items.count, 6,
                       "Two runs separated by a user message must NOT merge. Got: \(items)")

        // Item 0: user1.
        guard case .message(let u1) = items[0] else { XCTFail("Item 0 must be u1"); return }
        XCTAssertEqual(u1.id, "u1")

        // Item 1: fold(a1, a2) — only the FIRST run's intermediates.
        guard case .folded(let fold1) = items[1] else { XCTFail("Item 1 must be a fold"); return }
        XCTAssertEqual(fold1.count, 2)
        XCTAssertEqual(fold1.messages.map { $0.id }, ["a1", "a2"],
                       "Run 1 fold must NOT contain a3 or any run-2 ids")

        // Item 2: a3 — final of run 1.
        guard case .message(let r1Final) = items[2] else { XCTFail("Item 2 must be a3"); return }
        XCTAssertEqual(r1Final.id, "a3")

        // Item 3: u2 — the boundary user message.
        guard case .message(let u2) = items[3] else { XCTFail("Item 3 must be u2"); return }
        XCTAssertEqual(u2.id, "u2")

        // Item 4: fold(a4) — single intermediate of run 2.
        guard case .folded(let fold2) = items[4] else { XCTFail("Item 4 must be a fold"); return }
        XCTAssertEqual(fold2.count, 1)
        XCTAssertEqual(fold2.messages.map { $0.id }, ["a4"],
                       "Run 2 fold must contain only a4")

        // Item 5: a5 — final of run 2.
        guard case .message(let r2Final) = items[5] else { XCTFail("Item 5 must be a5"); return }
        XCTAssertEqual(r2Final.id, "a5")
    }

    // MARK: - Adjacent edge cases

    /// Empty input → empty output. (Sanity guard.)
    func testEmptyInputProducesEmptyOutput() {
        XCTAssertEqual(TranscriptRunGrouper.group([]), [])
    }

    /// A run starting at the head (no leading user message) must still fold.
    func testLeadingAssistantRunFolds() {
        let a1 = message(id: "a1", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        let a2 = message(id: "a2", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_020))
        let a3 = message(id: "a3", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_030))

        let items = TranscriptRunGrouper.group([a1, a2, a3])

        XCTAssertEqual(items.count, 2)
        guard case .folded(let g) = items[0] else { XCTFail("Item 0 must be a fold"); return }
        XCTAssertEqual(g.count, 2)
        guard case .message(let m) = items[1] else { XCTFail("Item 1 must be the final"); return }
        XCTAssertEqual(m.id, "a3")
    }

    /// A trailing assistant run (no trailing user) must still fold.
    /// Run is [a1, a2] — 2 messages — so the grouper produces
    /// (fold(a1), standalone(a2)) for a total of 3 items including u1.
    func testTrailingAssistantRunFolds() {
        let u1 = message(id: "u1", role: "user",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let a1 = message(id: "a1", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        let a2 = message(id: "a2", role: "assistant",
                         timestamp: Date(timeIntervalSince1970: 1_700_000_020))

        let items = TranscriptRunGrouper.group([u1, a1, a2])

        XCTAssertEqual(items.count, 3)
        guard case .message(let user) = items[0] else { XCTFail("Item 0 must be u1"); return }
        XCTAssertEqual(user.id, "u1")
        guard case .folded(let g) = items[1] else { XCTFail("Item 1 must be a fold of a1"); return }
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.messages.map { $0.id }, ["a1"])
        guard case .message(let final) = items[2] else { XCTFail("Item 2 must be the final a2"); return }
        XCTAssertEqual(final.id, "a2")
    }

    /// System messages are boundary markers (not folded, don't get folded into).
    func testSystemMessageIsBoundary() {
        let sys = message(id: "s1", role: "system")
        let a1 = message(id: "a1", role: "assistant")
        let a2 = message(id: "a2", role: "assistant")
        let a3 = message(id: "a3", role: "assistant")

        let items = TranscriptRunGrouper.group([sys, a1, a2, a3])

        // system, fold(a1, a2), a3
        XCTAssertEqual(items.count, 3)
        if case .message(let m) = items[0] { XCTAssertEqual(m.id, "s1") } else { XCTFail("system must be standalone") }
        if case .folded(let g) = items[1] { XCTAssertEqual(g.count, 2) } else { XCTFail("must be fold") }
        if case .message(let m) = items[2] { XCTAssertEqual(m.id, "a3") } else { XCTFail("must be a3") }
    }

    // MARK: - Invariant: no assistant message is dropped

    /// The total number of assistant messages in the source array must equal
    /// the sum of fold-member counts plus the count of standalone assistant
    /// Items. (No assistant is dropped, merged, or duplicated.)
    func testNoAssistantMessageIsDropped() {
        let user1 = message(id: "u1", role: "user")
        let a1 = message(id: "a1", role: "assistant")
        let a2 = message(id: "a2", role: "assistant")
        let a3 = message(id: "a3", role: "assistant")
        let user2 = message(id: "u2", role: "user")
        let a4 = message(id: "a4", role: "assistant")

        let source = [user1, a1, a2, a3, user2, a4]
        let items = TranscriptRunGrouper.group(source)

        var foldedAssistantCount = 0
        var standaloneAssistantCount = 0
        for item in items {
            switch item {
            case .folded(let g):
                foldedAssistantCount += g.count
            case .message(let m):
                if m.role == "assistant" {
                    standaloneAssistantCount += 1
                }
            }
        }
        let totalAssistant = foldedAssistantCount + standaloneAssistantCount
        XCTAssertEqual(totalAssistant, 4,
                       "Sum of folded + standalone assistant count must equal source assistant count (4). Got: folded=\(foldedAssistantCount), standalone=\(standaloneAssistantCount)")
    }

    // MARK: - groupedPayloads produces the expected payload shape

    /// The payload array exposed to the JS bridge must contain a synthetic
    /// fold payload with the `fold` field, and the final block must be a
    /// normal message payload (id, role, html — no `fold` field).
    func testGroupedPayloadsProducesFoldAndStandalonePayloads() {
        let user1 = message(id: "u1", role: "user")
        let a1 = message(id: "a1", role: "assistant", content: "Thinking step 1")
        let a2 = message(id: "a2", role: "assistant", content: "Thinking step 2")
        let a3 = message(id: "a3", role: "assistant", content: "Final answer")

        let payloads = TranscriptPayloadBuilder.groupedPayloads([user1, a1, a2, a3])

        XCTAssertEqual(payloads.count, 3)

        // Payload 0: user message — no fold field, role=user.
        let p0 = payloads[0]
        XCTAssertEqual(p0["id"] as? String, "u1")
        XCTAssertEqual(p0["role"] as? String, "user")
        XCTAssertNil(p0["fold"], "User message payload must NOT carry a fold field")

        // Payload 1: the fold covering a1 + a2.
        let p1 = payloads[1]
        XCTAssertEqual(p1["role"] as? String, "assistant",
                       "Fold payload uses role='assistant' — the presence of `fold` is the sole discriminator")
        let fold = p1["fold"] as? [String: Any]
        XCTAssertNotNil(fold, "Fold payload must carry a `fold` field")
        XCTAssertEqual(fold?["label"] as? String, "Working…",
                       "Fold label must be 'Working…' per Adam's spec")
        XCTAssertEqual(fold?["count"] as? Int, 2,
                       "Fold count must equal the number of intermediate blocks")
        let blocks = fold?["blocks"] as? [String]
        XCTAssertEqual(blocks?.count, 2, "Fold must carry 2 sanitized HTML blocks")
        let ids = fold?["ids"] as? [String]
        XCTAssertEqual(ids, ["a1", "a2"], "Fold must preserve the original ids")

        // Payload 2: the final assistant message — renders exactly as today.
        let p2 = payloads[2]
        XCTAssertEqual(p2["id"] as? String, "a3",
                       "Final block must keep its original id (synthetic __fold_ prefix must NOT be applied)")
        XCTAssertEqual(p2["role"] as? String, "assistant",
                       "Final block must render as a normal assistant message, not as a fold")
        XCTAssertNil(p2["fold"],
                     "Final block payload must NOT carry a fold field — it renders exactly as today")
        XCTAssertNotNil(p2["html"] as? String, "Final block must carry html like any other assistant message")
    }

    /// The fold payload's id must be stable across re-applies so the JS
    /// template can upsert the fold entry in place when the underlying
    /// messages change.
    func testFoldPayloadIdIsStableAcrossCalls() {
        let a1 = message(id: "stable-id-001", role: "assistant")
        let a2 = message(id: "stable-id-002", role: "assistant")
        let a3 = message(id: "stable-id-003", role: "assistant")

        let p1 = TranscriptPayloadBuilder.groupedPayloads([a1, a2, a3])
        let p2 = TranscriptPayloadBuilder.groupedPayloads([a1, a2, a3])

        let id1 = (p1[0]["id"] as? String) ?? ""
        let id2 = (p2[0]["id"] as? String) ?? ""
        XCTAssertEqual(id1, id2, "Fold payload id must be stable across calls")
        XCTAssertTrue(id1.hasPrefix("__fold_"), "Fold id must use the __fold_<firstId> prefix")
        XCTAssertTrue(id1.contains("stable-id-001"), "Fold id must derive from the FIRST folded message id")
    }

    /// The fold payload's `blocks` must be sanitized HTML (not raw markdown)
    /// — the JS template assigns it via innerHTML and the sanitizer is the
    /// only trust boundary (route plan §4.6).
    func testFoldPayloadBlocksAreSanitizedHTML() {
        let a1 = message(id: "a1", role: "assistant",
                         content: "**bold** and [link](https://example.com)")
        let a2 = message(id: "a2", role: "assistant",
                         content: "<script>alert('xss')</script>safe")
        let a3 = message(id: "a3", role: "assistant", content: "final")

        let payloads = TranscriptPayloadBuilder.groupedPayloads([a1, a2, a3])
        let fold = payloads[0]["fold"] as? [String: Any]
        let blocks = fold?["blocks"] as? [String] ?? []

        XCTAssertEqual(blocks.count, 2)
        // Markdown → HTML conversion happened.
        XCTAssertTrue(blocks[0].contains("<strong>bold</strong>"),
                      "Block 0 must have markdown converted. Got: \(blocks[0])")
        XCTAssertTrue(blocks[0].contains("href=\"https://example.com\""),
                      "Block 0 must render link with href. Got: \(blocks[0])")
        // Script tag stripped.
        XCTAssertFalse(blocks[1].localizedCaseInsensitiveContains("<script"),
                       "Block 1 must NOT contain a script tag. Got: \(blocks[1])")
        // Raw markdown asterisks must not survive.
        XCTAssertFalse(blocks[0].contains("**"),
                       "Block 0 must not leak raw markdown asterisks. Got: \(blocks[0])")
    }
}
