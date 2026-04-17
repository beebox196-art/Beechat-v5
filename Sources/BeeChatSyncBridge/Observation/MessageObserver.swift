import Foundation
import GRDB
import BeeChatPersistence

public struct MessageObserver {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    public func observeMessages(sessionKey: String) -> AsyncStream<[Message]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Message.filter(Column("sessionId") == sessionKey).fetchAll(db)
            }
            
            let cancellable = observation.start(in: dbManager.writer) { error in
                print("Message observation error: \(error)")
            } onChange: { messages in
                continuation.yield(messages)
            }
            
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
}
