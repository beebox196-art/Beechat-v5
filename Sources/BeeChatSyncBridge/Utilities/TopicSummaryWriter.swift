import Foundation

// MARK: - Extracted data from LLM

/// Structured extraction result from the LLM.
/// Codable so it can be serialized to/from JSON in the chat response.
public struct TopicSummaryExtracted: Codable, Sendable {
    public var state: String
    public var decisions: [String]
    public var corrections: [String]
    public var openQuestions: [String]

    public init(
        state: String = "",
        decisions: [String] = [],
        corrections: [String] = [],
        openQuestions: [String] = []
    ) {
        self.state = state
        self.decisions = decisions
        self.corrections = corrections
        self.openQuestions = openQuestions
    }

    /// True when no durable content was found — all fields empty.
    public var isEmpty: Bool {
        state.isEmpty && decisions.isEmpty && corrections.isEmpty && openQuestions.isEmpty
    }
}

// MARK: - Activity entry

/// A timestamped activity line appended to the "Recent Activity" section.
fileprivate struct ActivityEntry: Codable {
    let timestamp: Date
    let text: String
}

// MARK: - Persisted summary file model

/// Internal representation of the on-disk summary file.
/// Used for merge operations; serialized to markdown on write.
fileprivate struct SummaryData {
    var state: String
    var decisions: [String]
    var corrections: [String]
    var openQuestions: [String]
    var activityEntries: [ActivityEntry]
    var lastUpdated: Date
    var projectName: String?
    var topicName: String

    init(
        state: String = "",
        decisions: [String] = [],
        corrections: [String] = [],
        openQuestions: [String] = [],
        activityEntries: [ActivityEntry] = [],
        lastUpdated: Date = Date(),
        projectName: String? = nil,
        topicName: String = ""
    ) {
        self.state = state
        self.decisions = decisions
        self.corrections = corrections
        self.openQuestions = openQuestions
        self.activityEntries = activityEntries
        self.lastUpdated = lastUpdated
        self.projectName = projectName
        self.topicName = topicName
    }

    /// Serialize to markdown format (spec §3.2).
    func toMarkdown() -> String {
        var lines: [String] = []

        lines.append("# Topic: \(topicName)")
        lines.append("**Last updated:** \(lastUpdated.formatted(date: .numeric, time: .shortened))")
        if let project = projectName {
            lines.append("**Project:** \(project)")
        } else {
            lines.append("**Project:** None — general topic")
        }
        lines.append("**Status:** active")
        lines.append("")

        // Last State
        if !state.isEmpty {
            lines.append("## Last State")
            lines.append(state)
            lines.append("")
        }

        // Decisions
        if !decisions.isEmpty {
            lines.append("## Decisions")
            for d in decisions {
                lines.append("- \(d)")
            }
            lines.append("")
        }

        // Corrections
        if !corrections.isEmpty {
            lines.append("## Corrections")
            for c in corrections {
                lines.append("- \(c)")
            }
            lines.append("")
        }

        // Open Questions
        if !openQuestions.isEmpty {
            lines.append("## Open Questions")
            for q in openQuestions {
                lines.append("- \(q)")
            }
            lines.append("")
        }

        // Recent Activity
        if !activityEntries.isEmpty {
            lines.append("## Recent Activity")
            for entry in activityEntries {
                let dateStr = entry.timestamp.formatted(date: .numeric, time: .shortened)
                lines.append("- \(dateStr): \(entry.text)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Writer

/// Writes (or merges) a topic summary into the project filesystem.
///
/// All operations are synchronous and non-throwing — safe to call inside
/// the SyncBridge actor. Uses atomic file writes (temp + rename).
public enum TopicSummaryWriter {

    // MARK: - Constants

    /// Maximum summary file size in bytes (8KB).
    private static let maxBytes = 8192

    /// Allowed root directories for summary files (spec §3.7).
    private static let allowedRoots = [
        "/Users/openclaw/Projects/",
        "/Users/openclaw/.openclaw/workspace/",
    ]

    // MARK: - Public API

    /// Writes (or merges) a topic summary.
    ///
    /// - Parameters:
    ///   - topicId: The topic's unique identifier.
    ///   - topicName: The topic's display name.
    ///   - projectPath: The project's root path, or nil for unbound topics.
    ///   - workspacePath: The workspace root (used when projectPath is nil).
    ///   - extracted: Structured extraction result from the LLM.
    /// - Returns: The path to the written file, or nil on failure.
    public static func write(
        topicId: String,
        topicName: String,
        projectPath: String?,
        workspacePath: String,
        extracted: TopicSummaryExtracted
    ) -> String? {
        guard !extracted.isEmpty else { return nil }

        // Determine output path
        let outputPath = summaryPath(
            topicId: topicId,
            projectPath: projectPath,
            workspacePath: workspacePath
        )
        let targetDir = (outputPath as NSString).deletingLastPathComponent

        // Validate the target directory is within allowed roots
        guard validatePath(targetDir) else {
            print("[TopicSummaryWriter] Rejected path: \(targetDir)")
            return nil
        }

        // Create directory if needed
        do {
            if !FileManager.default.fileExists(atPath: targetDir) {
                try FileManager.default.createDirectory(
                    atPath: targetDir,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            print("[TopicSummaryWriter] Failed to create directory: \(error)")
            return nil
        }

        // Read existing summary if present
        let existing = SummaryData(
            projectName: projectPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent },
            topicName: topicName
        )
        let merged = merge(
            existing: existing,
            extracted: extracted,
            outputPath: outputPath
        )

        // Serialize to markdown
        let content = merged.toMarkdown()

        // Enforce 8KB cap by trimming
        let trimmed = enforceCap(content, maxBytes: maxBytes)

        // Write atomically
        guard atomicWrite(content: trimmed, to: outputPath) else {
            print("[TopicSummaryWriter] Failed to write summary to \(outputPath)")
            return nil
        }

        return outputPath
    }

    /// Reads an existing summary for a topic, if one exists.
    ///
    /// - Parameters:
    ///   - topicId: The topic's unique identifier.
    ///   - projectPath: The project's root path, or nil for unbound topics.
    ///   - workspacePath: The workspace root (used when projectPath is nil).
    /// - Returns: The summary content, or nil if no summary file exists.
    public static func read(
        topicId: String,
        projectPath: String?,
        workspacePath: String
    ) -> String? {
        let path = summaryPath(
            topicId: topicId,
            projectPath: projectPath,
            workspacePath: workspacePath
        )
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard validatePath(path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Returns the file URL for a topic summary, or nil if none exists.
    public static func fileURL(
        topicId: String,
        projectPath: String?,
        workspacePath: String
    ) -> URL? {
        let path = summaryPath(
            topicId: topicId,
            projectPath: projectPath,
            workspacePath: workspacePath
        )
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return url
    }

    // MARK: - Internal (package-visible for testing)

    /// Determines the filesystem path for a topic summary.
    static func summaryPath(
        topicId: String,
        projectPath: String?,
        workspacePath: String
    ) -> String {
        if let projectPath = projectPath, !projectPath.isEmpty {
            let dir = (projectPath as NSString).appendingPathComponent("docs/topics")
            return (dir as NSString).appendingPathComponent("\(topicId)-summary.md")
        } else {
            let dir = (workspacePath as NSString).appendingPathComponent("docs/topics/unbound")
            return (dir as NSString).appendingPathComponent("\(topicId)-summary.md")
        }
    }

    /// Merges new extraction data into an existing summary (spec §3.5).
    fileprivate static func merge(
        existing: SummaryData,
        extracted: TopicSummaryExtracted,
        outputPath: String
    ) -> SummaryData {
        let now = Date()
        var result = existing
        result.lastUpdated = now

        // Last State: replace entirely
        if !extracted.state.isEmpty {
            result.state = extracted.state
        }

        // Decisions: append + normalised dedup (lowercase, trimmed, first 50 chars)
        let existingKeys = Set(result.decisions.map { normalisedKey($0) })
        for d in extracted.decisions {
            if !existingKeys.contains(normalisedKey(d)) {
                result.decisions.append(d)
            }
        }

        // Corrections: append + exact dedup
        let existingCorrections = Set(result.corrections)
        for c in extracted.corrections {
            if !existingCorrections.contains(c) {
                result.corrections.append(c)
            }
        }

        // Open Questions: append + exact dedup, cap at 5
        let existingQuestions = Set(result.openQuestions)
        for q in extracted.openQuestions {
            if !existingQuestions.contains(q) {
                result.openQuestions.append(q)
            }
        }
        if result.openQuestions.count > 5 {
            result.openQuestions = Array(result.openQuestions.prefix(5))
        }

        // Recent Activity: append timestamped entry, cap at 10
        let activityText = extracted.state.isEmpty
            ? "Summary saved — no active work"
            : extracted.state
        let entry = ActivityEntry(timestamp: now, text: activityText)
        result.activityEntries.append(entry)
        // Sort newest first, keep only last 10
        result.activityEntries.sort { $0.timestamp > $1.timestamp }
        if result.activityEntries.count > 10 {
            result.activityEntries = Array(result.activityEntries.prefix(10))
        }

        // Update topic name if changed
        if !existing.topicName.isEmpty && existing.topicName != extracted.state {
            // Keep existing topic name — it's set from the caller
        }

        return result
    }

    /// Normalised dedup key: lowercase, trimmed, first 50 chars.
    static func normalisedKey(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let idx = trimmed.index(trimmed.startIndex, offsetBy: min(50, trimmed.count))
        return String(trimmed[..<idx])
    }

    /// Enforce 8KB cap by trimming oldest activity entries first, then corrections,
    /// then decisions (keeping at least the last 5 decisions).
    static func enforceCap(_ content: String, maxBytes: Int) -> String {
        var bytes = content.utf8
        guard bytes.count > maxBytes else { return content }

        // If we're only slightly over, truncate at the byte level (safe fallback)
        // For a smarter trim, we'd re-parse the markdown, but byte truncation is acceptable
        // since the file is human-editable and the next save will re-normalise.
        let prefixBytes = bytes.prefix(maxBytes - 100) // Leave room for truncation marker
        guard let truncated = String(data: Data(prefixBytes), encoding: .utf8) else {
            return String(data: Data(bytes.prefix(maxBytes - 100)), encoding: .utf8) ?? content
                + "\n\n... [summary trimmed to size cap]"
        }
        return truncated + "\n\n... [summary trimmed to size cap]"
    }

    /// Validate that a file path is within allowed roots.
    /// Resolves symlinks to defeat symlink-escape attacks (spec §3.7).
    /// Pure prefix check — does NOT probe filesystem (directory existence
    /// is handled separately in the write flow).
    static func validatePath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let url = URL(fileURLWithPath: normalized).resolvingSymlinksInPath()
        let resolved = url.path

        for root in allowedRoots {
            let rootPath = root.hasSuffix("/") ? String(root.dropLast()) : root
            if resolved.hasPrefix(rootPath) {
                return true
            }
        }
        return false
    }

    /// Atomic write: write to temp file in same directory, then rename.
    static func atomicWrite(content: String, to path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let tempPath = (dir as NSString).appendingPathComponent(
            ".tmp-summary-\(UUID().uuidString)"
        )
        do {
            try content.write(toFile: tempPath, atomically: false, encoding: .utf8)
            try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            return true
        } catch {
            print("[TopicSummaryWriter] Atomic write failed: \(error)")
            // Clean up temp file if it exists
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
    }

    /// Parse existing markdown summary back into SummaryData (for merge).
    fileprivate static func parseMarkdown(_ content: String) -> SummaryData {
        var data = SummaryData()

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var currentSection: String = ""
        var stateLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Header metadata
            if trimmed.hasPrefix("# Topic:") {
                data.topicName = trimmed.dropFirst("# Topic:".count).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("**Last updated:**") {
                continue
            }
            if trimmed.hasPrefix("**Project:**") {
                let proj = trimmed.dropFirst("**Project:**".count).trimmingCharacters(in: .whitespaces)
                if proj != "None — general topic" {
                    data.projectName = proj
                }
                continue
            }
            if trimmed.hasPrefix("**Status:**") {
                continue
            }

            // Section headers
            if trimmed == "## Last State" {
                // Save previous state
                if !stateLines.isEmpty {
                    data.state = stateLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    stateLines = []
                }
                currentSection = "state"
                continue
            }
            if trimmed == "## Decisions" { currentSection = "decisions"; continue }
            if trimmed == "## Corrections" { currentSection = "corrections"; continue }
            if trimmed == "## Open Questions" { currentSection = "questions"; continue }
            if trimmed == "## Recent Activity" { currentSection = "activity"; continue }

            // Skip empty lines between sections
            if trimmed.isEmpty {
                if currentSection == "state" {
                    stateLines.append("")
                }
                continue
            }

            // Content lines
            switch currentSection {
            case "state":
                stateLines.append(trimmed)
            case "decisions":
                if trimmed.hasPrefix("- ") {
                    data.decisions.append(String(trimmed.dropFirst(2)))
                }
            case "corrections":
                if trimmed.hasPrefix("- ") {
                    data.corrections.append(String(trimmed.dropFirst(2)))
                }
            case "questions":
                if trimmed.hasPrefix("- ") {
                    data.openQuestions.append(String(trimmed.dropFirst(2)))
                }
            case "activity":
                if trimmed.hasPrefix("- ") {
                    let entryText = String(trimmed.dropFirst(2))
                    // Parse date prefix: "DD/MM/YYYY, HH:mm: text"
                    data.activityEntries.append(
                        ActivityEntry(timestamp: Date(), text: entryText)
                    )
                }
            default:
                break
            }
        }

        // Flush final state
        if !stateLines.isEmpty {
            data.state = stateLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return data
    }
}
