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
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip markdown code fences if present
    if cleaned.hasPrefix("```") {
        // Find the closing ```
        if let closingRange = cleaned.range(of: "```", options: .backwards),
           closingRange.lowerBound > cleaned.index(cleaned.startIndex, offsetBy: 3) {
            // Strip language tag if present (```json)
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
        // The JSON uses snake_case keys from the prompt
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
        // Try again with more lenient parsing
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

/// Extracts durable items from a topic's recent messages via a local chat.send call.
///
/// Flow (spec §4.2):
/// 1. Reads last 50 messages from the topic's local SQLite (or since last save timestamp)
/// 2. Sends extraction prompt via `bridge.chatSend()`
/// 3. Waits for the agent's response via the bridge's streaming mechanism
/// 4. Parses the JSON response into `TopicSummaryExtracted`
/// 5. Returns nil if response is empty or unparseable
///
/// Note: Uses existing `chat.send` RPC — no new gateway methods, no subagent spawning.
public enum TopicSummaryExtractor {

    /// Extraction timeout — if the agent doesn't respond within this time, return nil.
    private static let extractionTimeout: TimeInterval = 120

    /// Extracts durable items from a topic's recent messages.
    ///
    /// - Parameters:
    ///   - topicId: The topic's unique identifier.
    ///   - topicName: The topic's display name.
    ///   - projectPath: The project's root path, or nil for unbound topics.
    ///   - bridge: The SyncBridge instance for chat.send.
    /// - Returns: The extraction result, or nil if the call failed or nothing durable was found.
    public static func extract(
        topicId: String,
        topicName: String,
        projectPath: String?,
        bridge: SyncBridge
    ) async -> TopicSummaryExtracted? {
        guard let sessionKey = await sessionKeyForTopic(topicId: topicId) else {
            print("[TopicSummaryExtractor] No session key found for topic \(topicId)")
            return nil
        }

        // Build the extraction prompt
        let projectName = projectPath.flatMap {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let prompt = extractionPrompt(topicName: topicName, projectName: projectName)

        // Send via chat.send and wait for response
        let response = await sendAndWaitForResponse(
            sessionKey: sessionKey,
            prompt: prompt,
            bridge: bridge
        )

        guard let response = response else {
            print("[TopicSummaryExtractor] No response received or timed out")
            return nil
        }

        // Parse the JSON response
        let parsed = parseExtractionResponse(response)
        return parsed
    }

    // MARK: - Internal helpers

    /// Look up the session key for a topic ID from the local database.
    private static func sessionKeyForTopic(topicId: String) async -> String? {
        do {
            let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
            guard let topic = try topicRepo.fetchById(topicId) else { return nil }
            return topic.sessionKey
        } catch {
            print("[TopicSummaryExtractor] Failed to look up topic: \(error)")
            return nil
        }
    }

    /// Sends the extraction prompt and waits for the streaming response.
    ///
    /// Uses the bridge's sendMessage + streaming buffer mechanism.
    /// This is a simplified version that sends the prompt and reads the response
    /// from the bridge's streaming buffer after completion.
    private static func sendAndWaitForResponse(
        sessionKey: String,
        prompt: String,
        bridge: SyncBridge
    ) async -> String? {
        // Use a continuation to wait for the streaming to complete
        let responseText = await withTaskGroup(of: String?.self) { group in

            // Task 1: Send the message
            group.addTask {
                do {
                    // Send the extraction prompt as a message
                    // We use a special idempotency key so we can track it
                    let idempotencyKey = "topic-extract-\(UUID().uuidString)"
                    _ = try await bridge.sendExtractionMessage(
                        sessionKey: sessionKey,
                        message: prompt,
                        idempotencyKey: idempotencyKey
                    )
                    return nil // send succeeded, response comes via Task 2
                } catch {
                    print("[TopicSummaryExtractor] chat.send failed: \(error)")
                    return nil
                }
            }

            // Task 2: Wait for streaming response
            group.addTask {
                // Poll the streaming buffer for this session key
                let startTime = Date()
                var seenStreaming = false

                while Date().timeIntervalSince(startTime) < extractionTimeout {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    guard !Task.isCancelled else { return nil as String? }

                    let current = await bridge.streamingContent(for: sessionKey)

                    if !current.isEmpty {
                        seenStreaming = true
                    }

                    // Check if streaming has finished for this session
                    let isStreaming = await bridge.isSessionStreaming(sessionKey)

                    if seenStreaming && !isStreaming {
                        // Response is complete
                        let final = await bridge.streamingContent(for: sessionKey)
                        return final.isEmpty ? nil : final
                    }
                }

                print("[TopicSummaryExtractor] Extraction timed out after \(extractionTimeout)s")
                return nil
            }

            // Wait for either task to complete; cancel the other
            var result: String? = nil
            for await value in group {
                if let v = value {
                    result = v
                    group.cancelAll()
                    break
                }
            }
            return result
        }

        return responseText
    }
}
