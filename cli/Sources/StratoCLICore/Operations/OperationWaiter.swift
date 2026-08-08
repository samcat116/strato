import Foundation
import StratoAPIClient

/// The generated `ResourceOperation`, under the name the commands use.
public typealias ResourceOperation = Components.Schemas.ResourceOperation

extension ResourceOperation {
    /// `pending` is the only non-terminal status.
    public var isTerminal: Bool { status != .pending }
    public var succeeded: Bool { status == .succeeded }
}

/// What a `202` leaves the CLI to follow: an id, and nothing else.
///
/// One shape since STR-151 — every mutation answers with its resource and a
/// `mutationId`, and that id is what `GET /api/operations/{id}` answers for.
/// It carried a `seed` as well, an operation the mutation had already returned
/// in a terminal state, which the façade could serve from a real row; STR-152
/// dropped the table, so every answer is synthesized on read and the first
/// poll is the only way to get one.
public struct AcceptedMutation: Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public init(_ operation: ResourceOperation) {
        self.id = operation.id ?? ""
    }
}

/// Polls `getOperation` until the mutation leaves `pending`.
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
    public func wait(
        for accepted: AcceptedMutation, client: any APIProtocol
    ) async throws -> ResourceOperation {
        guard !accepted.id.isEmpty else {
            throw CLIError.api(status: 0, message: "Server accepted the mutation without an id")
        }
        var current: ResourceOperation?
        let deadline = Date().addingTimeInterval(timeout)

        while current?.isTerminal != true {
            guard Date() < deadline else {
                throw CLIError.timedOut(
                    "Timed out after \(Int(timeout))s waiting for operation \(accepted.id); "
                        + "check it later with 'strato operation get \(accepted.id)'.")
            }
            // The first pass reads immediately; the sleep only separates one
            // pending answer from the next.
            if current != nil {
                try await sleeper(pollInterval)
            }
            current = try await client.getOperation(path: .init(operationID: accepted.id)).ok.body.json
        }

        guard let final = current else {
            throw CLIError.api(status: 0, message: "Server returned no operation for \(accepted.id)")
        }
        if !final.succeeded {
            throw CLIError.operationFailed(
                kind: final.kind.rawValue, message: final.error ?? "unknown error")
        }
        return final
    }

    @discardableResult
    public func wait(
        for operation: ResourceOperation, client: any APIProtocol
    ) async throws -> ResourceOperation {
        try await wait(for: AcceptedMutation(operation), client: client)
    }
}
