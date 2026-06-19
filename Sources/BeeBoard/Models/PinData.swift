import Foundation

public struct PinData: Codable, Equatable, Sendable {
    public var attachments: [PinAttachment]
    public var links: [PinLink]

    public init(
        attachments: [PinAttachment] = [],
        links: [PinLink] = []
    ) {
        self.attachments = attachments
        self.links = links
    }
}

public struct PinAttachment: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var fileName: String
    public var fileExtension: String?
    public var isImage: Bool
    public var relativePath: String  // relative to app's AttachmentStorage directory

    public init(
        id: String = UUID().uuidString,
        fileName: String,
        fileExtension: String? = nil,
        isImage: Bool,
        relativePath: String
    ) {
        self.id = id
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.isImage = isImage
        self.relativePath = relativePath
    }
}

public struct PinLink: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var url: String
    public var title: String?  // fetched page title, or nil if not yet fetched/failed

    public init(
        id: String = UUID().uuidString,
        url: String,
        title: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
    }
}
