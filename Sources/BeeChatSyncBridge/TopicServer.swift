import Foundation
import Network
import BeeChatPersistence

/// HTTP server that serves topic data from GRDB.
/// Proxied via Tailscale Serve for external access by the iPhone app.
///
/// Listens on localhost:8976 (localhost-only — Tailscale Serve handles external proxying).
/// Single endpoint: GET /v1/topics — returns JSON matching `TopicSyncPayload` format.
final class TopicServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "TopicServer", qos: .userInitiated)

    /// Server base URL
    static let url = "http://127.0.0.1:8976"
    static let topicsPath = "/v1/topics"

    // MARK: - Lifecycle

    /// Start the HTTP server on localhost:8976.
    /// Logs and continues without crashing if the port is occupied.
    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: 8976))
            nwListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            self.listener = nwListener
            nwListener.start(queue: queue)

            print("[TopicServer] Serving topics at http://127.0.0.1:8976/v1/topics (proxied via Tailscale Serve)")
        } catch {
            print("[TopicServer] Failed to create listener: \(error). Topic server unavailable — iPhone will use standalone mode.")
        }
    }

    /// Stop the HTTP server.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - State Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[TopicServer] Listener ready on port 8976")
        case .failed(let error):
            print("[TopicServer] Listener failed: \(error). Topic server unavailable — iPhone will use standalone mode.")
            listener = nil
        case .cancelled:
            print("[TopicServer] Listener cancelled")
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveRequest(connection)
            case .failed(let error):
                print("[TopicServer] Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[TopicServer] Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                self.sendResponse(connection: connection, statusCode: 400, body: "Bad request".data(using: .utf8)!)
                return
            }

            let path = self.extractPath(from: request)
            if path == Self.topicsPath {
                self.handleTopicsRequest(connection)
            } else {
                self.sendResponse(connection: connection, statusCode: 404, body: "Not found".data(using: .utf8)!)
            }

            if isComplete {
                connection.cancel()
            }
        }
    }

    private func extractPath(from request: String) -> String {
        // Parse the request line: "GET /v1/topics HTTP/1.1"
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return "" }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    // MARK: - Topic Request

    private func handleTopicsRequest(_ connection: NWConnection) {
        let repository = TopicRepository()

        // Perform GRDB read on the background queue to avoid blocking the connection handler
        queue.async { [weak self] in
            guard let self = self else { return }

            do {
                let topics = try repository.fetchAllActive(limit: 50)

                // Filter to only topics with a sessionKey (syncable)
                let syncableTopics = topics.filter { $0.sessionKey != nil && !$0.sessionKey!.isEmpty }

                let topicItems = syncableTopics.map { topic in
                    TopicPayloadItem(
                        id: topic.id,
                        name: topic.name,
                        sessionKey: topic.sessionKey ?? "",
                        isArchived: topic.isArchived,
                        // Use updatedAt instead of lastActivityAt — lastActivityAt is not reliably
                        // refreshed when new messages arrive. updatedAt is refreshed by
                        // syncMetadataFromSessions() so it reflects the true last activity time.
                        lastActivityAt: Self.dateFormatter.string(from: topic.updatedAt),
                        lastMessagePreview: topic.lastMessagePreview
                    )
                }

                let payload = ServerTopicPayload(
                    v: 1,
                    timestamp: Self.dateFormatter.string(from: Date()),
                    topics: topicItems
                )

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let jsonData = try encoder.encode(payload)
                self.sendResponse(connection: connection, statusCode: 200, body: jsonData)
            } catch {
                print("[TopicServer] GRDB read error: \(error)")
                self.sendResponse(connection: connection, statusCode: 503, body: "Service Unavailable".data(using: .utf8)!)
            }
        }
    }

    // MARK: - Response

    private func sendResponse(connection: NWConnection, statusCode: Int, body: Data) {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Unknown"
        }

        let statusLine = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        let headers = "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"

        var responseData = Data()
        responseData.append(statusLine.data(using: .utf8)!)
        responseData.append(headers.data(using: .utf8)!)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("[TopicServer] Send error: \(error)")
            }
            connection.cancel()
        })
    }
}

// MARK: - Server Payload

/// Payload format served by the Mac's TopicServer.
/// Matches `TopicSyncPayload` on the iPhone for zero-parse effort.
private struct ServerTopicPayload: Codable {
    let v: Int
    let timestamp: String
    let topics: [TopicPayloadItem]
}

private struct TopicPayloadItem: Codable {
    let id: String
    let name: String
    let sessionKey: String
    // Coupling note: iPhone's TopicPayloadItem decodes isArchived as Bool?
    // Codable handles Bool→Bool? correctly. Changes to this type must update both.
    let isArchived: Bool
    let lastActivityAt: String?
    let lastMessagePreview: String?
}

// MARK: - Shared Formatters

// ISO8601DateFormatter is not thread-safe, but TopicServer's queue is serial,
// so a static shared instance is safe here.
extension TopicServer {
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
