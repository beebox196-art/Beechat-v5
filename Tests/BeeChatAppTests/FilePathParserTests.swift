import XCTest
@testable import BeeChatApp

final class FilePathParserTests: XCTestCase {

    // MARK: - Backtick patterns (priority)

    func testBacktickAbsolutePath() {
        let input = "See `/Users/openclaw/Desktop/report.md` for details."
        let segments = FilePathParser.parse(input)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text("See "))
        XCTAssertEqual(segments[1], .link(path: "/Users/openclaw/Desktop/report.md", displayText: "/Users/openclaw/Desktop/report.md"))
        XCTAssertEqual(segments[2], .text(" for details."))
    }

    func testBacktickHomeRelativePath() {
        let input = "Check `~/.zshrc` for aliases."
        let segments = FilePathParser.parse(input)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text("Check "))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(segments[1], .link(path: home + "/.zshrc", displayText: "~/.zshrc"))
        XCTAssertEqual(segments[2], .text(" for aliases."))
    }

    func testBacktickPatternConsumesRange_preventsBareOverlap() {
        let input = "`/Users/openclaw/Desktop/report.md` and /Users/openclaw/other.txt"
        let segments = FilePathParser.parse(input)

        // Backtick path is consumed first; bare pattern should still match the second path.
        XCTAssertTrue(segments.contains(where: {
            if case .link(_, let display) = $0, display == "/Users/openclaw/Desktop/report.md" { return true }
            return false
        }))
        XCTAssertTrue(segments.contains(where: {
            if case .link(_, let display) = $0, display == "/Users/openclaw/other.txt" { return true }
            return false
        }))
    }

    // MARK: - Bare absolute paths

    func testBareAbsolutePath() {
        let input = "Your file is at /Users/openclaw/Projects/BeeChat-v5/README.md"
        let segments = FilePathParser.parse(input)

        XCTAssertTrue(segments.contains(where: {
            if case .link(_, let display) = $0, display == "/Users/openclaw/Projects/BeeChat-v5/README.md" { return true }
            return false
        }))
    }

    func testTrailingPunctuationStripped() {
        // Regex excludes trailing punctuation, so these should match cleanly.
        let inputs = [
            "See /Users/openclaw/file.md.",
            "See /Users/openclaw/file.md,",
            "See /Users/openclaw/file.md)",
            "See /Users/openclaw/file.md]",
            "See /Users/openclaw/file.md:",
            "See /Users/openclaw/file.md;",
        ]
        for input in inputs {
            let segments = FilePathParser.parse(input)
            XCTAssertTrue(
                segments.contains(where: {
                    if case .link(_, let display) = $0, display == "/Users/openclaw/file.md" { return true }
                    return false
                }),
                "Failed to strip trailing punctuation for: \(input)"
            )
        }
    }

    // MARK: - Home-relative paths

    func testHomeRelativePath() {
        let input = "Config is at ~/.config/app/settings.json"
        let segments = FilePathParser.parse(input)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(segments.contains(where: {
            if case .link(let path, let display) = $0,
               path == home + "/.config/app/settings.json",
               display == "~/.config/app/settings.json" { return true }
            return false
        }))
    }

    // MARK: - file:// URLs

    func testFileURL() {
        let input = "Open file:///Users/openclaw/Desktop/report.pdf"
        let segments = FilePathParser.parse(input)

        XCTAssertTrue(segments.contains(where: {
            if case .link(_, let display) = $0, display == "/Users/openclaw/Desktop/report.pdf" { return true }
            return false
        }))
    }

    // MARK: - Exclusions

    func testExcludesHTTPS() {
        let input = "Visit https://example.com/page and /Users/openclaw/file.txt"
        let segments = FilePathParser.parse(input)

        XCTAssertFalse(segments.contains(where: {
            if case .link(_, let display) = $0, display.contains("https://") { return true }
            return false
        }))
        XCTAssertTrue(segments.contains(where: {
            if case .link(_, let display) = $0, display == "/Users/openclaw/file.txt" { return true }
            return false
        }))
    }

    func testExcludesRelativePaths() {
        let input = "Use ./setup.sh and ../config.json"
        let segments = FilePathParser.parse(input)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], .text(input))
    }

    func testExcludesSystemPaths() {
        let input = "Look in /usr/bin/bash and /System/Library/Fonts"
        let segments = FilePathParser.parse(input)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], .text(input))
    }

    // MARK: - Tilde resolution

    func testTildeOnlyLeadingTildeResolved() {
        // A path with ~ only at the start should resolve; later ~ should not be touched.
        // (In practice this is an unusual path, but we guard against it.)
        let input = "Path: ~/Projects/test"
        let segments = FilePathParser.parse(input)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(segments.contains(where: {
            if case .link(let path, let display) = $0,
               path == home + "/Projects/test",
               display == "~/Projects/test" { return true }
            return false
        }))
    }

    // MARK: - Path traversal guard

    func testTraversalGuardRejectsOutsideUsers() {
        // Simulate a match that somehow resolves outside /Users/ (e.g. via symlink or exploit).
        // Since our regex only matches /Users/ and ~/, this is defence-in-depth.
        // We test by checking that a crafted input with traversal characters is handled.
        let input = "File: /Users/openclaw/../../etc/passwd"
        let segments = FilePathParser.parse(input)

        // The regex will match /Users/openclaw/../../etc/passwd, but standardizingPath
        // will resolve it to /etc/passwd, which fails the guard.
        // It should render as plain text.
        let linkSegments = segments.filter {
            if case .link = $0 { return true }
            return false
        }
        XCTAssertTrue(linkSegments.isEmpty, "Traversal guard should reject resolved path outside /Users/")
    }

    // MARK: - Edge cases

    func testMultiplePathsInOneMessage() {
        let input = "Files: /Users/a/1.txt and ~/2.txt and `~/3.txt`"
        let segments = FilePathParser.parse(input)

        let links = segments.filter {
            if case .link = $0 { return true }
            return false
        }
        XCTAssertEqual(links.count, 3, "Should match three distinct paths")
    }

    func testPlainTextNoPaths() {
        let input = "Hello world, no files here."
        let segments = FilePathParser.parse(input)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0], .text(input))
    }
}
