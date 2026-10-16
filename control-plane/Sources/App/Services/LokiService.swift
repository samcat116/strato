import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor
import StratoShared

/// Service for pushing and querying VM logs from Loki
actor LokiService {
    private let app: Application
    /// Loki push/query endpoint, or `nil` when `LOKI_ENDPOINT` is unset (Loki not deployed).
    let lokiEndpoint: String?
    private let httpClient: HTTPClient

    init(app: Application) {
        self.app = app
        self.lokiEndpoint = app.controlPlaneConfiguration.string(.lokiEndpoint)
        self.httpClient = app.http.client.shared
    }

    // MARK: - Push Logs to Loki

    /// Group by the complete Loki label set while retaining arrival order in
    /// each stream. Labels such as level/source/operation are stream identity.
    nonisolated static func vmBatch(_ messages: [VMLogMessage]) throws -> LokiPushRequest {
        try batch(
            messages.map { message in
                (
                    [
                        "service_name": "strato-agent",
                        "vm_id": message.vmId,
                        "level": message.level.rawValue,
                        "source": message.source.rawValue,
                        "event_type": message.eventType.rawValue,
                        "operation": message.operation ?? "",
                    ].filter { !$0.value.isEmpty },
                    message.timestamp, message.message
                )
            })
    }

    nonisolated static func sandboxBatch(_ messages: [SandboxLogMessage]) throws -> LokiPushRequest {
        try batch(
            messages.map { message in
                (
                    [
                        "service_name": "strato-agent",
                        "sandbox_id": message.sandboxId,
                        "stream": message.stream,
                        "source": "workload",
                    ].filter { !$0.value.isEmpty },
                    message.timestamp, message.message
                )
            })
    }

    private nonisolated static func batch(_ lines: [([String: String], Date, String)]) throws -> LokiPushRequest {
        var streams: [LokiStream] = []
        for (labels, timestamp, message) in lines {
            let nanos = timestamp.timeIntervalSince1970 * 1_000_000_000
            guard nanos.isFinite, nanos >= Double(Int64.min), nanos < Double(Int64.max) else {
                throw LokiError.pushFailed("Invalid timestamp")
            }
            let value = [String(Int64(nanos)), message]
            if let index = streams.firstIndex(where: { $0.stream == labels }) {
                streams[index].values.append(value)
            } else {
                streams.append(LokiStream(stream: labels, values: [value]))
            }
        }
        return LokiPushRequest(streams: streams)
    }

    func pushLogs(_ messages: [VMLogMessage]) async throws {
        try await push(Self.vmBatch(messages))
    }

    func pushSandboxLogs(_ messages: [SandboxLogMessage]) async throws {
        try await push(Self.sandboxBatch(messages))
    }

    /// Failures reach the ingestor's circuit breaker. Do not log per line or
    /// retry here: this is lossy telemetry and a slow dependency must not hold
    /// the control-plane drain indefinitely.
    private func push(_ batch: LokiPushRequest) async throws {
        guard let lokiEndpoint, !batch.streams.isEmpty else { return }
        let body = try JSONEncoder().encode(batch)
        var request = HTTPClientRequest(url: "\(lokiEndpoint)/loki/api/v1/push")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: body))
        let httpClient = self.httpClient
        let requestToSend = request
        // AsyncHTTPClient's execute deadline ends when response headers arrive.
        // Keep a deadline around body consumption too: a trickling/missing body
        // must release the serial worker and trip its outage gate. Cancellation
        // of the body iterator cancels the underlying HTTP transaction.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let response = try await httpClient.execute(requestToSend, timeout: .seconds(2))
                guard (200..<300).contains(Int(response.status.code)) else {
                    throw LokiError.pushFailed("HTTP \(response.status.code)")
                }
                // Consume small replies for connection reuse, with a hard cap.
                _ = try await response.body.collect(upTo: 64 * 1024)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw HTTPClientError.deadlineExceeded
            }
            defer { group.cancelAll() }
            _ = try await group.next()
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

    /// Query workload logs for a specific sandbox (issue #423).
    func querySandboxLogs(
        sandboxId: String,
        start: Date? = nil,
        end: Date? = nil,
        limit: Int = 100,
        direction: QueryDirection = .backward
    ) async throws -> [LogEntry] {
        let query = "{sandbox_id=\"\(sandboxId)\"}"
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
        guard let lokiEndpoint else {
            throw LokiError.notConfigured
        }

        var urlComponents = URLComponents(string: "\(lokiEndpoint)/loki/api/v1/query_range")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "direction", value: direction.rawValue),
        ]

        // Default to last 24 hours if no time range specified
        let endTime = end ?? Date()
        let startTime = start ?? endTime.addingTimeInterval(-86400)  // 24 hours ago

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

        let body = try await response.body.collect(upTo: 10 * 1024 * 1024)  // 10MB max
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
    case notConfigured
    case queryFailed(String)
    case pushFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Loki URL"
        case .notConfigured:
            return "Loki is not configured (LOKI_ENDPOINT unset)"
        case .pushFailed(let reason):
            return "Loki push failed: \(reason)"
        case .queryFailed(let reason):
            return "Loki query failed: \(reason)"
        }
    }
}

// MARK: - Loki API Types

struct LokiPushRequest: Encodable {
    let streams: [LokiStream]
}

struct LokiStream: Codable {
    let stream: [String: String]
    var values: [[String]]
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
    private struct LokiServiceKey: StorageKey, LockKey {
        typealias Value = LokiService
    }

    var lokiService: LokiService {
        get {
            lazyService(LokiServiceKey.self) { LokiService(app: self) }
        }
    }

    /// Check if Loki is enabled (endpoint configured)
    var lokiEnabled: Bool {
        lokiService.lokiEndpoint != nil
    }
}

// MARK: - Request Extension

extension Request {
    var lokiService: LokiService {
        application.lokiService
    }
}
