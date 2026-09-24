import Foundation
import os
import BeeChatLogging

struct GatewayDiagnosticSinks: @unchecked Sendable {
    let file: @Sendable (Data) -> Void
    let print: @Sendable (String) -> Void
    let unifiedLog: @Sendable (String) -> Void

    static func live(
        configuration: DiagnosticFileLogConfiguration = .init()
    ) -> GatewayDiagnosticSinks {
        let fileLog = BoundedFileLog(
            configuration: configuration,
            defaultFilename: "BeeChat-debug.log",
            overrideEnvironmentKey: "BEE_DEBUG_LOG_PATH"
        )
        let logger = Logger(subsystem: "com.beebox.beechat", category: "gateway")
        return GatewayDiagnosticSinks(
            file: { data in try? fileLog.write(data) },
            print: { message in Swift.print(message) },
            unifiedLog: { message in logger.debug("\(message, privacy: .private)") }
        )
    }
}

protocol GatewayTransport: AnyObject {
    var onClose: ((Int, String?) -> Void)? { get set }
    func connect(url: URL, origin: String?)
    func send(_ message: String) async throws
    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func disconnect()
}

extension WebSocketTransport: GatewayTransport {}
