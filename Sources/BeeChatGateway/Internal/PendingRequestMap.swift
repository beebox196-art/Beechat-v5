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
    
    /// Remove a pending request by ID, rejecting it with the given reason.
    /// - Returns: `true` if the entry was found and its reject callback was
    ///   invoked (i.e., the continuation was resumed). Callers that need to
    ///   avoid double-resuming a `CheckedContinuation` MUST check this value.
    @discardableResult
    public func remove(id: String, reason: String) -> Bool {
        if let req = pending.removeValue(forKey: id) {
            req.timer.cancel()
            req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
            return true
        }
        return false
    }
    
    public func clearAll(reason: String) {
        for (id, req) in pending {
            req.timer.cancel()
            req.reject(NSError(domain: "PendingRequestMap", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
        pending.removeAll()
    }
}
