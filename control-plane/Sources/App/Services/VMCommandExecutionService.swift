import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Owns the live capture window for durable, non-interactive VM commands.
/// PostgreSQL owns status; this actor owns bounded bytes from
/// `guest_exec_started` until the terminal result is durably committed.
actor VMCommandExecutionService {
    static let outputLimitBytes = 1_048_576
    static let completionBudget: TimeInterval = 300

    private struct Capture {
        let agentKey: String
        let deadline: Date
        var stdout = Data()
        var stderr = Data()
        var truncated = false

        mutating func append(_ data: Data, stream: String) {
            let remaining = max(0, VMCommandExecutionService.outputLimitBytes - stdout.count - stderr.count)
            if data.count > remaining { truncated = true }
            guard remaining > 0 else { return }
            let accepted = data.prefix(remaining)
            if stream == "stderr" {
                stderr.append(contentsOf: accepted)
            } else {
                stdout.append(contentsOf: accepted)
            }
        }
    }

    private struct PendingCompletion {
        let capture: Capture
        let exitCode: Int
    }

    private struct Claimed: Decodable { let id: UUID }
    private struct TimedOut: Decodable {
        let id: UUID
        let agentKey: String
        enum CodingKeys: String, CodingKey {
            case id
            case agentKey = "agent_key"
        }
    }

    private let app: Application
    private let sendEnvelope: @Sendable (MessageEnvelope, String) async throws -> Void
    private let beforePersistResult: (@Sendable () async throws -> Void)?
    private let completionRetryDelay: Duration
    private var captures: [UUID: Capture] = [:]
    private var pendingCompletions: [UUID: PendingCompletion] = [:]

    init(
        app: Application,
        sendEnvelope: (@Sendable (MessageEnvelope, String) async throws -> Void)? = nil,
        beforePersistResult: (@Sendable () async throws -> Void)? = nil,
        completionRetryDelay: Duration = .seconds(1)
    ) {
        self.app = app
        self.beforePersistResult = beforePersistResult
        self.completionRetryDelay = completionRetryDelay
        self.sendEnvelope =
            sendEnvelope ?? { [weak app] envelope, agentKey in
                guard let app else { throw CancellationError() }
                try await app.replicaBridge.deliver(envelope, agentKey: agentKey)
            }
    }

    /// Returns true only for a recorded command. Interactive session starts
    /// fall through to `GuestExecSessionManager` without changing behavior.
    func handleStarted(sessionId: String, fromAgentKey agentKey: String) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        do {
            guard
                let execution = try await VMCommandExecution.query(on: app.db)
                    .filter(\.$id == id)
                    .filter(\.$status == .pending)
                    .filter(\.$agentKey == agentKey)
                    .first()
            else { return false }

            captures[id] = Capture(agentKey: execution.agentKey, deadline: execution.deadline)
            do {
                try await sendEnvelope(
                    MessageEnvelope(message: GuestExecInputMessage(sessionId: sessionId, eof: true)),
                    agentKey)
            } catch let error as ReplicaMessageBridge.DeliveryError where !error.isDefinitive {
                app.logger.warning(
                    "VM command stdin EOF delivery outcome is unknown; awaiting command stream",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            } catch {
                captures.removeValue(forKey: id)
                try await fail(id: id, reason: "Could not close command stdin: \(error.localizedDescription)")
            }
            return true
        } catch {
            app.logger.error("Could not identify recorded VM command start: \(error)")
            return false
        }
    }

    func handleOutput(
        sessionId: String, fromAgentKey agentKey: String, stream: String, data: Data
    ) -> Bool {
        guard let id = UUID(uuidString: sessionId), var capture = captures[id],
            capture.agentKey == agentKey
        else { return false }
        guard stream == "stdout" || stream == "stderr" else {
            capture.truncated = true
            captures[id] = capture
            return true
        }
        capture.append(data, stream: stream)
        captures[id] = capture
        return true
    }

    func handleExit(sessionId: String, fromAgentKey agentKey: String, exitCode: Int) async -> Bool {
        guard let id = UUID(uuidString: sessionId), let capture = captures[id],
            capture.agentKey == agentKey
        else { return false }
        captures.removeValue(forKey: id)
        let completion = PendingCompletion(capture: capture, exitCode: exitCode)
        pendingCompletions[id] = completion
        do {
            try await complete(id: id, capture: capture, exitCode: exitCode)
            pendingCompletions.removeValue(forKey: id)
        } catch {
            app.logger.warning(
                "Could not persist completed VM command; retrying",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            Task { [weak self] in
                await self?.retryCompletion(id: id, completion: completion)
            }
        }
        return true
    }

    func handleClosed(
        sessionId: String, fromAgentKey agentKey: String, reason: String?
    ) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        if let capture = captures[id] {
            guard capture.agentKey == agentKey else { return false }
            captures.removeValue(forKey: id)
        } else {
            // Start failures are reported as `guest_exec_closed` without a
            // preceding `guest_exec_started`, so there is no live capture yet.
            // Classify those against durable state instead of leaving the
            // operation pending until the timeout sweep.
            do {
                guard
                    try await VMCommandExecution.query(on: app.db)
                        .filter(\.$id == id)
                        .filter(\.$status == .pending)
                        .filter(\.$agentKey == agentKey)
                        .first() != nil
                else { return false }
            } catch {
                app.logger.error("Could not identify closed recorded VM command: \(error)")
                return false
            }
        }
        do {
            try await fail(
                id: id, reason: reason ?? "Guest command session closed without an exit code")
        } catch {
            app.logger.error("Could not fail closed recorded VM command: \(error)")
        }
        return true
    }

    func markDispatchFailed(id: UUID, reason: String) async {
        do {
            try await fail(id: id, reason: reason)
        } catch {
            app.logger.error("Could not persist VM command dispatch failure: \(error)")
        }
    }

    /// Every replica may run this pass. The conditional UPDATE is the claim,
    /// so a command crosses pending -> failed exactly once without a Valkey
    /// sweep lock.
    func sweepStuck(now: Date = Date()) async {
        // Also bound actor-local memory if a database state transition raced a
        // suspended start-classification query and therefore did not return
        // this id from the conditional update below.
        captures = captures.filter { $0.value.deadline > now }
        guard let sql = app.db as? any SQLDatabase else { return }
        do {
            let timedOut = try await sql.raw(
                """
                UPDATE vm_command_executions
                SET status = 'failed', error = 'Command execution timed out', completed_at = \(bind: now)
                WHERE status = 'pending' AND deadline <= \(bind: now)
                RETURNING id, agent_key
                """
            ).all(decoding: TimedOut.self)
            for execution in timedOut {
                captures.removeValue(forKey: execution.id)
                try? await sendEnvelope(
                    MessageEnvelope(
                        message: GuestExecCloseMessage(
                            sessionId: execution.id.uuidString, reason: "command execution timed out")),
                    execution.agentKey)
            }
        } catch {
            app.logger.error("Stuck VM command sweep failed: \(error)")
        }
    }

    private func complete(id: UUID, capture: Capture, exitCode: Int) async throws {
        try await beforePersistResult?()
        try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            let claimed = try await sql.raw(
                """
                UPDATE vm_command_executions
                SET status = 'succeeded', error = NULL, completed_at = now()
                WHERE id = \(bind: id) AND status IN ('pending', 'failed')
                RETURNING id
                """
            ).all(decoding: Claimed.self)
            guard !claimed.isEmpty else { return }
            guard let payload = try await VMCommandPayload.find(id, on: db) else {
                throw Abort(.internalServerError, reason: "VM command payload is missing")
            }
            payload.recordResult(
                stdout: capture.stdout, stderr: capture.stderr,
                exitCode: exitCode, truncated: capture.truncated)
            try await payload.update(on: db)
        }
    }

    private func retryCompletion(id: UUID, completion: PendingCompletion) async {
        var retryDelay = completionRetryDelay
        while pendingCompletions[id] != nil, !app.didShutdown {
            try? await Task.sleep(for: retryDelay)
            guard pendingCompletions[id] != nil, !app.didShutdown else { return }
            do {
                try await complete(
                    id: id, capture: completion.capture, exitCode: completion.exitCode)
                pendingCompletions.removeValue(forKey: id)
                return
            } catch {
                app.logger.warning(
                    "Could not persist completed VM command; retrying",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
                retryDelay = min(retryDelay + retryDelay, .seconds(30))
            }
        }
    }

    private func fail(id: UUID, reason: String) async throws {
        guard let sql = app.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        _ = try await sql.raw(
            """
            UPDATE vm_command_executions
            SET status = 'failed', error = \(bind: String(reason.prefix(4_096))), completed_at = now()
            WHERE id = \(bind: id) AND status = 'pending'
            RETURNING id
            """
        ).all(decoding: Claimed.self)
    }
}

extension Application {
    private struct VMCommandExecutionServiceKey: StorageKey, LockKey {
        typealias Value = VMCommandExecutionService
    }

    var vmCommandExecutionService: VMCommandExecutionService {
        get { lazyService(VMCommandExecutionServiceKey.self) { VMCommandExecutionService(app: self) } }
        set { setStorageValue(VMCommandExecutionServiceKey.self, to: newValue) }
    }
}

extension Request {
    var vmCommandExecutionService: VMCommandExecutionService {
        application.vmCommandExecutionService
    }
}

extension VMCommandExecution {
    /// Persist attribution/status and the exact argv in one transaction owned
    /// by the caller. Keeping argv in the cold payload preserves the audit fact
    /// without adding it to every operation poll/history row.
    func create(command: [String], on db: any Database) async throws {
        try await create(on: db)
        try await VMCommandPayload(
            executionID: try requireID(), command: command
        ).create(on: db)
    }

    func operationResponse(on db: any Database) async throws -> OperationResponse {
        let executionID = try requireID()
        let payload =
            status == .succeeded
            ? try await VMCommandPayload.find(executionID, on: db)
            : nil
        return try operationResponse(payload: payload)
    }

    func operationResponse(payload: VMCommandPayload?) throws -> OperationResponse {
        let executionID = try requireID()
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
            id: executionID,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            kind: .run,
            status: status,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt,
            result: result)
    }
}
