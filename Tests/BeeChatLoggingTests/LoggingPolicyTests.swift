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
            for literal in Self.userSpecificAbsoluteLiterals(in: source) {
                if allowedAbsoluteLiterals[literal] != nil {
                    observedAllowlist[literal, default: 0] += 1
                } else {
                    violations.append("\(relative(file, to: root)): \(literal)")
                }
            }

            let relativePath = relative(file, to: root)
            if Self.isNonUITarget(relativePath) {
                let normalized = Self.joinAdjacentStringFragments(in: source)
                if normalized.contains(".desktopDirectory") {
                    violations.append("\(relativePath): .desktopDirectory")
                }
                for literal in Self.desktopLiterals(in: normalized)
                where literal != "/Users/openclaw/Desktop/Claude Oversight Reports" {
                    violations.append("\(relativePath): Desktop component in \(literal)")
                }
            }
        }

        XCTAssertEqual(observedAllowlist, allowedAbsoluteLiterals, "G1 allowlist size/content changed; review every literal")
        XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
    }

    func testG1FixturesRejectDefectAndAcceptValidator() {
        let defect = "let path = \"/Users/\" + \"alice/Desktop/secret.log\""
        let normalizedDefect = Self.joinAdjacentStringFragments(in: defect)
        XCTAssertFalse(Self.userSpecificAbsoluteLiterals(in: normalizedDefect).isEmpty)
        XCTAssertFalse(Self.desktopLiterals(in: normalizedDefect).isEmpty)

        let validator = "guard path.hasPrefix(\"/Users/\") else { return }"
        XCTAssertTrue(Self.userSpecificAbsoluteLiterals(in: validator).isEmpty)
        XCTAssertTrue(Self.desktopLiterals(in: validator).isEmpty)
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

    private static func isNonUITarget(_ path: String) -> Bool {
        ["Sources/BeeChatGateway/", "Sources/BeeChatPersistence/", "Sources/BeeChatSyncBridge/"]
            .contains { path.hasPrefix($0) }
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
