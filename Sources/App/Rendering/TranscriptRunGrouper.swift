import Foundation
import BeeChatPersistence

// MARK: - TranscriptRunGrouper
//
// Fold intermediate assistant "narration" blocks into a single collapsed
// disclosure (display grouping only — persistence is untouched).
//
// ## Why this exists
//
// The gateway legitimately stores multiple assistant text blocks per run
// (intermediate narration + final). In the transcript, every block was
// previously rendered as its own bubble — a full thought transcript that
// reads as near-duplicate noise to the user.
//
// ## Rule
//
// A "run" = consecutive `role == "assistant"` messages bounded by non-
// assistant messages (user / system) or by the start/end of the array.
//
//   [user, asst-A, asst-B, asst-C, user, asst-D]
//      run 1: asst-A, asst-B, asst-C (3 blocks)
//             → fold = (asst-A, asst-B), final = asst-C
//      run 2: asst-D (1 block)
//             → no fold (single block = "untouched")
//
// ## What this is NOT
//
// - **Not a merge.** Original Message values are preserved by reference in
//   `FoldedAssistantGroup.messages`. The grouper NEVER mutates or deletes
//   entries — it only re-shapes the rendering surface.
// - **Not a re-ordering.** Output preserves input order at the boundary level
//   (fold then final, then next message in source order).
// - **Not a persistence-layer change.** The fold is a Swift-side pre-pass
//   before the payload builder; GRDB / MessageRepository are untouched.
// - **Not streaming-aware.** The fold only applies to settled messages (the
//   in-flight streaming node is a separate DOM element managed by
//   `setStreaming`, not by this grouper).
//
// ## Threading
//
// Pure functions, no shared state. Safe to call from any actor.

enum TranscriptRunGrouper {

    // MARK: - Boundary invariant (do NOT silently change)
    //
    // This grouper assumes the gateway NEVER persists two model runs back-to-back
    // with no intervening non-assistant message. In practice this holds: a
    // new run begins when the user sends a message, and user messages are the
    // natural boundary. Tool-loop continuation / auto-retry / agent-initiated
    // runs WITHOUT a user/system boundary would merge into one fold and the
    // previous run's final answer would disappear into "Working…" — silent
    // content loss from the user's point of view.
    //
    // If the gateway ever emits back-to-back assistant runs without a
    // boundary, the fix is to surface a run id at the persistence layer
    // (NOT in this grouper) and pass it as part of the Message metadata.
    // Don't add an in-memory heuristic here — that would mask the
    // upstream invariant instead of fixing it.
    //
    // The grouper also assumes the input array is already ordered by
    // sequence/timestamp. The GRDB MessageRepository fetches with
    // `ORDER BY timestamp ASC` (see MessageRepository.swift) so this
    // invariant holds at the boundary; callers MUST NOT pass a
    // re-ordered slice.

    /// One rendered unit on the transcript. Either a standalone message
    /// (renders via the existing `buildMessage` JS path) or a fold entry
    /// (renders via the new `.msg-fold` disclosure path).
    indirect enum Item: Equatable {
        case message(Message)
        case folded(FoldedAssistantGroup)
    }

    /// A consecutive run of 2+ assistant messages where all-but-the-last
    /// are folded into a single disclosure bubble.
    ///
    /// `messages` is ordered oldest→newest (the same order as the source
    /// array slice). The last message in `messages` is rendered as a
    /// separate Item by the caller — `messages` here is only the folded
    /// intermediates.
    struct FoldedAssistantGroup: Equatable {
        let messages: [Message]
        var count: Int { messages.count }
    }

    /// Group `messages` into a sequence of Items where consecutive
    /// assistant blocks form runs and the all-but-last entries of each run
    /// are folded.
    ///
    /// Empty input → empty output. The output count satisfies:
    ///   folds(N assistant + other roles) ≤ N (one fold per multi-block run)
    /// and the count of unfolded assistant messages equals the input count
    /// of assistant messages (no assistant is dropped).
    static func group(_ messages: [Message]) -> [Item] {
        guard !messages.isEmpty else { return [] }
        var output: [Item] = []
        var pending: [Message] = []  // assistant-only buffer

        func flushPending() {
            // Empty: nothing to emit.
            guard !pending.isEmpty else { return }
            if pending.count == 1 {
                // Single-assistant run: untouched (no fold).
                output.append(.message(pending[0]))
            } else {
                // Multi-assistant run: fold the first (count - 1), keep the last standalone.
                let foldedSlice = pending.dropLast()
                let finalMessage = pending.last!
                output.append(.folded(FoldedAssistantGroup(messages: Array(foldedSlice))))
                output.append(.message(finalMessage))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for msg in messages {
            if msg.role == "assistant" {
                pending.append(msg)
            } else {
                flushPending()
                output.append(.message(msg))
            }
        }
        flushPending()
        return output
    }
}
