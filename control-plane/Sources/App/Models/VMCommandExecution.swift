import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Application-side intent for a captured command. Durable state crosses the
/// persistence boundary as `VMCommandExecutionSnapshot`.
struct VMCommandExecution: Equatable, Sendable {
    let id: UUID
    let vmID: UUID
    let actorID: UUID
    let agentKey: String
    let deadline: Date

    init(
        id: UUID = UUID(), vmID: UUID, actorID: UUID, agentKey: String,
        deadline: Date
    ) {
        self.id = id
        self.vmID = vmID
        self.actorID = actorID
        self.agentKey = agentKey
        self.deadline = deadline
    }

    func requireID() throws -> UUID { id }

    @discardableResult
    func create(command: [String], using persistence: VMCommandExecutionsPersistence) async throws
        -> VMCommandExecutionSnapshot
    {
        try await persistence.create(
            id: id,
            vmID: vmID,
            actorType: MutationActorType.user.rawValue,
            actorID: actorID,
            agentKey: agentKey,
            deadline: deadline,
            command: command)
    }

    static func find(_ id: UUID, using persistence: VMCommandExecutionsPersistence) async throws
        -> VMCommandExecutionSnapshot?
    {
        try await persistence.execution(id: id)
    }

    static func count(using persistence: VMCommandExecutionsPersistence) async throws -> Int {
        try await persistence.count()
    }
}

typealias VMCommandPayload = VMCommandPayloadSnapshot

extension VMCommandPayloadSnapshot {
    static func find(_ id: UUID, using persistence: VMCommandExecutionsPersistence) async throws
        -> VMCommandPayloadSnapshot?
    {
        try await persistence.payload(executionID: id)
    }
}

extension VMCommandExecutionSnapshot {
    func operationResponse(using persistence: VMCommandExecutionsPersistence) async throws
        -> OperationResponse
    {
        let payload = status == VMOperationStatus.succeeded.rawValue
            ? try await persistence.payload(executionID: id)
            : nil
        return try operationResponse(payload: payload)
    }

    func operationResponse(payload: VMCommandPayloadSnapshot?) throws -> OperationResponse {
        guard let operationStatus = VMOperationStatus(rawValue: status) else {
            throw Abort(.internalServerError, reason: "Unknown VM command status: \(status)")
        }
        let result = payload.flatMap { payload -> VMCommandResultResponse? in
            guard let stdout = payload.stdout, let stderr = payload.stderr,
                let exitCode = payload.exitCode, let truncated = payload.truncated
            else { return nil }
            return VMCommandResultResponse(
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: exitCode,
                truncated: truncated)
        }
        return OperationResponse(
            id: id,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            kind: .run,
            status: operationStatus,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt,
            result: result)
    }
}
