import ControlPlanePostgres
import Foundation
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
        var deadline: Date
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

    private let app: Application
    private let persistence: VMCommandExecutionsPersistence
    private let sendEnvelope: @Sendable (MessageEnvelope, String) async throws -> Void
    private let beforeClassifyStart: (@Sendable () async throws -> Void)?
    private let beforePersistResult: (@Sendable () async throws -> Void)?
    private let retryDelay: Duration
    private var captures: [UUID: Capture] = [:]
    private var pendingCompletions: [UUID: PendingCompletion] = [:]

    init(
        app: Application,
        persistence: VMCommandExecutionsPersistence,
        sendEnvelope: (@Sendable (MessageEnvelope, String) async throws -> Void)? = nil,
        beforeClassifyStart: (@Sendable () async throws -> Void)? = nil,
        beforePersistResult: (@Sendable () async throws -> Void)? = nil,
        retryDelay: Duration = .seconds(1)
    ) {
        self.app = app
        self.persistence = persistence
        self.beforeClassifyStart = beforeClassifyStart
        self.beforePersistResult = beforePersistResult
        self.retryDelay = retryDelay
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
        guard app.guestExecSessionManager.getSession(sessionId: sessionId) == nil else {
            return false
        }
        if let capture = captures[id] { return capture.agentKey == agentKey }
        if let completion = pendingCompletions[id] {
            return completion.capture.agentKey == agentKey
        }
        do {
            guard let execution = try await recordedExecution(id: id, agentKey: agentKey) else {
                return false
            }

            captures[id] = Capture(agentKey: execution.agentKey, deadline: execution.deadline)
            await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
            return true
        } catch {
            // The process has already started, so falling through would lose
            // all later frames. Install a bounded provisional capture while
            // the durable classification is retried.
            captures[id] = Capture(
                agentKey: agentKey,
                deadline: Date().addingTimeInterval(Self.completionBudget))
            app.logger.warning(
                "Could not classify started VM command; retrying",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "agentKey": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
            Task { [weak self] in
                await self?.retryStartClassification(id: id, agentKey: agentKey)
            }
            await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
            return true
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
                    try await persistence.pendingExecution(
                        id: id, agentKey: agentKey) != nil
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
        do {
            let timedOut = try await persistence.failTimedOut(now: now)
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
        _ = try await persistence.complete(
            id: id,
            stdout: capture.stdout,
            stderr: capture.stderr,
            exitCode: exitCode,
            truncated: capture.truncated)
    }

    private func recordedExecution(id: UUID, agentKey: String) async throws
        -> VMCommandExecutionSnapshot?
    {
        try await beforeClassifyStart?()
        return try await persistence.pendingExecution(id: id, agentKey: agentKey)
    }

    private func closeStdin(sessionId: String, id: UUID, agentKey: String) async {
        do {
            try await sendEnvelope(
                MessageEnvelope(message: GuestExecInputMessage(sessionId: sessionId, eof: true)),
                agentKey)
        } catch {
            // `guest_exec_started` proves the process may already have run.
            // An EOF delivery failure therefore cannot safely become a
            // retryable command failure; the terminal stream or deadline owns
            // the outcome from here.
            app.logger.warning(
                "Could not deliver VM command stdin EOF; awaiting command stream",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "agentKey": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func retryStartClassification(id: UUID, agentKey: String) async {
        var nextDelay = retryDelay
        while captures[id]?.agentKey == agentKey, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
            guard captures[id]?.agentKey == agentKey, !app.didShutdown else {
                return
            }
            do {
                guard let execution = try await recordedExecution(id: id, agentKey: agentKey) else {
                    captures.removeValue(forKey: id)
                    return
                }
                // The database query suspends this actor. A terminal frame may
                // have moved the capture into pending completion meanwhile;
                // never resurrect it after that transition.
                guard var capture = captures[id], capture.agentKey == agentKey else { return }
                capture.deadline = execution.deadline
                captures[id] = capture
                return
            } catch {
                app.logger.warning(
                    "Could not classify started VM command; retrying",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
                nextDelay = min(nextDelay + nextDelay, .seconds(30))
            }
        }
    }

    private func retryCompletion(id: UUID, completion: PendingCompletion) async {
        var nextDelay = retryDelay
        while pendingCompletions[id] != nil, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
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
                nextDelay = min(nextDelay + nextDelay, .seconds(30))
            }
        }
    }

    private func fail(id: UUID, reason: String) async throws {
        _ = try await persistence.fail(id: id, reason: reason)
    }
}

extension Application {
    private struct VMCommandExecutionServiceKey: StorageKey, LockKey {
        typealias Value = VMCommandExecutionService
    }

    var vmCommandExecutionService: VMCommandExecutionService {
        get {
            guard let service = storage[VMCommandExecutionServiceKey.self] else {
                preconditionFailure("VM command execution service has not been configured")
            }
            return service
        }
        set { setStorageValue(VMCommandExecutionServiceKey.self, to: newValue) }
    }
}

extension Request {
    var vmCommandExecutionService: VMCommandExecutionService {
        application.vmCommandExecutionService
    }
}
