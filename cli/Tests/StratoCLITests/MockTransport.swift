import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization

@testable import StratoCLICore

/// Scripted `ClientTransport`: returns queued responses in order and records
/// every request it saw. The generated client is exercised end to end — path
/// building, encoding, and decoding all run — with only the network replaced.
final class MockTransport: ClientTransport, Sendable {
    struct ScriptedResponse {
        let statusCode: Int
        let body: Data
        let contentType: String

        init(statusCode: Int, json: String) {
            self.statusCode = statusCode
            self.body = Data(json.utf8)
            self.contentType = "application/json"
        }

        /// A body-less response, as `204 No Content` endpoints return.
        static func empty(statusCode: Int = 204) -> ScriptedResponse {
            ScriptedResponse(statusCode: statusCode, json: "")
        }
    }

    /// One request as the transport saw it, with its body already collected.
    struct RecordedRequest {
        let request: HTTPRequest
        let body: Data?

        var path: String { request.path.map { $0.split(separator: "?").first.map(String.init) ?? $0 } ?? "" }
        var query: String? { request.path?.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) }
        var authorization: String? { request.headerFields[.authorization] }
        var bodyText: String { body.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }

    private struct State {
        var queue: [ScriptedResponse]
        var requests: [RecordedRequest] = []
    }

    private let state: Mutex<State>
    /// Answers a request from its content instead of from the queue. Needed
    /// wherever requests are concurrent, since arrival order is then undefined.
    private let handler: (@Sendable (RecordedRequest) -> ScriptedResponse)?
    init(responses: [ScriptedResponse]) {
        self.state = Mutex(State(queue: responses))
        self.handler = nil
    }

    init(handler: @escaping @Sendable (RecordedRequest) -> ScriptedResponse) {
        self.state = Mutex(State(queue: []))
        self.handler = handler
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var collected: Data?
        if let body { collected = try await Data(collecting: body, upTo: 1024 * 1024) }
        let next = try respond(to: RecordedRequest(request: request, body: collected))

        var headerFields = HTTPFields()
        if !next.body.isEmpty {
            headerFields[.contentType] = next.contentType
        }
        return (
            HTTPResponse(status: .init(code: next.statusCode), headerFields: headerFields),
            next.body.isEmpty ? nil : HTTPBody(next.body)
        )
    }

    private func respond(to request: RecordedRequest) throws -> ScriptedResponse {
        try state.withLock { state in
            state.requests.append(request)
            if let handler { return handler(request) }
            guard !state.queue.isEmpty else {
                struct ExhaustedScript: Error {}
                throw ExhaustedScript()
            }
            return state.queue.removeFirst()
        }
    }

    var recordedRequests: [RecordedRequest] {
        state.withLock { $0.requests }
    }
}

/// A throwaway config/credential directory for a single test.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("strato-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

/// Async-friendly variant of `withTemporaryDirectory`.
func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("strato-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
