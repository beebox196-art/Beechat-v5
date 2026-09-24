import Foundation

/// The single file-logging policy used by BeeChat's exceptional diagnostic sinks.
public struct DiagnosticFileLogConfiguration: Sendable {
    public static let gateEnvironmentKey = "BEE_DEBUG_LOG"
    public static let maximumBytes = 1_048_576
    public static let retainedBytes = 262_144

    public let isEnabled: Bool
    public let homeDirectory: URL
    public let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isEnabled = environment[Self.gateEnvironmentKey] == "1"
    }

    public init(isEnabled: Bool, homeDirectory: URL, environment: [String: String] = [:]) {
        self.isEnabled = isEnabled
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    public func logURL(defaultFilename: String, overrideEnvironmentKey: String? = nil) -> URL {
        if let key = overrideEnvironmentKey,
           let override = environment[key],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(defaultFilename, isDirectory: false)
    }
}

/// A gated, one-file writer that trims in place and never creates generations.
public struct BoundedFileLog: Sendable {
    public let configuration: DiagnosticFileLogConfiguration
    public let url: URL
    public let maximumBytes: Int
    public let retainedBytes: Int

    public init(
        configuration: DiagnosticFileLogConfiguration,
        defaultFilename: String,
        overrideEnvironmentKey: String? = nil,
        maximumBytes: Int = DiagnosticFileLogConfiguration.maximumBytes,
        retainedBytes: Int = DiagnosticFileLogConfiguration.retainedBytes
    ) {
        precondition(maximumBytes > 0)
        precondition(retainedBytes >= 0 && retainedBytes <= maximumBytes)
        self.configuration = configuration
        self.url = configuration.logURL(
            defaultFilename: defaultFilename,
            overrideEnvironmentKey: overrideEnvironmentKey
        )
        self.maximumBytes = maximumBytes
        self.retainedBytes = retainedBytes
    }

    /// Writes only when the injected gate is enabled. The resulting file is at
    /// most `maximumBytes`, including when a single record exceeds the cap.
    public func write(_ data: Data, fileManager: FileManager = .default) throws {
        guard configuration.isEnabled else { return }

        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let existing = (try? Data(contentsOf: url)) ?? Data()
        var output: Data
        if existing.count + data.count > maximumBytes {
            output = Data(existing.suffix(retainedBytes))
            output.append(data)
            if output.count > maximumBytes {
                output = Data(output.suffix(maximumBytes))
            }
        } else {
            output = existing
            output.append(data)
        }

        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: output)
    }
}
