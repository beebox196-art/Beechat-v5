import SwiftUI

// MARK: - File Existence Cache

struct FileExistenceCache {
    private var entries: [String: (result: Bool, timestamp: Date)] = [:]
    private let ttl: TimeInterval = 30

    mutating func check(_ path: String) -> Bool {
        let now = Date()
        if let entry = entries[path], now.timeIntervalSince(entry.timestamp) < ttl {
            return entry.result
        }
        let result = FileManager.default.fileExists(atPath: path)
        entries[path] = (result, now)
        return result
    }

    mutating func invalidate() {
        entries.removeAll()
    }
}

// MARK: - Content Segment

enum ContentSegment: Equatable {
    case text(String)
    case link(path: String, displayText: String)
}

// MARK: - Path Parser

struct FilePathParser {

    /// Patterns are applied in order; backtick patterns run first and mark their
    /// matched ranges as consumed so bare patterns cannot overlap them.
    static let patterns: [(regex: NSRegularExpression, isBacktick: Bool)] = {
        let strings: [(String, Bool)] = [
            (#"`(/Users/[^`\s]+)`"#, true),      // backtick absolute
            (#"`(~/[^`\s]+)`"#, true),           // backtick home-relative
            (#"file://(/[^\s]+)"#, false),       // file:// captures path after protocol
            (#"/Users/[^\s]+"#, false),           // bare absolute
            (#"~/[^\s]+"#, false),                // bare home-relative
        ]
        return strings.compactMap { (pattern, isBacktick) in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            return (regex, isBacktick)
        }
    }()

    /// Parse message content into segments.
    static func parse(_ content: String) -> [ContentSegment] {
        let fullRange = NSRange(content.startIndex..., in: content)
        var consumedRanges: [NSRange] = []

        // Gather all matches with their pattern index to preserve priority.
        var allMatches: [(range: NSRange, path: String, isBacktick: Bool)] = []

        for (regex, isBacktick) in patterns {
            let matches = regex.matches(in: content, options: [], range: fullRange)
            for match in matches {
                let matchRange = match.range
                // Skip if already consumed by a higher-priority match.
                if consumedRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) {
                    continue
                }

                let path: String
                if isBacktick {
                    // Group 1 is the path inside the backticks.
                    let groupRange = match.range(at: 1)
                    guard groupRange.location != NSNotFound,
                          let swiftRange = Range(groupRange, in: content) else { continue }
                    path = String(content[swiftRange])
                } else if match.numberOfRanges > 1 {
                    // file:// pattern captures path in group 1.
                    let groupRange = match.range(at: 1)
                    guard groupRange.location != NSNotFound,
                          let swiftRange = Range(groupRange, in: content) else { continue }
                    path = String(content[swiftRange])
                } else {
                    guard let swiftRange = Range(matchRange, in: content) else { continue }
                    path = String(content[swiftRange])
                }

                consumedRanges.append(matchRange)
                allMatches.append((matchRange, path, isBacktick))
            }
        }

        // Sort by location to process left-to-right.
        allMatches.sort { $0.range.location < $1.range.location }

        var segments: [ContentSegment] = []
        var currentIndex = content.startIndex

        for (nsRange, rawPath, isBacktick) in allMatches {
            guard let range = Range(nsRange, in: content) else { continue }

            // Add plain text before this match.
            if currentIndex < range.lowerBound {
                let prefix = String(content[currentIndex..<range.lowerBound])
                if !prefix.isEmpty {
                    segments.append(.text(prefix))
                }
            }

            // Resolve tilde, strip trailing punctuation, and validate path.
            let stripped = stripTrailingPunctuation(rawPath)
            let resolved = resolvePath(stripped)
            let standardised = (resolved as NSString).standardizingPath

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let usersPrefix = "/Users/"
            guard standardised.hasPrefix(usersPrefix) || standardised.hasPrefix(home) else {
                // Traversal guard failed — render matched text as plain text.
                segments.append(.text(String(content[range])))
                currentIndex = range.upperBound
                continue
            }

            let displayText = isBacktick ? rawPath : rawPath
            segments.append(.link(path: standardised, displayText: displayText))

            currentIndex = range.upperBound
        }

        // Append remaining plain text.
        if currentIndex < content.endIndex {
            let suffix = String(content[currentIndex...])
            if !suffix.isEmpty {
                segments.append(.text(suffix))
            }
        }

        return segments
    }

    private static func stripTrailingPunctuation(_ path: String) -> String {
        let punctuation: [Character] = [".", ",", ")", "]", ":", ";"]
        var result = path
        while let last = result.last, punctuation.contains(last) {
            result.removeLast()
        }
        return result
    }

    /// Resolve only a leading tilde to the user's home directory.
    private static func resolvePath(_ path: String) -> String {
        if path.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + path.dropFirst()
        }
        return path
    }
}

// MARK: - File Link Text View

struct FileLinkText: View {
    let content: String
    @Environment(ThemeManager.self) var themeManager

    @State private var cache = FileExistenceCache()

    var body: some View {
        Text(attributedString())
            .font(themeManager.font(.body))
            .textSelection(.enabled)
            .onDisappear {
                cache.invalidate()
            }
    }

    private func attributedString() -> AttributedString {
        let segments = FilePathParser.parse(content)
        var result = AttributedString("")
        for segment in segments {
            switch segment {
            case .text(let str):
                result.append(AttributedString(str))
            case .link(let path, let display):
                let exists = cache.check(path)
                var linkAttr = AttributedString(display)
                if exists {
                    linkAttr.foregroundColor = themeManager.color(.accentPrimary)
                    linkAttr.underlineStyle = .single
                    linkAttr.link = URL(fileURLWithPath: path)
                } else {
                    linkAttr.foregroundColor = themeManager.color(.textSecondary)
                }
                result.append(linkAttr)
            }
        }
        return result
    }
}
