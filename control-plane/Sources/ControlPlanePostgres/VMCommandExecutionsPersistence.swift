import Foundation
import PostgresNIO

public struct VMCommandExecutionSnapshot: Equatable, Sendable {
    public let id: UUID
    public let vmID: UUID
    public let actorType: String
    public let actorID: UUID
    public let agentKey: String
    public let status: String
    public let error: String?
    public let deadline: Date
    public let createdAt: Date?
    public let completedAt: Date?
}

public struct VMCommandPayloadSnapshot: Equatable, Sendable {
    public let executionID: UUID
    public let command: [String]
    public let stdout: Data?
    public let stderr: Data?
    public let exitCode: Int?
    public let truncated: Bool?
}

public struct TimedOutVMCommandSnapshot: Equatable, Sendable {
    public let id: UUID
    public let agentKey: String
}

public enum VMCommandPersistenceError: Error, Equatable, Sendable {
    case missingExecution(UUID)
    case missingPayload(UUID)
    case invalidCount(Int64)
}

/// Owns the durable command status row and its cold argv/result side table.
/// Creation and completion each update both tables on one leased connection
/// and in one PostgreSQL transaction.
public struct VMCommandExecutionsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func create(
        id: UUID = UUID(),
        vmID: UUID,
        actorType: String,
        actorID: UUID,
        agentKey: String,
        deadline: Date,
        command: [String]
    ) async throws -> VMCommandExecutionSnapshot {
        try await database.withTransaction(operation: "vm_commands.create") { session in
            guard let execution = try await session.execute(
                InsertVMCommandExecution(
                    id: id,
                    vmID: vmID,
                    actorType: actorType,
                    actorID: actorID,
                    agentKey: agentKey,
                    deadline: deadline),
                operation: "vm_commands.create.execution"
            ).first else {
                throw VMCommandPersistenceError.missingExecution(id)
            }
            guard try await session.execute(
                InsertVMCommandPayload(executionID: id, command: command),
                operation: "vm_commands.create.payload"
            ) == [id] else {
                throw VMCommandPersistenceError.missingPayload(id)
            }
            return execution.snapshot
        }
    }

    public func execution(id: UUID) async throws -> VMCommandExecutionSnapshot? {
        try await database.withSession(operation: "vm_commands.lookup") { session in
            try await session.execute(
                FindVMCommandExecution(id: id),
                operation: "vm_commands.lookup.query"
            ).first?.snapshot
        }
    }

    public func pendingExecution(id: UUID, agentKey: String) async throws
        -> VMCommandExecutionSnapshot?
    {
        try await database.withSession(operation: "vm_commands.classify") { session in
            try await session.execute(
                FindPendingVMCommandExecution(id: id, agentKey: agentKey),
                operation: "vm_commands.classify.query"
            ).first?.snapshot
        }
    }

    public func history(vmID: UUID, limit: Int) async throws -> [VMCommandExecutionSnapshot] {
        try await database.withSession(operation: "vm_commands.history") { session in
            try await session.execute(
                ListVMCommandExecutions(vmID: vmID, limit: limit),
                operation: "vm_commands.history.query"
            ).map(\.snapshot)
        }
    }

    public func payload(executionID: UUID) async throws -> VMCommandPayloadSnapshot? {
        try await database.withSession(operation: "vm_commands.payload") { session in
            try await session.execute(
                FindVMCommandPayload(executionID: executionID),
                operation: "vm_commands.payload.query"
            ).first?.snapshot
        }
    }

    @discardableResult
    public func complete(
        id: UUID,
        stdout: Data,
        stderr: Data,
        exitCode: Int,
        truncated: Bool
    ) async throws -> Bool {
        try await database.withTransaction(operation: "vm_commands.complete") { session in
            guard try await session.execute(
                CompleteVMCommandExecution(id: id),
                operation: "vm_commands.complete.execution"
            ).first != nil else { return false }
            guard try await session.execute(
                RecordVMCommandResult(
                    executionID: id,
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    truncated: truncated),
                operation: "vm_commands.complete.payload"
            ).first != nil else {
                throw VMCommandPersistenceError.missingPayload(id)
            }
            return true
        }
    }

    @discardableResult
    public func fail(id: UUID, reason: String) async throws -> Bool {
        try await database.withSession(operation: "vm_commands.fail") { session in
            try await session.execute(
                FailVMCommandExecution(id: id, reason: String(reason.prefix(4_096))),
                operation: "vm_commands.fail.query"
            ).first != nil
        }
    }

    public func failTimedOut(now: Date) async throws -> [TimedOutVMCommandSnapshot] {
        try await database.withSession(operation: "vm_commands.timeout") { session in
            try await session.execute(
                FailTimedOutVMCommands(now: now),
                operation: "vm_commands.timeout.query"
            )
        }
    }

    public func count() async throws -> Int {
        let value = try await database.withSession(operation: "vm_commands.count") { session in
            try await session.execute(
                CountVMCommandExecutions(),
                operation: "vm_commands.count.query"
            ).first ?? 0
        }
        guard let count = Int(exactly: value) else {
            throw VMCommandPersistenceError.invalidCount(value)
        }
        return count
    }
}

private let vmCommandColumns = """
    id, vm_id, actor_type::text, actor_id, agent_key, status::text,
    error, deadline, created_at, completed_at
    """

private struct VMCommandExecutionRecord: Sendable {
    let id: UUID
    let vmID: UUID
    let actorType: String
    let actorID: UUID
    let agentKey: String
    let status: String
    let error: String?
    let deadline: Date
    let createdAt: Date?
    let completedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, vmID, actorType, actorID, agentKey, status,
            error, deadline, createdAt, completedAt
        ) = try row.decode((
            UUID, UUID, String, UUID, String, String,
            String?, Date, Date?, Date?
        ).self)
    }

    var snapshot: VMCommandExecutionSnapshot {
        VMCommandExecutionSnapshot(
            id: id,
            vmID: vmID,
            actorType: actorType,
            actorID: actorID,
            agentKey: agentKey,
            status: status,
            error: error,
            deadline: deadline,
            createdAt: createdAt,
            completedAt: completedAt)
    }
}

private protocol VMCommandStatement: PostgresPreparedStatement
where Row == VMCommandExecutionRecord {}

extension VMCommandStatement {
    func decodeRow(_ row: PostgresRow) throws -> VMCommandExecutionRecord {
        try VMCommandExecutionRecord(row: row)
    }
}

private struct InsertVMCommandExecution: VMCommandStatement {
    static var sql: String {
        """
        INSERT INTO vm_command_executions (
            id, vm_id, actor_type, actor_id, agent_key, status, error,
            deadline, created_at, completed_at
        ) VALUES ($1, $2, $3, $4, $5, 'pending', NULL, $6, CURRENT_TIMESTAMP, NULL)
        RETURNING \(vmCommandColumns)
        """
    }
    let id: UUID
    let vmID: UUID
    let actorType: String
    let actorID: UUID
    let agentKey: String
    let deadline: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(vmID)
        bindings.append(actorType)
        bindings.append(actorID)
        bindings.append(agentKey)
        bindings.append(deadline)
        return bindings
    }
}

private struct FindVMCommandExecution: VMCommandStatement {
    static var sql: String { "SELECT \(vmCommandColumns) FROM vm_command_executions WHERE id = $1" }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindPendingVMCommandExecution: VMCommandStatement {
    static var sql: String {
        "SELECT \(vmCommandColumns) FROM vm_command_executions WHERE id = $1 AND status = 'pending' AND agent_key = $2"
    }
    let id: UUID
    let agentKey: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(agentKey)
        return bindings
    }
}

private struct ListVMCommandExecutions: VMCommandStatement {
    static var sql: String {
        "SELECT \(vmCommandColumns) FROM vm_command_executions WHERE vm_id = $1 ORDER BY created_at DESC LIMIT $2"
    }
    let vmID: UUID
    let limit: Int
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(vmID)
        bindings.append(limit)
        return bindings
    }
}

private struct VMCommandPayloadRecord: Sendable {
    let executionID: UUID
    let command: [String]
    let stdout: Data?
    let stderr: Data?
    let exitCode: Int?
    let truncated: Bool?

    init(row: PostgresRow) throws {
        (executionID, command, stdout, stderr, exitCode, truncated) = try row.decode(
            (UUID, [String], Data?, Data?, Int?, Bool?).self)
    }

    var snapshot: VMCommandPayloadSnapshot {
        VMCommandPayloadSnapshot(
            executionID: executionID,
            command: command,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            truncated: truncated)
    }
}

private struct InsertVMCommandPayload: PostgresPreparedStatement {
    static let sql = "INSERT INTO vm_command_payloads (execution_id, command) VALUES ($1, $2) RETURNING execution_id"
    typealias Row = UUID
    let executionID: UUID
    let command: [String]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(executionID)
        bindings.append(command)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindVMCommandPayload: PostgresPreparedStatement {
    static let sql = "SELECT execution_id, command, stdout, stderr, exit_code, truncated FROM vm_command_payloads WHERE execution_id = $1"
    typealias Row = VMCommandPayloadRecord
    let executionID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(executionID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> VMCommandPayloadRecord {
        try VMCommandPayloadRecord(row: row)
    }
}

private struct CompleteVMCommandExecution: PostgresPreparedStatement {
    static let sql = """
        UPDATE vm_command_executions
        SET status = 'succeeded', error = NULL, completed_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND status IN ('pending', 'failed')
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RecordVMCommandResult: PostgresPreparedStatement {
    static let sql = """
        UPDATE vm_command_payloads
        SET stdout = $2, stderr = $3, exit_code = $4, truncated = $5
        WHERE execution_id = $1
        RETURNING execution_id
        """
    typealias Row = UUID
    let executionID: UUID
    let stdout: Data
    let stderr: Data
    let exitCode: Int
    let truncated: Bool
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(executionID)
        try bindings.append(stdout)
        try bindings.append(stderr)
        bindings.append(exitCode)
        bindings.append(truncated)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FailVMCommandExecution: PostgresPreparedStatement {
    static let sql = """
        UPDATE vm_command_executions
        SET status = 'failed', error = $2, completed_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND status = 'pending'
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let reason: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(reason)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FailTimedOutVMCommands: PostgresPreparedStatement {
    static let sql = """
        UPDATE vm_command_executions
        SET status = 'failed', error = 'Command execution timed out', completed_at = $1
        WHERE status = 'pending' AND deadline <= $1
        RETURNING id, agent_key
        """
    typealias Row = TimedOutVMCommandSnapshot
    let now: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(now)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> TimedOutVMCommandSnapshot {
        let value = try row.decode((UUID, String).self)
        return TimedOutVMCommandSnapshot(id: value.0, agentKey: value.1)
    }
}

private struct CountVMCommandExecutions: PostgresPreparedStatement {
    static let sql = "SELECT COUNT(*)::bigint FROM vm_command_executions"
    typealias Row = Int64
    func makeBindings() -> PostgresBindings { PostgresBindings(capacity: 0) }
    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}
