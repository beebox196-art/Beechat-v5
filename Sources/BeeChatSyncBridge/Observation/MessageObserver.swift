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
                try Message
                    .filter(Column("sessionId") == sessionKey)
                    .order(Column("timestamp").asc)
                    .limit(500)
                    .fetchAll(db)
            }
            
            do {
                let writer = try dbManager.writer
                let cancellable = observation.start(
                    in: writer,
                    scheduling: .mainActor,
                    onError: { error in
                        print("Message observation error: \(error)")
                    },
                    onChange: { messages in
                        continuation.yield(messages)
                    }
                )
                
                continuation.onTermination = { _ in
                    cancellable.cancel()
                }
            } catch {
                print("Message observer failed to access DB writer: \(error)")
            }
        }
    }
}
