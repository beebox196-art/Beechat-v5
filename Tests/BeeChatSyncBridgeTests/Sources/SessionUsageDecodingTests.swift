import XCTest
@testable import BeeChatSyncBridge
@testable import BeeChatGateway

final class SessionUsageDecodingTests: XCTestCase {
    
    func testRealGatewayResponseShape() throws {
        let json = """
        {
            "updatedAt": 1776440726273,
            "startDate": "2026-04-27",
            "endDate": "2026-04-27",
            "sessions": [
                {
                    "key": "agent:main:telegram:group:-1003830552971:topic:1185",
                    "label": "General",
                    "sessionId": "abc123",
                    "updatedAt": 1776440726273,
                    "agentId": "main",
                    "channel": "telegram",
                    "chatType": "group",
                    "origin": null,
                    "modelOverride": null,
                    "providerOverride": null,
                    "modelProvider": null,
                    "model": null,
                    "usage": {
                        "sessionId": "abc123",
                        "sessionFile": "/path/to/file.jsonl",
                        "firstActivity": 1776440000000,
                        "lastActivity": 1776440726273,
                        "durationMs": 726273,
                        "activityDates": ["2026-04-27"],
                        "dailyBreakdown": [{"date": "2026-04-27", "tokens": 1500, "cost": 0.001}],
                        "dailyMessageCounts": [{"date": "2026-04-27", "total": 10, "user": 5, "assistant": 5, "toolCalls": 0, "toolResults": 0, "errors": 0}],
                        "messageCounts": {"total": 10, "user": 5, "assistant": 5, "toolCalls": 0, "toolResults": 0, "errors": 0},
                        "toolUsage": {"totalCalls": 0, "uniqueTools": 0, "tools": []},
                        "modelUsage": [],
                        "latency": {"count": 5, "avgMs": 1200, "p95Ms": 2000, "minMs": 500, "maxMs": 3000},
                        "input": 1000,
                        "output": 500,
                        "cacheRead": 0,
                        "cacheWrite": 0,
                        "totalTokens": 1500,
                        "totalCost": 0.001,
                        "inputCost": 0.0005,
                        "outputCost": 0.0005,
                        "cacheReadCost": 0,
                        "cacheWriteCost": 0,
                        "missingCostEntries": 0
                    },
                    "contextWeight": null
                }
            ],
            "totals": {
                "input": 1000,
                "output": 500,
                "cacheRead": 0,
                "cacheWrite": 0,
                "totalTokens": 1500,
                "totalCost": 0.001,
                "inputCost": 0.0005,
                "outputCost": 0.0005,
                "cacheReadCost": 0,
                "cacheWriteCost": 0,
                "missingCostEntries": 0
            },
            "aggregates": {}
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(SessionUsageResponse.self, from: json)
        XCTAssertEqual(response.sessions.count, 1)
        XCTAssertEqual(response.sessions.first?.key, "agent:main:telegram:group:-1003830552971:topic:1185")
        XCTAssertEqual(response.sessions.first?.usage?.totalTokens, 1500)
        XCTAssertEqual(response.totals?.totalTokens, 1500)
    }
    
    func testAnyCodableRoundTrip() throws {
        let json = """
        {
            "updatedAt": 1776440726273,
            "sessions": [
                {
                    "key": "agent:main:telegram:group:-1003830552971:topic:1185",
                    "usage": {
                        "totalTokens": 1500,
                        "input": 1000,
                        "output": 500,
                        "totalCost": 0.001
                    }
                }
            ],
            "totals": {
                "totalTokens": 1500,
                "totalCost": 0.001
            }
        }
        """.data(using: .utf8)!
        
        // Decode as AnyCodable first (simulating GatewayClient.call)
        let anyCodable = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        
        // Re-encode to JSON (simulating RPCClient.sessionsUsage)
        let reencoded = try JSONEncoder().encode(anyCodable)
        
        // Decode as SessionUsageResponse
        let response = try JSONDecoder().decode(SessionUsageResponse.self, from: reencoded)
        
        XCTAssertEqual(response.sessions.count, 1)
        XCTAssertEqual(response.sessions.first?.usage?.totalTokens, 1500)
        XCTAssertEqual(response.totals?.totalTokens, 1500)
    }
    
    func testAnyCodableWithNulls() throws {
        let json = """
        {
            "updatedAt": 1776440726273,
            "sessions": [
                {
                    "key": "agent:main:telegram:group:-1003830552971:topic:1185",
                    "label": null,
                    "usage": null
                }
            ],
            "totals": {
                "totalTokens": 0,
                "totalCost": 0
            }
        }
        """.data(using: .utf8)!
        
        let anyCodable = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let reencoded = try JSONEncoder().encode(anyCodable)
        let response = try JSONDecoder().decode(SessionUsageResponse.self, from: reencoded)
        
        XCTAssertEqual(response.sessions.count, 1)
        XCTAssertNil(response.sessions.first?.usage)
        XCTAssertEqual(response.totals?.totalTokens, 0)
    }
    
    func testUsageAboveThreshold() throws {
        let json = """
        {
            "sessions": [
                {
                    "key": "agent:main:telegram:group:-1003830552971:topic:1185",
                    "usage": {
                        "totalTokens": 120000
                    }
                }
            ],
            "totals": {
                "totalTokens": 120000
            }
        }
        """.data(using: .utf8)!
        
        let response = try JSONDecoder().decode(SessionUsageResponse.self, from: json)
        let contextWindow: Double = 200_000
        let totalTokens = response.sessions.first?.usage?.totalTokens ?? response.totals?.totalTokens ?? 0
        let usage = min(Double(totalTokens) / contextWindow, 1.0)
        
        XCTAssertEqual(usage, 0.6, accuracy: 0.001)
        XCTAssertTrue(usage >= 0.50)
    }
}
