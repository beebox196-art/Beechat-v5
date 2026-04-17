import Foundation
import GRDB

public struct MessageBlock: Codable {
    public enum BlockType: String, Codable {
        case text
        case image
        case file
        case audio
        case video
        case system
    }
    
    public var type: BlockType
    public var content: String
    public var metadata: [String: String]?
    
    public init(type: BlockType, content: String, metadata: [String: String]? = nil) {
        self.type = type
        self.content = content
        self.metadata = metadata
    }
}
