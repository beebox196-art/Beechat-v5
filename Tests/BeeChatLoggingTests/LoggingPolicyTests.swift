import XCTest
@testable import BeeChatLogging

final class LoggingPolicyTests: XCTestCase {
    private let allowedAbsoluteLiterals: [String: Int] = [
        "/Users/openclaw/Desktop/Claude Oversight Reports": 1,
        "/Users/openclaw/Projects/": 6,
        "/Users/openclaw/.openclaw/workspace/": 4,
        "/Users/openclaw/Projects/_template/": 1,
        "/Users/openclaw/Projects/\\(name)/": 1,
    ]

    func testG1SourcePathPolicy() throws {
        let root = repositoryRoot
        let sources = try swiftSources(below: root.appendingPathComponent("Sources"))
        XCTAssertFalse(sources.isEmpty, "G1 must fail rather than scan zero files")

        let names = Set(sources.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("GatewayClient.swift"), "G1 scanned the wrong source tree")
        XCTAssertTrue(names.contains("Topic.swift"), "G1 scanned the wrong source tree")

        var observedAllowlist: [String: Int] = [:]
        var violations: [String] = []
        for file in sources {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relativePath = relative(file, to: root)
            let findings = Self.sourceFindings(in: source, relativePath: relativePath)
            for literal in findings.userSpecificAbsoluteLiterals {
                if allowedAbsoluteLiterals[literal] != nil {
                    observedAllowlist[literal, default: 0] += 1
                } else {
                    violations.append("\(findings.relativePath): \(literal)")
                }
            }

            if findings.usesDesktopDirectory {
                violations.append("\(findings.relativePath): .desktopDirectory")
            }
            for literal in findings.desktopLiterals
            where literal != "/Users/openclaw/Desktop/Claude Oversight Reports" {
                violations.append("\(findings.relativePath): Desktop component in \(literal)")
            }
        }

        XCTAssertEqual(observedAllowlist, allowedAbsoluteLiterals, "G1 allowlist size/content changed; review every literal")
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    func testG1FixturesRejectSplitAbsolutePathAndAppDesktopDefects() {
        let splitAbsolutePathDefect = "let path = \"/Users/\" + \"alice/Desktop/secret.log\""
        let splitFindings = Self.sourceFindings(
            in: splitAbsolutePathDefect,
            relativePath: "Sources/BeeChatGateway/Mutation.swift"
        )
        XCTAssertFalse(splitFindings.userSpecificAbsoluteLiterals.isEmpty)
        XCTAssertFalse(splitFindings.desktopLiterals.isEmpty)

        let appDesktopDefect =
            "let urls = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)"
        let appFindings = Self.sourceFindings(
            in: appDesktopDefect,
            relativePath: "Sources/App/Utils/BeeChatLogger.swift"
        )
        XCTAssertEqual(appFindings.relativePath, "Sources/App/Utils/BeeChatLogger.swift")
        XCTAssertTrue(appFindings.usesDesktopDirectory,
                      "App-target Desktop writes must be rejected just like non-UI-target writes")

        let validator = "guard path.hasPrefix(\"/Users/\") else { return }"
        let validatorFindings = Self.sourceFindings(
            in: validator,
            relativePath: "Sources/BeeChatGateway/Validator.swift"
        )
        XCTAssertTrue(validatorFindings.userSpecificAbsoluteLiterals.isEmpty)
        XCTAssertTrue(validatorFindings.desktopLiterals.isEmpty)
        XCTAssertFalse(validatorFindings.usesDesktopDirectory)
    }

    func testG2WriterBoundsOneFileAndUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beechat-log-g2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DiagnosticFileLogConfiguration(isEnabled: true, homeDirectory: directory)
        let writer = BoundedFileLog(
            configuration: configuration,
            defaultFilename: "bounded.log",
            maximumBytes: 1_024,
            retainedBytes: 256
        )

        for index in 0..<10 {
            try writer.write(Data("record-\(index)-\(String(repeating: "x", count: 390))\n".utf8))
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: writer.url.path)
        XCTAssertLessThanOrEqual(attributes[.size] as? Int ?? .max, 1_024)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
        let siblings = try FileManager.default.contentsOfDirectory(at: writer.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(siblings.filter { $0.lastPathComponent.hasPrefix("bounded.log") }.count, 1)
    }

    func testG3DefaultGateCreatesNoFileUnderInjectedHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("beechat-log-g3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let configuration = DiagnosticFileLogConfiguration(environment: [:], homeDirectory: home)
        XCTAssertFalse(configuration.isEnabled)
        let writer = BoundedFileLog(configuration: configuration, defaultFilename: "disabled.log")

        try writer.write(Data("must not exist".utf8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Logs").path))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSources(below directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func relative(_ file: URL, to root: URL) -> String {
        String(file.path.dropFirst(root.path.count + 1))
    }

    private struct SourceFindings {
        let relativePath: String
        let userSpecificAbsoluteLiterals: [String]
        let desktopLiterals: [String]
        let usesDesktopDirectory: Bool
    }

    private static func sourceFindings(in source: String, relativePath: String) -> SourceFindings {
        let normalized = joinAdjacentStringFragments(in: source)
        return SourceFindings(
            relativePath: relativePath,
            userSpecificAbsoluteLiterals: userSpecificAbsoluteLiterals(in: normalized),
            desktopLiterals: desktopLiterals(in: normalized),
            usesDesktopDirectory: normalized.contains(".desktopDirectory")
        )
    }

    private static func joinAdjacentStringFragments(in source: String) -> String {
        source.replacingOccurrences(
            of: #"\"\s*\+\s*\""#,
            with: "",
            options: .regularExpression
        )
    }

    private static func userSpecificAbsoluteLiterals(in source: String) -> [String] {
        matches(pattern: #"\"(/Users/[^/\"\\]+/[^\"\n]*)\""#, in: source) +
            matches(pattern: #"'(/Users/[^/'\\]+/[^'\n]*)'"#, in: source)
    }

    private static func desktopLiterals(in source: String) -> [String] {
        matches(pattern: #"\"([^\"\n]*(?:^|/)Desktop(?:/|$)[^\"\n]*)\""#, in: source) +
            matches(pattern: #"'([^'\n]*(?:^|/)Desktop(?:/|$)[^'\n]*)'"#, in: source)
    }

    private static func matches(pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }
}
