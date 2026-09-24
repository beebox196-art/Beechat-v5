import Foundation
import os
import BeeChatLogging

/// Simple file-based logger for BeeChat diagnostics.
/// Mirrors privacy-redacted events to unified logging. When BEE_DEBUG_LOG=1,
/// also writes to the bounded ~/Library/Logs/BeeChat-diagnostics.log file.
///
/// All writes happen on a background serial queue to prevent blocking the main thread.
/// If the file is iCloud-evicted or otherwise slow to materialize, the app stays responsive.
enum BeeChatLogger {
    private static let fileLog = BoundedFileLog(
        configuration: DiagnosticFileLogConfiguration(),
        defaultFilename: "BeeChat-diagnostics.log"
    )

    private static let unifiedLogger = Logger(
        subsystem: "com.beebox.beechat",
        category: "diagnostics"
    )

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Serial background queue for log writes — prevents main-thread blocking
    /// and serialises concurrent writes safely.
    private static let writeQueue = DispatchQueue(label: "com.beebox.beechat.logger", qos: .utility)

    static func log(_ message: String) {
        let message = sanitized(message)
        unifiedLogger.debug("\(message, privacy: .private)")

        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        writeQueue.async {
            try? fileLog.write(data)
        }
    }

    /// Removes the one legacy message-content field without touching its callers.
    private static func sanitized(_ message: String) -> String {
        for marker in [", text=", " text="] {
            if let range = message.range(of: marker) {
                return String(message[..<range.lowerBound]) + marker + "<redacted>"
            }
        }
        return message
    }
}
