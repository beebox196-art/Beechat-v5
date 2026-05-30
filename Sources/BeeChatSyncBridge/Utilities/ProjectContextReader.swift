import Foundation

/// Reads project context files from a project directory.
/// Returns a formatted string suitable for injection into the context header.
///
/// All file reads are synchronous and non-throwing — safe to call inside
/// the SyncBridge actor. MUST NOT be called from the main actor or
/// SwiftUI observation paths (Mel Critical-2).
public enum ProjectContextReader {

    /// Allowed path prefix for security (Kieran Critical-1)
    private static let allowedPrefix = "/Users/openclaw/Projects/"

    /// Allowed file extensions for safety (Kieran Warning-4)
    private static let allowedExtensions = Set(["md", "txt", "json", "yaml", "yml", "toml"])

    /// Files to read, in order. Each entry: (filename, required, maxBytes)
    static let contextFiles: [(name: String, required: Bool, maxBytes: Int)] = [
        ("STATUS.md", true, 8192),
        ("README.md", false, 8192),
        ("decisions.md", false, 4096),
        ("corrections.md", false, 4096),
    ]

    // MARK: - Path validation

    /// Validate that projectPath is within the allowed directory and resolves cleanly.
    /// Uses URL.resolvingSymlinksInPath to defeat traversal attacks via
    /// intermediate directory symlinks (Kieran C1).
    static func validatePath(_ projectPath: String) -> Bool {
        let normalized = (projectPath as NSString).standardizingPath
        let url = URL(fileURLWithPath: normalized).resolvingSymlinksInPath()
        let resolved = url.path

        guard resolved.hasPrefix(allowedPrefix) else { return false }
        guard FileManager.default.fileExists(atPath: resolved) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return true
    }

    // MARK: - Read

    /// Read and format project context files.
    /// - Parameters:
    ///   - projectPath: Absolute path to the project directory.
    ///   - maxTotalBytes: Cap on total output size in UTF-8 bytes (default 16KB).
    /// - Returns: Formatted context string, or empty string if projectPath is nil/invalid.
    public static func read(projectPath: String, maxTotalBytes: Int = 16_384) -> String {
        // Kieran Critical-1: validate path before any file access
        guard validatePath(projectPath) else {
            print("[ProjectContextReader] Rejected path: \(projectPath)")
            return ""
        }

        var output: [String] = []
        var totalBytes = 0

        for (filename, required, maxBytes) in contextFiles {
            guard totalBytes < maxTotalBytes else { break }

            // Kieran Warning-4: extension check
            let ext = (filename as NSString).pathExtension
            guard allowedExtensions.contains(ext) else { continue }

            let filePath = (projectPath as NSString).appendingPathComponent(filename)
            guard let content = readFile(at: filePath, maxBytes: maxBytes) else {
                if required {
                    output.append("** \(filename) NOT FOUND **")
                }
                continue
            }

            // Kieran Critical-2: byte-based truncation, not character count
            let contentBytes = content.utf8
            let remainingBytes = maxTotalBytes - totalBytes
            let truncated: String
            if contentBytes.count > remainingBytes {
                let prefixBytes = contentBytes.prefix(remainingBytes)
                let decoded = String(data: Data(prefixBytes), encoding: .utf8) ?? ""
                truncated = decoded + "\n... [truncated to \(remainingBytes) bytes]"
            } else {
                truncated = content
            }

            output.append("--- \(filename) ---\n\(truncated)")
            totalBytes += truncated.utf8.count
        }

        if output.isEmpty { return "" }
        return output.joined(separator: "\n\n")
    }

    /// Read a single file with UTF-8 byte truncation.
    private static func readFile(at path: String, maxBytes: Int) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard var content = String(data: data, encoding: .utf8) else { return nil }

        // Kieran Critical-2: UTF-8 byte truncation
        let contentBytes = content.utf8
        if contentBytes.count > maxBytes {
            let prefixBytes = contentBytes.prefix(maxBytes)
            content = String(data: Data(prefixBytes), encoding: .utf8) ?? content
        }
        return content
    }
}
