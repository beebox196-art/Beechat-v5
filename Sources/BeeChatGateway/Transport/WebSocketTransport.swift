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
        var request = URLRequest(url: url)
        if let origin = origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }
    
    public func send(_ message: String) async throws {
        try await task?.send(.string(message))
    }
    
    public func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task?.cancel(with: code, reason: reason)
    }
    
    public func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let task = task else { throw NSError(domain: "WebSocketTransport", code: -1, userInfo: nil) }
        return try await task.receive()
    }
    
    public func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(Int(closeCode.rawValue), reason.flatMap { String(data: $0, encoding: .utf8) })
    }
}
