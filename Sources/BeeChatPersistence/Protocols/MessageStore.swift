import Foundation
import GRDB

public protocol MessageStore {
    // Session operations
    func saveSession(_ session: Session) throws
    func fetchSessions(limit: Int, offset: Int) throws -> [Session]
    func fetchSession(id: String) throws -> Session?
    func deleteSession(id: String) throws
    func deleteSessionCascading(id: String) throws
    func updateUnreadCount(sessionId: String, count: Int) throws
    
    // Topic operations
    func saveTopic(_ topic: Topic) throws
    func fetchAllActiveTopics(limit: Int) throws -> [Topic]
    func deleteTopicCascading(id: String) throws
    func updateTopicSessionKey(topicId: String, sessionKey: String) throws
    func saveTopicBridge(topicId: String, sessionKey: String) throws
    func resolveSessionKeyForTopic(topicId: String) throws -> String?
    
    // Message operations
    func saveMessage(_ message: Message) throws
    func fetchMessages(sessionId: String, limit: Int, before: Date?) throws -> [Message]
    func fetchMessage(id: String) throws -> Message?
    func deleteMessage(id: String) throws
    func markAsRead(messageIds: [String]) throws
    
    // Attachment operations
    func saveAttachment(_ attachment: Attachment) throws
    func fetchAttachments(messageId: String) throws -> [Attachment]
    
    // Bulk operations
    func upsertSessions(_ sessions: [Session]) throws
    func upsertMessages(_ messages: [Message]) throws
    
    // Database lifecycle
    func openDatabase(at path: String) throws
    func closeDatabase()
}

public protocol GatewayEventConsumer {
    func handleSessionList(_ sessions: [Session]) throws
    func handleNewMessage(_ message: Message) throws
    func handleMessageUpdate(_ message: Message) throws
    func handleSessionUpdate(_ session: Session) throws
}