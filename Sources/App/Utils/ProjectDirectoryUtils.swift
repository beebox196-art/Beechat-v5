import Foundation

/// Utilities for project directory discovery and management.
public enum ProjectDirectoryUtils {

    /// List all project directories under the given base path.
    /// - Parameters:
    ///   - path: The base directory to scan (default: `/Users/openclaw/Projects/`)
    /// - Returns: Sorted array of directory names (not full paths)
    public static func listProjectDirectories(at path: String = "/Users/openclaw/Projects/") -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }

        do {
            let contents = try fm.contentsOfDirectory(atPath: path)
            let dirs = contents.filter { name in
                // Exclude dot-prefixed
                guard !name.hasPrefix(".") else { return false }
                // Exclude _template
                guard name != "_template" else { return false }
                // Must be a directory
                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { return false }
                return true
            }
            return dirs.sorted()
        } catch {
            print("[ProjectDirectoryUtils] Failed to list projects at \(path): \(error)")
            return []
        }
    }

    /// Build full paths from directory names for a given base path.
    public static func fullPaths(for names: [String], basePath: String = "/Users/openclaw/Projects/") -> [String] {
        names.map { (basePath as NSString).appendingPathComponent($0) + "/" }
    }
}
