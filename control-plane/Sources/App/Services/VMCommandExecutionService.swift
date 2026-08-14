import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Owns the live capture window for durable, non-interactive VM commands.
/// PostgreSQL owns status; this actor owns only bounded bytes between
/// `guest_exec_started` and the terminal frame.
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
    private var captures: [UUID: Capture] = [:]

    init(
        app: Application,
        sendEnvelope: (@Sendable (MessageEnvelope, String) async throws -> Void)? = nil
    ) {
        self.app = app
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
        do {
            try await complete(id: id, capture: capture, exitCode: exitCode)
        } catch {
            app.logger.error("Could not complete recorded VM command: \(error)")
            try? await fail(id: id, reason: "Could not persist command result")
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

    /// A disconnected agent cannot complete any command it was running. Fail
    /// those operations immediately instead of making callers wait for the
    /// five-minute backstop; the conditional update still lets an exit frame
    /// that committed first win the race.
    func failAll(forAgent agentKey: String, reason: String) async {
        guard let sql = app.db as? any SQLDatabase else { return }
        do {
            let failed = try await sql.raw(
                """
                UPDATE vm_command_executions
                SET status = 'failed', error = \(bind: String(reason.prefix(4_096))), completed_at = now()
                WHERE agent_key = \(bind: agentKey) AND status = 'pending'
                RETURNING id
                """
            ).all(decoding: Claimed.self)
            for execution in failed {
                captures.removeValue(forKey: execution.id)
            }
        } catch {
            app.logger.error("Could not fail VM commands for disconnected agent: \(error)")
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
        try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            let claimed = try await sql.raw(
                """
                UPDATE vm_command_executions
                SET status = 'succeeded', error = NULL, completed_at = now()
                WHERE id = \(bind: id) AND status = 'pending'
                RETURNING id
                """
            ).all(decoding: Claimed.self)
            guard !claimed.isEmpty else { return }
            try await VMCommandOutput(
                executionID: id, stdout: capture.stdout, stderr: capture.stderr,
                exitCode: exitCode, truncated: capture.truncated
            ).create(on: db)
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
    func operationResponse(on db: any Database) async throws -> OperationResponse {
        let executionID = try requireID()
        let output =
            status == .succeeded
            ? try await VMCommandOutput.find(executionID, on: db)
            : nil
        return try operationResponse(output: output)
    }

    func operationResponse(output: VMCommandOutput?) throws -> OperationResponse {
        let executionID = try requireID()
        return OperationResponse(
            id: executionID,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            kind: .run,
            status: status,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt,
            result: output.map {
                VMCommandResultResponse(
                    stdout: String(decoding: $0.stdout, as: UTF8.self),
                    stderr: String(decoding: $0.stderr, as: UTF8.self),
                    exitCode: $0.exitCode,
                    truncated: $0.truncated)
            })
    }
}
