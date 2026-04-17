import Foundation

public actor PendingRequestMap: Sendable {
    private struct PendingRequest {
        let resolve: ([String: AnyCodable]) -> Void
        let reject: (Error) -> Void
        let timer: DispatchSourceTimer
    }
    
    private var pending: [String: PendingRequest] = [:]
    
    public func add(id: String, timeout: TimeInterval, resolve: @escaping ([String: AnyCodable]) -> Void, reject: @escaping (Error) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            Task { await self.remove(id: id, reason: "Request timed out after \(timeout)s") }
        }
        timer.resume()
        
        pending[id] = PendingRequest(resolve: resolve, reject: reject, timer: timer)
    }
    
    public func resolve(id: String, payload: [String: AnyCodable]) {
        if let req = pending.removeValue(forKey: id) {
            req.timer.cancel()
            req.resolve(payload)
        }
    }
    
    public func reject(id: String, error: Error) {
        if let req = pending.removeValue(forKey: id) {
            req.timer.cancel()
            req.reject(error)
        }
    }
    
    public func remove(id: String, reason: String) {
        if let req = pending.removeValue(forKey: id) {
            req.timer.cancel()
            req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }
    
    public func clearAll(reason: String) {
        for (id, req) in pending {
            req.timer.cancel()
            req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
        pending.removeAll()
    }
}
