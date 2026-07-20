import Foundation

@testable import StratoCLICore

/// Scripted transport: returns queued responses in order and records every
/// request it saw.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct ScriptedResponse {
        let statusCode: Int
        let body: Data

        init(statusCode: Int, json: String) {
            self.statusCode = statusCode
            self.body = Data(json.utf8)
        }
    }

    private let lock = NSLock()
    private var queue: [ScriptedResponse]
    private(set) var requests: [TransportRequest] = []

    init(responses: [ScriptedResponse]) {
        self.queue = responses
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        try dequeue(recording: request)
    }

    /// NSLock use lives in a synchronous helper: Swift 6 forbids holding a
    /// lock across an async function's suspension points.
    private func dequeue(recording request: TransportRequest) throws -> TransportResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !queue.isEmpty else {
            struct ExhaustedScript: Error {}
            throw ExhaustedScript()
        }
        let next = queue.removeFirst()
        return TransportResponse(statusCode: next.statusCode, body: next.body)
    }

    var recordedRequests: [TransportRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
