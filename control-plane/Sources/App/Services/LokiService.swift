import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor
import StratoShared

/// Service for pushing and querying VM logs from Loki
actor LokiService {
    private let app: Application
    private let lokiEndpoint: String
    private let httpClient: HTTPClient

    init(app: Application) {
        self.app = app
        self.lokiEndpoint = Environment.get("LOKI_ENDPOINT") ?? "http://loki:3100"
        self.httpClient = app.http.client.shared
    }

    // MARK: - Push Logs to Loki

    /// Push a VM log message to Loki
    func pushLog(_ logMessage: VMLogMessage) async throws {
        let labels = [
            "service_name": "strato-agent",
            "vm_id": logMessage.vmId,
            "level": logMessage.level.rawValue,
            "source": logMessage.source.rawValue,
            "event_type": logMessage.eventType.rawValue,
            "operation": logMessage.operation ?? ""
        ].filter { !$0.value.isEmpty }

        let lokiStream = LokiPushRequest(
            streams: [
                LokiStream(
                    stream: labels,
                    values: [
                        [
                            String(Int(logMessage.timestamp.timeIntervalSince1970 * 1_000_000_000)),
                            logMessage.message
                        ]
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        let body = try encoder.encode(lokiStream)

        var request = HTTPClientRequest(url: "\(lokiEndpoint)/loki/api/v1/push")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: body))

        do {
            let response = try await httpClient.execute(request, timeout: .seconds(10))
            if response.status.code >= 400 {
                app.logger.error("Failed to push log to Loki", metadata: [
                    "status": .stringConvertible(response.status.code),
                    "vmId": .string(logMessage.vmId)
                ])
            }
        } catch {
            app.logger.error("Error pushing log to Loki: \(error)")
        }
    }

    // MARK: - Query Logs from Loki

    /// Query logs for a specific VM
    func queryVMLogs(
        vmId: String,
        start: Date? = nil,
        end: Date? = nil,
        limit: Int = 100,
        direction: QueryDirection = .backward
    ) async throws -> [LogEntry] {
        let query = buildLogQLQuery(vmId: vmId)
        return try await executeQuery(
            query: query,
            start: start,
            end: end,
            limit: limit,
            direction: direction
        )
    }

    /// Query logs with custom LogQL query
    func queryLogs(
        query: String,
        start: Date? = nil,
        end: Date? = nil,
        limit: Int = 100,
        direction: QueryDirection = .backward
    ) async throws -> [LogEntry] {
        return try await executeQuery(
            query: query,
            start: start,
            end: end,
            limit: limit,
            direction: direction
        )
    }

    private func buildLogQLQuery(vmId: String) -> String {
        return "{vm_id=\"\(vmId)\"}"
    }

    private func executeQuery(
        query: String,
        start: Date?,
        end: Date?,
        limit: Int,
        direction: QueryDirection
    ) async throws -> [LogEntry] {
        var urlComponents = URLComponents(string: "\(lokiEndpoint)/loki/api/v1/query_range")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "direction", value: direction.rawValue)
        ]

        // Default to last 24 hours if no time range specified
        let endTime = end ?? Date()
        let startTime = start ?? endTime.addingTimeInterval(-86400) // 24 hours ago

        queryItems.append(URLQueryItem(name: "start", value: String(Int(startTime.timeIntervalSince1970))))
        queryItems.append(URLQueryItem(name: "end", value: String(Int(endTime.timeIntervalSince1970))))

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            throw LokiError.invalidURL
        }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET

        let response = try await httpClient.execute(request, timeout: .seconds(30))

        guard response.status == .ok else {
            throw LokiError.queryFailed("HTTP \(response.status.code)")
        }

        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10MB max
        let decoder = JSONDecoder()
        let lokiResponse = try decoder.decode(LokiQueryResponse.self, from: body)

        return lokiResponse.data.result.flatMap { stream in
            stream.values.map { value in
                // value[0] is timestamp in nanoseconds as string, value[1] is the log line
                let timestampNanos = Double(value[0]) ?? 0
                let timestamp = Date(timeIntervalSince1970: timestampNanos / 1_000_000_000)

                return LogEntry(
                    timestamp: timestamp,
                    message: value[1],
                    labels: stream.stream
                )
            }
        }
    }
}

// MARK: - Supporting Types

enum QueryDirection: String {
    case forward = "forward"
    case backward = "backward"
}

struct LogEntry: Content {
    let timestamp: Date
    let message: String
    let labels: [String: String]
}

enum LokiError: Error, LocalizedError {
    case invalidURL
    case queryFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Loki URL"
        case .queryFailed(let reason):
            return "Loki query failed: \(reason)"
        case .connectionFailed(let reason):
            return "Failed to connect to Loki: \(reason)"
        }
    }
}

// MARK: - Loki API Types

struct LokiPushRequest: Encodable {
    let streams: [LokiStream]
}

struct LokiStream: Codable {
    let stream: [String: String]
    let values: [[String]]
}

struct LokiQueryResponse: Codable {
    let status: String
    let data: LokiData
}

struct LokiData: Codable {
    let resultType: String
    let result: [LokiStreamResult]
}

struct LokiStreamResult: Codable {
    let stream: [String: String]
    let values: [[String]]
}

// MARK: - Application Extension

extension Application {
    private struct LokiServiceKey: StorageKey {
        typealias Value = LokiService
    }

    var lokiService: LokiService {
        get {
            if let existing = storage[LokiServiceKey.self] {
                return existing
            }
            let service = LokiService(app: self)
            storage[LokiServiceKey.self] = service
            return service
        }
        set {
            storage[LokiServiceKey.self] = newValue
        }
    }

    /// Check if Loki is enabled (endpoint configured)
    var lokiEnabled: Bool {
        Environment.get("LOKI_ENDPOINT") != nil
    }
}

// MARK: - Request Extension

extension Request {
    var lokiService: LokiService {
        application.lokiService
    }
}
