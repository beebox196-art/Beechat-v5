import Foundation

/// Simple file-based logger for BeeChat diagnostics.
/// Writes to ~/Desktop/BeeChat-diagnostics.log so Adam can use the app normally
/// and Bee can read the log file remotely.
///
/// All writes happen on a background serial queue to prevent blocking the main thread.
/// If the file is iCloud-evicted or otherwise slow to materialize, the app stays responsive.
enum BeeChatLogger {
    private static let logURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("BeeChat-diagnostics.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Serial background queue for log writes — prevents main-thread blocking
    /// and serialises concurrent writes safely.
    private static let writeQueue = DispatchQueue(label: "com.beebox.beechat.logger", qos: .utility)

    /// Maximum log file size before rotation (1 MB).
    /// When exceeded, the file is truncated to the last 256 KB.
    private static let maxLogBytes: Int = 1_048_576
    private static let truncateToBytes: Int = 262_144

    static func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        writeQueue.async {
            Self.writeSynchronously(data)
        }
    }

    /// Internal synchronous write, called only on writeQueue.
    private static func writeSynchronously(_ data: Data) {
        let path = logURL.path

        if FileManager.default.fileExists(atPath: path) {
            // Rotate if file is too large
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let fileSize = attrs[.size] as? Int, fileSize > maxLogBytes {
                Self.rotateLog(at: path)
            }

            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                return
            }
            // If FileHandle fails (e.g. iCloud-evicted file), delete and recreate
            try? FileManager.default.removeItem(at: logURL)
        }

        // Create new file
        try? data.write(to: logURL)
    }

    /// Truncates the log file, keeping only the last `truncateToBytes` of content.
    private static func rotateLog(at path: String) {
        guard let data = try? Data(contentsOf: logURL) else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let trimmed = data.suffix(truncateToBytes)
        try? FileManager.default.removeItem(atPath: path)
        try? trimmed.write(to: logURL)
    }
}