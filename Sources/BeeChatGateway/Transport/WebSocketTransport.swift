import Foundation

public class WebSocketTransport: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    
    public override init() {
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }
    
    public func connect(url: URL) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        return task
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
}
