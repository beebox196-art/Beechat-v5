import Foundation

/// Ensures topic publishing is serialised per topic to prevent stale overwrites
/// during rapid CRUD operations (e.g. create → rapid rename).
///
/// Without this, concurrent Tasks could fire for create and rename, and the
/// slower create might finish after rename, overwriting with stale data.
/// Serialising per topic guarantees ordering: the rename always wins.
actor TopicPublishQueue {
    private var queues: [String: [() async -> Void]] = [:]
    private var running: [String: Bool] = [:]

    /// Enqueues a publish operation for the given session key.
    /// Operations for the same key are executed serially in FIFO order.
    func enqueue(sessionKey: String, operation: @escaping () async -> Void) {
        if queues[sessionKey] == nil { queues[sessionKey] = [] }
        queues[sessionKey]!.append(operation)
        if running[sessionKey] != true {
            running[sessionKey] = true
            Task { await drain(sessionKey: sessionKey) }
        }
    }

    private func drain(sessionKey: String) async {
        while let op = queues[sessionKey]?.first {
            queues[sessionKey]?.removeFirst()
            await op()
        }
        running[sessionKey] = false
    }
}
