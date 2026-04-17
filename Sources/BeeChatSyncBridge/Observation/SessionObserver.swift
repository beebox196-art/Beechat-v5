import Foundation
import GRDB
import BeeChatPersistence

public struct SessionObserver {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    public func observeSessions() -> AsyncStream<[Session]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Session.fetchAll(db)
            }
            
            do {
                let writer = try dbManager.writer
                let cancellable = observation.start(in: writer) { error in
                    print("Session observation error: \(error)")
                } onChange: { sessions in
                    continuation.yield(sessions)
                }
                
                continuation.onTermination = { _ in
                    cancellable.cancel()
                }
            } catch {
                print("Session observer failed to access DB writer: \(error)")
            }
        }
    }
}
