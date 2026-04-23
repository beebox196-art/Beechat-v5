import Foundation
import GRDB

public class BeeChatPersistenceStore {
    private let dbManager: DatabaseManager
    private let sessionRepo: SessionRepository
    private let messageRepo: MessageRepository
    private let attachmentRepo: AttachmentRepository
    
    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
        self.sessionRepo = SessionRepository(dbManager: dbManager)
        self.messageRepo = MessageRepository(dbManager: dbManager)
        self.attachmentRepo = AttachmentRepository(dbManager: dbManager)
    }
    
    public func openDatabase(at path: String) throws {
        try dbManager.openDatabase(at: path)
    }
    
    public func closeDatabase() {
        dbManager.closeDatabase()
    }
    
    
    public func saveSession(_ session: Session) throws {
        try sessionRepo.save(session)
    }
    
    public func fetchSessions(limit: Int, offset: Int) throws -> [Session] {
        try sessionRepo.fetchAll(limit: limit, offset: offset)
    }
    
    public func fetchSession(id: String) throws -> Session? {
        try sessionRepo.fetchById(id)
    }
    
    public func deleteSession(id: String) throws {
        try sessionRepo.delete(id)
    }
    
    public func deleteSessionCascading(id: String) throws {
        try sessionRepo.deleteCascading(id)
    }
    
    public func updateUnreadCount(sessionId: String, count: Int) throws {
        try sessionRepo.updateUnreadCount(id: sessionId, count: count)
    }
    
    public func upsertSessions(_ sessions: [Session]) throws {
        try sessionRepo.upsert(sessions)
    }
    
    
    private let topicRepo = TopicRepository()
    
    public func saveTopic(_ topic: Topic) throws {
        try topicRepo.save(topic)
    }
    
    public func fetchAllActiveTopics(limit: Int = 100) throws -> [Topic] {
        try topicRepo.fetchAllActive(limit: limit)
    }
    
    public func deleteTopicCascading(id: String) throws {
        try topicRepo.deleteCascading(id)
    }
    
    public func updateTopicSessionKey(topicId: String, sessionKey: String) throws {
        try topicRepo.updateSessionKey(topicId: topicId, sessionKey: sessionKey)
    }
    
    public func saveTopicBridge(topicId: String, sessionKey: String) throws {
        try topicRepo.saveBridge(topicId: topicId, sessionKey: sessionKey)
    }
    
    public func resolveSessionKeyForTopic(topicId: String) throws -> String? {
        try topicRepo.resolveSessionKey(topicId: topicId)
    }
    
    
    public func saveMessage(_ message: Message) throws {
        try messageRepo.save(message)
    }
    
    public func fetchMessages(sessionId: String, limit: Int, before: Date?) throws -> [Message] {
        try messageRepo.fetchBySession(sessionId: sessionId, limit: limit, before: before)
    }
    
    public func fetchMessage(id: String) throws -> Message? {
        try messageRepo.fetchById(id)
    }
    
    public func deleteMessage(id: String) throws {
        try messageRepo.delete(id)
    }
    
    public func markAsRead(messageIds: [String]) throws {
        try messageRepo.markAsRead(ids: messageIds)
    }
    
    public func upsertMessages(_ messages: [Message]) throws {
        try messageRepo.upsert(messages)
    }
    
    
    public func saveAttachment(_ attachment: Attachment) throws {
        try attachmentRepo.save(attachment)
    }
    
    public func fetchAttachments(messageId: String) throws -> [Attachment] {
        try attachmentRepo.fetchByMessage(messageId: messageId)
    }
    

}