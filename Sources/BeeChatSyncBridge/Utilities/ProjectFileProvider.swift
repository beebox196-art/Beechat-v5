import Foundation

// MARK: - Result types

/// Result of a project context read operation (Mel Warning-5).
/// Structured metadata so UI and tests can distinguish capability states.
public struct ProjectContextReadResult {
    public var text: String
    public var files: [ProjectContextFileStatus]
    public var totalBytes: Int
    public var truncated: Bool
    public var unavailableReason: String?

    public struct ProjectContextFileStatus: Codable {
        public var filename: String
        public var status: FileStatus
        public var bytes: Int

        public enum FileStatus: String, Codable {
            case found, missing, truncated
        }

        public init(filename: String, status: FileStatus, bytes: Int) {
            self.filename = filename
            self.status = status
            self.bytes = bytes
        }
    }

    public init(
        text: String,
        files: [ProjectContextFileStatus],
        totalBytes: Int,
        truncated: Bool,
        unavailableReason: String? = nil
    ) {
        self.text = text
        self.files = files
        self.totalBytes = totalBytes
        self.truncated = truncated
        self.unavailableReason = unavailableReason
    }
}

// MARK: - Protocol

/// Protocol for platform-specific project file access.
/// Kieran Warning-1: replaces #if os(iOS) with injectable provider.
/// Mel Critical-1: enables structured capability reporting for iOS.
public protocol ProjectFileProvider {
    func readContextFiles(projectPath: String) -> ProjectContextReadResult
}

// MARK: - macOS implementation

/// Reads project files directly from the local filesystem.
public struct LocalProjectFileProvider: ProjectFileProvider {
    public init() {}

    public func readContextFiles(projectPath: String) -> ProjectContextReadResult {
        let text = ProjectContextReader.read(projectPath: projectPath)
        return ProjectContextReadResult(
            text: text,
            files: ProjectContextReader.getFileStatuses(projectPath: projectPath),
            totalBytes: text.utf8.count,
            truncated: text.contains("[truncated]"),
            unavailableReason: nil
        )
    }
}

// MARK: - iOS / stub implementation

/// Returns a degraded result indicating project files are unavailable on this device.
/// Mel Critical-1: iOS users see accurate capability status, not false confidence.
public struct StubProjectFileProvider: ProjectFileProvider {
    public init() {}

    public func readContextFiles(projectPath: String) -> ProjectContextReadResult {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return ProjectContextReadResult(
            text: "[Project: \(name) — project files accessible on Mac only; context unavailable on this device.]",
            files: [],
            totalBytes: 0,
            truncated: false,
            unavailableReason: "iOS device — project files accessible on Mac only"
        )
    }
}

// MARK: - File statuses extension for UI display

/// Utility: get per-file status for UI display (Mel Warning-4, Q impl note).
/// Called from EditTopicSheet — synchronous but only on user interaction,
/// never during observation/refresh paths (Mel Critical-2).
extension ProjectContextReader {
    public static func getFileStatuses(projectPath: String) -> [ProjectContextReadResult.ProjectContextFileStatus] {
        guard validatePath(projectPath) else { return [] }

        return contextFiles.map { (filename, _, maxBytes) in
            let filePath = (projectPath as NSString).appendingPathComponent(filename)
            guard let data = FileManager.default.contents(atPath: filePath) else {
                return ProjectContextReadResult.ProjectContextFileStatus(
                    filename: filename, status: .missing, bytes: 0)
            }
            let bytes = data.count
            let status: ProjectContextReadResult.ProjectContextFileStatus.FileStatus =
                bytes > maxBytes ? .truncated : .found
            return ProjectContextReadResult.ProjectContextFileStatus(
                filename: filename, status: status, bytes: bytes)
        }
    }
}
