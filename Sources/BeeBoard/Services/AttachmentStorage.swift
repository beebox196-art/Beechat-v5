import Foundation

public enum AttachmentStorage {
    public static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BeeChat/BeeBoard/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy a file from source URL into attachment storage. Returns the relative path.
    public static func copy(from sourceURL: URL) throws -> String {
        let fileName = sourceURL.lastPathComponent
        let uniqueName = "\(String(UUID().uuidString.prefix(8)))-\(fileName)"
        let destination = storageDirectory.appendingPathComponent(uniqueName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return uniqueName
    }

    /// Full URL for a relative path
    public static func url(for relativePath: String) -> URL {
        storageDirectory.appendingPathComponent(relativePath)
    }

    /// Delete a file by relative path
    public static func remove(relativePath: String) {
        let url = url(for: relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
