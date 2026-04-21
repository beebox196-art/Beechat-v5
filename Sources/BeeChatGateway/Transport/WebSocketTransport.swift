import Foundation

public class WebSocketTransport: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    
    // Callback for close events
    public var onClose: ((Int, String?) -> Void)?
    
    public override init() {
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }
    
    public func connect(url: URL, origin: String? = nil) {
        print("[GW-Transport] connect() called — url=\(url)")
        var request = URLRequest(url: url)
        if let origin = origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        print("[GW-Transport] WebSocket task resumed")
    }
    
    public func send(_ message: String) async throws {
        print("[GW-Transport] send() — \(message.prefix(200))")
        try await task?.send(.string(message))
        print("[GW-Transport] send() completed")
    }
    
    public func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[GW-Transport] close(code=\(code.rawValue), reason=\(reason != nil ? String(data: reason!, encoding: .utf8) ?? "binary" : "nil"))")
        task?.cancel(with: code, reason: reason)
    }
    
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let task = task else { throw NSError(domain: "WebSocketTransport", code: -1, userInfo: nil) }
        return try await task.receive()
    }
    
    public func disconnect() {
        print("[GW-Transport] disconnect() called — hasTask=\(task != nil)")
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let code = Int(closeCode.rawValue)
        let reasonString = reason != nil ? String(data: reason!, encoding: .utf8) : nil
        print("[GW-Transport] didCloseWith — code=\(code) reason=\(reasonString ?? "n/a")")
        onClose?(code, reasonString)
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[GW-Transport] didOpenWithProtocol — protocol=\(`protocol` ?? "nil")")
    }
}
