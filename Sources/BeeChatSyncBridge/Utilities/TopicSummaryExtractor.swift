import Foundation
import BeeChatPersistence

// MARK: - Extraction prompt

/// Builds the extraction prompt sent to the agent (spec §3.3).
private func extractionPrompt(topicName: String, projectName: String?) -> String {
    let projectInfo: String
    if let project = projectName {
        projectInfo = project
    } else {
        projectInfo = "none"
    }

    return """
Read the recent conversation messages for topic "\(topicName)" (project: \(projectInfo)).

Return a JSON object with these keys:
- "state": string — brief description of what is currently being worked on and what is pending
- "decisions": array of strings — explicit agreements reached on specific choices, directions, or approaches
- "corrections": array of strings — things identified as wrong where the fix was confirmed
- "open_questions": array of strings — topics discussed but left unresolved with intent to revisit

Rules:
- ONLY extract items that are about the project or the work being done in this topic
- Require a specific, actionable outcome — not just "let's do something"
- Do NOT extract: social plans, tool preferences, debugging attempts that didn't converge, brainstorming that didn't reach a conclusion, casual discussion
- Return empty arrays for keys where nothing durable was found
- If nothing durable was found at all, return all empty arrays and empty state

Output ONLY the JSON object, no markdown formatting, no explanation.
"""
}

// MARK: - JSON parsing

/// Parses the agent's response into a `TopicSummaryExtracted` struct.
/// Handles common formatting issues (markdown code fences, trailing text).
private func parseExtractionResponse(_ text: String) -> TopicSummaryExtracted? {
    var cleaned = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

    // Strip markdown code fences if present
    if cleaned.hasPrefix("```") {
        if let closingRange = cleaned.range(of: "```", options: .backwards),
           closingRange.lowerBound > cleaned.index(cleaned.startIndex, offsetBy: 3) {
            let openingEnd = cleaned.index(cleaned.startIndex, offsetBy: 3)
            var inner = String(cleaned[openingEnd...cleaned.index(before: closingRange.lowerBound)])
            inner = inner.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if inner.hasPrefix("json") {
                inner = String(inner.dropFirst(4)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
            cleaned = inner
        }
    }

    // Try to find JSON object boundaries
    if let startIdx = cleaned.firstIndex(of: "{"),
       let endIdx = cleaned.lastIndex(of: "}") {
        cleaned = String(cleaned[startIdx...endIdx])
    }

    guard let data = cleaned.data(using: .utf8) else { return nil }

    do {
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawExtractionResponse.self, from: data)
        return TopicSummaryExtracted(
            state: raw.state,
            decisions: raw.decisions,
            corrections: raw.corrections,
            openQuestions: raw.openQuestions
        )
    } catch {
        print("[TopicSummaryExtractor] JSON parse failed: \(error)")
        return nil
    }
}

/// Raw response matching the JSON keys in the extraction prompt.
private struct RawExtractionResponse: Codable {
    var state: String
    var decisions: [String]
    var corrections: [String]
    var open_questions: [String]

    var openQuestions: [String] { open_questions }
}

// MARK: - Extractor

/// Extracts durable items from a topic's recent messages via a chat.send call.
///
/// Uses the topic's real session key so that the EventRouter can route streaming
/// responses back correctly. Waits for any current streaming to settle before sending
/// the extraction prompt.
///
/// Phase 2.1a: Multi-turn streaming awareness. When the model makes tool calls before
/// returning JSON, each tool call completes a streaming cycle. The extractor now skips
/// tool-call completions and continues waiting until the model produces a text response
/// that parses as valid `TopicSummaryExtracted` JSON.
///
/// - Parameters:
///   - topicId: The topic's unique identifier.
///   - topicName: The topic's display name.
///   - projectPath: The project's root path, or nil for unbound topics.
///   - bridge: The SyncBridge instance for chat.send.
/// - Returns: The extraction result, or nil if the call failed or nothing durable was found.
public enum TopicSummaryExtractor {

    /// Extraction timeout — if the agent doesn't produce valid JSON within this time, return nil.
    /// Bumped from 120s to 180s: tool-heavy responses (e.g. LCM grep, code_execution) can
    /// take 98s+ before the model produces JSON. 180s gives margin without being absurd.
    private static let extractionTimeout: TimeInterval = 180

    /// Result type for extraction outcomes, allowing the caller to distinguish
    /// failure modes (parse failure, timeout, tool-call exhaustion).
    public enum ExtractionResult {
        case success(TopicSummaryExtracted)
        case noContent
        case timedOut
        case failed(reason: String)
    }

    /// Extracts durable items from a topic's recent messages.
    public static func extract(
        topicId: String,
        topicName: String,
        projectPath: String?,
        bridge: SyncBridge
    ) async -> ExtractionResult {
        // Look up the topic to get its session key
        let topicSessionKey: String
        do {
            let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
            guard let key = try topicRepo.fetchById(topicId)?.sessionKey else {
                print("[TopicSummaryExtractor] No session key found for topic \(topicId)")
                return .failed(reason: "No session key for this topic")
            }
            topicSessionKey = key
        } catch {
            print("[TopicSummaryExtractor] Failed to look up topic: \(error)")
            return .failed(reason: "Failed to look up topic: \(error.localizedDescription)")
        }

        // Build the extraction prompt
        let projectName = projectPath.flatMap {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let prompt = extractionPrompt(topicName: topicName, projectName: projectName)

        // Use the topic's real session key for both send and receive.
        // The gateway routes streaming responses back on this key, so a synthetic
        // key would never receive any events (the EventRouter dispatches by the
        // gateway's session key, not a client-side UUID).
        //
        // To avoid race conditions with live streaming, we wait for any current
        // streaming to finish before sending the extraction prompt.
        let responseResult = await sendAndWaitForResponse(
            sessionKey: topicSessionKey,
            prompt: prompt,
            bridge: bridge
        )

        switch responseResult {
        case .content(let response):
            // Parse the JSON response
            if let parsed = parseExtractionResponse(response) {
                return .success(parsed)
            } else {
                print("[TopicSummaryExtractor] Failed to parse JSON from response:\n\(response.prefix(200))")
                return .failed(reason: "Model did not return valid summary")
            }
        case .noContent:
            return .noContent
        case .timedOut:
            return .timedOut
        case .toolCallExhaustion:
            return .failed(reason: "Model made too many tool-call turns without producing a summary")
        case .sendFailed(let error):
            return .failed(reason: "Send failed: \(error)")
        }
    }

    /// Convenience wrapper that returns the extracted value or nil.
    /// Used by callers that don't need to distinguish failure modes.
    public static func extractValue(
        topicId: String,
        topicName: String,
        projectPath: String?,
        bridge: SyncBridge
    ) async -> TopicSummaryExtracted? {
        switch await extract(topicId: topicId, topicName: topicName, projectPath: projectPath, bridge: bridge) {
        case .success(let extracted): return extracted
        default: return nil
        }
    }

    // MARK: - Internal helpers

    /// Result of waiting for a streaming response — distinguishes failure modes.
    private enum ResponseResult {
        case content(String)              // Got parseable text content
        case noContent                     // Empty/whitespace-only response
        case timedOut                      // Extraction timeout exceeded
        case toolCallExhaustion            // Too many tool-call turns without text
        case sendFailed(error: String)     // chat.send failed
    }

    /// Sends the extraction prompt and waits for the streaming response.
    ///
    /// Phase 2.1a: Multi-turn streaming awareness.
    ///
    /// When the model makes tool calls (e.g. `lcm_grep`, `sessions_list`, `code_execution`),
    /// each tool call completes a streaming cycle. The SyncBridge fires `processChatFinal`,
    /// sets `completedContent`, and clears `streamingSessionKeys`. The extractor must NOT
    /// exit on these intermediate completions — it must continue waiting until the model
    /// produces a text response that looks like JSON.
    ///
    /// **Key assumptions:**
    /// - When a completion contains both text and tool calls, we skip the entire completion.
    ///   The model re-emits any meaningful text in its final response.
    /// - `streamingContent(for:)` returns assembled content from the streaming buffer,
    ///   not raw deltas. Verified: SyncBridge builds the buffer via `replace` (first delta)
    ///   or `+=` (subsequent deltas), then moves it to `completedContent` on final.
    private static func sendAndWaitForResponse(
        sessionKey: String,
        prompt: String,
        bridge: SyncBridge
    ) async -> ResponseResult {
        // Wait for any current streaming on this session to finish,
        // so we don't capture stale content from a live conversation.
        let waitStart = Date()
        while await bridge.isSessionStreaming(sessionKey) {
            guard Date().timeIntervalSince(waitStart) < 30 else {
                print("[TopicSummaryExtractor] Timed out waiting for current streaming to finish")
                return .sendFailed(error: "Timed out waiting for current streaming to finish")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Clear any leftover completed content from a previous response
        await bridge.clearCompletedContent(for: sessionKey)

        // Send the extraction message
        do {
            let idempotencyKey = "topic-extract-\(UUID().uuidString)"
            _ = try await bridge.sendExtractionMessage(
                sessionKey: sessionKey,
                message: prompt,
                idempotencyKey: idempotencyKey
            )
        } catch {
            print("[TopicSummaryExtractor] chat.send failed: \(error)")
            return .sendFailed(error: error.localizedDescription)
        }

        // Wait for the streaming response to start and then complete.
        // Phase 2.1a: Loop through multiple streaming cycles — skip tool-call
        // completions, validate text completions before returning.
        let startTime = Date()
        var seenStreaming = false
        var attemptCount = 0
        let maxAttempts = 20  // Safety: don't loop forever on pathological model behavior

        while Date().timeIntervalSince(startTime) < extractionTimeout {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return .noContent }

            let isStreaming = await bridge.isSessionStreaming(sessionKey)

            if isStreaming {
                seenStreaming = true
                continue
            }

            // Streaming just stopped — check what we got
            guard seenStreaming else { continue }

            let content = await bridge.streamingContent(for: sessionKey)
            await bridge.clearCompletedContent(for: sessionKey)

            // Rule 1: Skip if content looks like a tool call (no parseable text)
            // Assumption: When a completion contains both text and tool calls,
            // we skip the entire completion. The model re-emits meaningful text
            // in its final response.
            if looksLikeToolCall(content) {
                attemptCount += 1
                if attemptCount >= 5 {
                    print("[TopicSummaryExtractor] Warning: \(attemptCount) tool-call turns so far, still waiting")
                }
                if attemptCount >= maxAttempts {
                    print("[TopicSummaryExtractor] Too many tool-call turns (\(maxAttempts)), giving up")
                    return .toolCallExhaustion
                }
                // Reset streaming flag — wait for the next response turn
                // (tool results will trigger new streaming from the gateway)
                seenStreaming = false
                continue
            }

            // Rule 2: Try to parse as JSON before returning.
            // The model may output a preamble (e.g. "Here is the summary:")
            // before the JSON block. If parsing fails, keep waiting — the
            // model might still be composing its response.
            if parseExtractionResponse(content) != nil {
                // Successfully parsed — this is the final response
                return .content(content)
            }

            // Unparseable text — could be a preamble or partial response. Keep waiting.
            attemptCount += 1
            if attemptCount >= 5 {
                print("[TopicSummaryExtractor] Warning: \(attemptCount) unparseable turns so far, still waiting")
            }
            if attemptCount >= maxAttempts {
                print("[TopicSummaryExtractor] Too many unparseable turns (\(maxAttempts)), giving up")
                return .toolCallExhaustion
            }
            seenStreaming = false
            continue
        }

        print("[TopicSummaryExtractor] Extraction timed out after \(extractionTimeout)s")
        return .timedOut
    }

    /// Heuristic: does this content look like a tool call response rather than user-facing text?
    ///
    /// Tool call completions contain function call blocks with no user-facing text.
    /// The SyncBridge's `completedContent` holds the assembled streaming buffer —
    /// this is the full accumulated text, not raw streaming deltas.
    ///
    /// **Assumption:** When a completion contains both text and tool calls,
    /// we skip the entire completion. The model re-emits any meaningful text
    /// in its final response.
    private static func looksLikeToolCall(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Anthropic format: contains tool_use blocks
        if trimmed.contains("\"type\":\"tool_use\"") { return true }
        // OpenAI format: contains function_call or tool_calls array
        if trimmed.contains("\"function_call\"") { return true }
        if trimmed.contains("\"tool_calls\"") { return true }
        // Empty or whitespace-only (common between tool-call turns)
        if trimmed.isEmpty { return true }
        return false
    }
}
