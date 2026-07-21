import Foundation

/// A `ResourceOperation` as returned by the control plane. `pending` is the
/// only non-terminal status.
public struct ResourceOperation: Codable, Sendable {
    public let id: UUID?
    public let resourceKind: String?
    public let resourceId: UUID?
    public let kind: String
    public let status: String
    public let error: String?
    public let createdAt: Date?
    public let completedAt: Date?

    public var isTerminal: Bool { status != "pending" }
    public var succeeded: Bool { status == "succeeded" }
}

/// Polls `GET /api/operations/:id` until the operation leaves `pending`.
public struct OperationWaiter: Sendable {
    public let pollInterval: Double
    public let timeout: Double
    private let sleeper: @Sendable (_ seconds: Double) async throws -> Void

    public init(
        pollInterval: Double = 2,
        timeout: Double = 600,
        sleeper: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.sleeper = sleeper
    }

    /// Returns the terminal operation, throwing `CLIError.operationFailed`
    /// when it lands on `failed`.
    @discardableResult
    public func wait(for operation: ResourceOperation, client: APIClient) async throws -> ResourceOperation {
        guard let operationID = operation.id else {
            throw CLIError.api(status: 0, message: "Server returned an operation without an id")
        }
        var current = operation
        let deadline = Date().addingTimeInterval(timeout)

        while !current.isTerminal {
            guard Date() < deadline else {
                throw CLIError.timedOut(
                    "Timed out after \(Int(timeout))s waiting for operation \(operationID); "
                        + "check it later with 'strato operation get \(operationID)'.")
            }
            try await sleeper(pollInterval)
            current = try await client.get("/api/operations/\(operationID.uuidString)")
        }

        if !current.succeeded {
            throw CLIError.operationFailed(kind: current.kind, message: current.error ?? "unknown error")
        }
        return current
    }
}
