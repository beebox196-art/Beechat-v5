import Foundation

// MARK: - Gateway RPC response types

/// Response from `sessions.list` RPC call.
struct SessionsListResponse: Codable {
    let sessions: [SessionInfo]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([SessionInfo].self, forKey: .sessions)
    }
    
    enum CodingKeys: String, CodingKey { case sessions }
}

/// Response from `chat.history` RPC call.
struct ChatHistoryResponse: Codable {
    let messages: [ChatHistoryMessage]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decode([ChatHistoryMessage].self, forKey: .messages)
    }
    
    enum CodingKeys: String, CodingKey { case messages }
}

/// A single message in the chat.history response.
struct ChatHistoryMessage: Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: TimeInterval
    let runId: String?
}

/// Response from `chat.send` RPC call.
struct ChatSendResponse: Codable {
    let runId: String
}

/// Response from `sessions.usage` RPC call.
struct SessionUsageResponse: Codable {
    let sessions: [SessionUsageEntry]
    let totals: UsageTotals?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([SessionUsageEntry].self, forKey: .sessions)
        totals = try container.decodeIfPresent(UsageTotals.self, forKey: .totals)
    }
    
    enum CodingKeys: String, CodingKey { case sessions, totals }
}

struct SessionUsageEntry: Codable {
    let key: String?
    let usage: SessionUsageDetail?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        usage = try container.decodeIfPresent(SessionUsageDetail.self, forKey: .usage)
    }
    
    enum CodingKeys: String, CodingKey { case key, usage }
}

struct SessionUsageDetail: Codable {
    let totalTokens: Int?
    let input: Int?
    let output: Int?
    let totalCost: Double?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        input = try container.decodeIfPresent(Int.self, forKey: .input)
        output = try container.decodeIfPresent(Int.self, forKey: .output)
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
    }
    
    enum CodingKeys: String, CodingKey { case totalTokens, input, output, totalCost }
}

struct UsageTotals: Codable {
    let totalTokens: Int?
    let totalCost: Double?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
    }
    
    enum CodingKeys: String, CodingKey { case totalTokens, totalCost }
}

/// Response from `sessions.reset` RPC call.
struct SessionResetResponse: Codable {
    let ok: Bool
}
