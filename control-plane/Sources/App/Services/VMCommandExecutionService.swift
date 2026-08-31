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
    static let aggregateOutputLimitBytes = 16 * outputLimitBytes
    static let maxBufferedExecutions = 64
    static let maxDiscardedExecutions = 64
    static let completionBudget: TimeInterval = 300
    static let timeoutReason = "Command execution timed out"

    struct BufferStats: Sendable {
        let states: Int
        let discardedStates: Int
        let capturedBytes: Int
        let stateShedTotal: Int
        let outputShedTotal: Int
    }

    private struct CaptureKey: Hashable, Sendable {
        let executionID: UUID
        let agentKey: String
    }

    private struct Capture {
        let agentKey: String
        var deadline: Date?
        var stdout = Data()
        var stderr = Data()
        var truncated = false

        mutating func append(
            _ data: Data,
            stream: String,
            aggregateRemaining: Int
        ) -> Int {
            let remaining = min(
                max(0, VMCommandExecutionService.outputLimitBytes - stdout.count - stderr.count),
                max(0, aggregateRemaining))
            if data.count > remaining { truncated = true }
            guard remaining > 0 else { return 0 }
            let accepted = data.prefix(remaining)
            if stream == "stderr" {
                stderr.append(contentsOf: accepted)
            } else {
                stdout.append(contentsOf: accepted)
            }
            return accepted.count
        }
    }

    private struct PendingCompletion {
        let capture: Capture
        let exitCode: Int
    }

    private struct TimestampedClaim: Decodable {
        let id: UUID
        let completedAt: Date
        enum CodingKeys: String, CodingKey {
            case id
            case completedAt = "completed_at"
        }
    }
    private struct CompletionCandidate: Decodable {
        let status: String
        let timedOutBySweeper: Bool
        enum CodingKeys: String, CodingKey {
            case status
            case timedOutBySweeper = "timed_out_by_sweeper"
        }
    }
    private struct TimedOut: Decodable {
        let id: UUID
        let agentKey: String
        let completedAt: Date
        enum CodingKeys: String, CodingKey {
            case id
            case agentKey = "agent_key"
            case completedAt = "completed_at"
        }
    }

    private struct CompletedTransition: Sendable {
        let context: VMGuestExecutionAuditContext
        let correctsTimeout: Bool
        let timestamp: Date
    }

    private struct TimedOutTransition: Sendable {
        let id: UUID
        let agentKey: String
        let context: VMGuestExecutionAuditContext
        let timestamp: Date
    }

    private struct FailedTransition: Sendable {
        let context: VMGuestExecutionAuditContext
        let timestamp: Date
    }

    private let app: Application
    private let sendEnvelope: @Sendable (MessageEnvelope, String) async throws -> Void
    private let beforeClassifyStart: (@Sendable () async throws -> Void)?
    private let beforePersistResult: (@Sendable () async throws -> Void)?
    private let afterTimeoutCommitBeforeAudit: (@Sendable () async -> Void)?
    private let retryDelay: Duration
    private var captures: [CaptureKey: Capture] = [:]
    private var pendingCompletions: [CaptureKey: PendingCompletion] = [:]
    private var discardedCaptures: Set<CaptureKey> = []
    private var discardedCaptureOrder: [CaptureKey] = []
    private var stateShedTotal = 0
    private var outputShedTotal = 0

    init(
        app: Application,
        sendEnvelope: (@Sendable (MessageEnvelope, String) async throws -> Void)? = nil,
        beforeClassifyStart: (@Sendable () async throws -> Void)? = nil,
        beforePersistResult: (@Sendable () async throws -> Void)? = nil,
        afterTimeoutCommitBeforeAudit: (@Sendable () async -> Void)? = nil,
        retryDelay: Duration = .seconds(1)
    ) {
        self.app = app
        self.beforeClassifyStart = beforeClassifyStart
        self.beforePersistResult = beforePersistResult
        self.afterTimeoutCommitBeforeAudit = afterTimeoutCommitBeforeAudit
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
        let key = CaptureKey(executionID: id, agentKey: agentKey)
        if captures[key] != nil { return true }
        if pendingCompletions[key] != nil { return true }
        if discardedCaptures.contains(key) { return true }
        do {
            guard let execution = try await recordedExecution(id: id, agentKey: agentKey) else {
                return false
            }

            guard execution.status == .pending else {
                await closeTimedOutSession(sessionId: sessionId, agentKey: agentKey)
                return true
            }
            guard hasBufferedStateCapacity else {
                recordStateShedding(key: key, reason: "recorded start capacity exhausted")
                rememberDiscardedCapture(key)
                await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
                return true
            }
            captures[key] = Self.capture(for: execution)
            await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
            return true
        } catch {
            // The process has already started, so falling through would lose
            // all later frames. Install an output-bounded provisional capture
            // while the durable classification is retried.
            let retained = hasBufferedStateCapacity
            if retained {
                captures[key] = Capture(
                    agentKey: agentKey,
                    deadline: Date().addingTimeInterval(Self.completionBudget))
            } else {
                recordStateShedding(key: key, reason: "provisional start capacity exhausted")
                rememberDiscardedCapture(key)
            }
            app.logger.warning(
                retained
                    ? "Could not classify started VM command; retrying"
                    : "Could not classify started VM command; capture shed",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "strato.agent.identity": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
            if retained {
                Task { [weak self] in
                    await self?.retryStartClassification(id: id, agentKey: agentKey)
                }
            }
            await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
            return true
        }
    }

    func handleOutput(
        sessionId: String, fromAgentKey agentKey: String, stream: String, data: Data
    ) -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        let key = CaptureKey(executionID: id, agentKey: agentKey)
        guard var capture = captures[key] else {
            return discardedCaptures.contains(key)
        }
        guard stream == "stdout" || stream == "stderr" else {
            capture.truncated = true
            captures[key] = capture
            return true
        }
        let aggregateRemaining = Self.aggregateOutputLimitBytes - liveCapturedByteCount
        let accepted = capture.append(
            data,
            stream: stream,
            aggregateRemaining: aggregateRemaining)
        captures[key] = capture
        if accepted < data.count {
            recordOutputShedding(key: key, droppedBytes: data.count - accepted)
        }
        return true
    }

    func handleExit(
        sessionId: String,
        fromAgentKey agentKey: String,
        exitCode: Int
    ) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        guard app.guestExecSessionManager.getSession(sessionId: sessionId) == nil else {
            return false
        }
        let key = CaptureKey(executionID: id, agentKey: agentKey)
        if pendingCompletions[key] != nil { return true }
        let wasDiscarding = forgetDiscardedCapture(key)
        let captured = captures.removeValue(forKey: key)
        let capture = captured ?? Self.compactCapture(agentKey: agentKey)
        let completion = PendingCompletion(capture: capture, exitCode: exitCode)
        let retainedForRetry = captured != nil || hasBufferedStateCapacity
        if retainedForRetry {
            pendingCompletions[key] = completion
        } else {
            recordStateShedding(key: key, reason: "late-exit retry capacity exhausted")
        }
        do {
            let claimed = try await complete(
                id: id, capture: capture, fromAgentKey: agentKey, exitCode: exitCode)
            if retainedForRetry {
                pendingCompletions.removeValue(forKey: key)
            }
            return wasDiscarding || captured != nil || claimed || !retainedForRetry
        } catch {
            app.logger.warning(
                "Could not persist completed VM command; retrying",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "error": .string(error.localizedDescription),
                ])
            if retainedForRetry {
                Task { [weak self] in
                    await self?.retryCompletion(key: key)
                }
            } else {
                app.logger.warning(
                    "Shed VM command completion retry after persistence failure",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return true
        }
    }

    func handleClosed(
        sessionId: String, fromAgentKey agentKey: String, reason: String?
    ) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        let key = CaptureKey(executionID: id, agentKey: agentKey)
        // An exit frame already owns the terminal transition while its result
        // is being retried. Consume a same-agent duplicate close without
        // allowing it to replace the real exit with a generic failure.
        if pendingCompletions[key] != nil { return true }
        let wasDiscarding = forgetDiscardedCapture(key)
        if captures.removeValue(forKey: key) == nil, !wasDiscarding {
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
                id: id,
                reason: reason ?? "Guest command session closed without an exit code",
                expectedAgentKey: agentKey)
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
        // Another replica may own the database timeout claim while this one
        // owns the socket capture. Every replica therefore sheds its own
        // expired bytes before attempting the shared durable transition.
        shedExpiredCapturedOutput(now: now)
        do {
            let transitions: [TimedOutTransition] = try await app.db.transaction { db in
                guard let sql = db as? any SQLDatabase else {
                    throw Abort(.internalServerError)
                }
                let timedOut = try await sql.raw(
                    """
                    UPDATE vm_command_executions
                    SET status = 'failed',
                        error = \(bind: Self.timeoutReason),
                        timed_out_by_sweeper = TRUE,
                        completed_at = clock_timestamp()
                    WHERE status = 'pending' AND deadline <= \(bind: now)
                    RETURNING id, agent_key, completed_at
                    """
                ).all(decoding: TimedOut.self)
                var transitions: [TimedOutTransition] = []
                transitions.reserveCapacity(timedOut.count)
                for execution in timedOut {
                    transitions.append(
                        TimedOutTransition(
                            id: execution.id,
                            agentKey: execution.agentKey,
                            context: try await Self.auditContext(id: execution.id, on: db),
                            timestamp: execution.completedAt))
                }
                return transitions
            }
            if !transitions.isEmpty {
                await afterTimeoutCommitBeforeAudit?()
            }
            for transition in transitions {
                shedCapturedOutput(for: transition.id)
                // Append the timeout fact before sending a close frame. The
                // send suspends and may immediately provoke an exit frame;
                // recording first preserves timeout-before-correction order.
                let auditRecord = VMGuestExecutionAudit.makeCommandCompletedRecord(
                    transition.context,
                    outcome: .timedOut,
                    reason: Self.timeoutReason,
                    timestamp: transition.timestamp)
                await app.audit.recordFailOpen(auditRecord)
                try? await sendEnvelope(
                    MessageEnvelope(
                        message: GuestExecCloseMessage(
                            sessionId: transition.context.correlationID,
                            reason: Self.timeoutReason)),
                    transition.agentKey)
            }
        } catch {
            app.logger.error("Stuck VM command sweep failed: \(error)")
        }
    }

    private func complete(
        id: UUID,
        capture: Capture,
        fromAgentKey agentKey: String,
        exitCode: Int
    ) async throws -> Bool {
        try await beforePersistResult?()
        let transition: CompletedTransition? = try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            guard
                let candidate = try await sql.raw(
                    """
                    SELECT status, timed_out_by_sweeper
                    FROM vm_command_executions
                    WHERE id = \(bind: id) AND agent_key = \(bind: agentKey)
                    FOR UPDATE
                    """
                ).first(decoding: CompletionCandidate.self),
                candidate.status == "pending"
                    || (candidate.status == "failed" && candidate.timedOutBySweeper)
            else { return nil }

            let claimed = try await sql.raw(
                """
                UPDATE vm_command_executions
                SET status = 'succeeded', error = NULL, completed_at = clock_timestamp()
                WHERE id = \(bind: id)
                  AND agent_key = \(bind: agentKey)
                  AND (
                    status = 'pending'
                    OR (status = 'failed' AND timed_out_by_sweeper = TRUE)
                  )
                RETURNING id, completed_at
                """
            ).all(decoding: TimestampedClaim.self)
            guard let claim = claimed.first else { return nil }
            guard let payload = try await VMCommandPayload.find(id, on: db) else {
                throw Abort(.internalServerError, reason: "VM command payload is missing")
            }
            let resultCapture =
                candidate.status == "failed" ? Self.compactCapture(agentKey: agentKey) : capture
            payload.recordResult(
                stdout: resultCapture.stdout, stderr: resultCapture.stderr,
                exitCode: exitCode, truncated: resultCapture.truncated)
            try await payload.update(on: db)
            return CompletedTransition(
                context: try await Self.auditContext(id: id, on: db),
                correctsTimeout: candidate.timedOutBySweeper,
                timestamp: claim.completedAt)
        }
        guard let transition else { return false }
        let auditRecord = VMGuestExecutionAudit.makeCommandCompletedRecord(
            transition.context,
            outcome: .exited,
            exitCode: exitCode,
            correctsOutcome: transition.correctsTimeout ? .timedOut : nil,
            timestamp: transition.timestamp)
        await app.audit.recordFailOpen(auditRecord)
        return true
    }

    private func recordedExecution(
        id: UUID,
        agentKey: String
    ) async throws -> VMCommandExecution? {
        try await beforeClassifyStart?()
        return try await VMCommandExecution.query(on: app.db)
            .filter(\.$id == id)
            .filter(\.$agentKey == agentKey)
            .group(.or) { eligible in
                eligible.filter(\.$status == .pending)
                eligible.group(.and) { timedOut in
                    timedOut.filter(\.$status == .failed)
                    timedOut.filter(\.$timedOutBySweeper == true)
                }
            }
            .first()
    }

    private static func capture(for execution: VMCommandExecution) -> Capture {
        Capture(agentKey: execution.agentKey, deadline: execution.deadline)
    }

    private static func compactCapture(agentKey: String) -> Capture {
        var capture = Capture(agentKey: agentKey, deadline: nil)
        capture.truncated = true
        return capture
    }

    private func shedExpiredCapturedOutput(now: Date) {
        for key in Array(captures.keys) {
            guard let deadline = captures[key]?.deadline, deadline <= now else { continue }
            captures.removeValue(forKey: key)
        }
        for key in Array(pendingCompletions.keys) {
            guard let pending = pendingCompletions[key], let deadline = pending.capture.deadline,
                deadline <= now
            else { continue }
            pendingCompletions[key] = PendingCompletion(
                capture: Self.compactCapture(agentKey: key.agentKey),
                exitCode: pending.exitCode)
        }
    }

    private func shedCapturedOutput(for id: UUID) {
        captures = captures.filter { $0.key.executionID != id }
        for key in Array(pendingCompletions.keys) where key.executionID == id {
            guard let pending = pendingCompletions[key] else { continue }
            pendingCompletions[key] = PendingCompletion(
                capture: Self.compactCapture(agentKey: key.agentKey),
                exitCode: pending.exitCode)
        }
    }

    private var hasBufferedStateCapacity: Bool {
        captures.count + pendingCompletions.count < Self.maxBufferedExecutions
    }

    private var liveCapturedByteCount: Int {
        captures.values.reduce(into: 0) { total, capture in
            total += capture.stdout.count + capture.stderr.count
        }
            + pendingCompletions.values.reduce(into: 0) { total, completion in
                total += completion.capture.stdout.count + completion.capture.stderr.count
            }
    }

    func bufferStats() -> BufferStats {
        BufferStats(
            states: captures.count + pendingCompletions.count,
            discardedStates: discardedCaptures.count,
            capturedBytes: liveCapturedByteCount,
            stateShedTotal: stateShedTotal,
            outputShedTotal: outputShedTotal)
    }

    private func rememberDiscardedCapture(_ key: CaptureKey) {
        guard discardedCaptures.insert(key).inserted else { return }
        discardedCaptureOrder.append(key)
        if discardedCaptureOrder.count > Self.maxDiscardedExecutions {
            let evicted = discardedCaptureOrder.removeFirst()
            discardedCaptures.remove(evicted)
            app.logger.warning(
                "Evicted VM command discard marker under backpressure",
                metadata: [
                    "executionId": .string(evicted.executionID.uuidString),
                    "agentKey": .string(evicted.agentKey),
                    "maxDiscardedExecutions": .stringConvertible(Self.maxDiscardedExecutions),
                ])
        }
    }

    @discardableResult
    private func forgetDiscardedCapture(_ key: CaptureKey) -> Bool {
        guard discardedCaptures.remove(key) != nil else { return false }
        discardedCaptureOrder.removeAll { $0 == key }
        return true
    }

    private func recordStateShedding(key: CaptureKey, reason: String) {
        stateShedTotal += 1
        guard stateShedTotal == 1 || stateShedTotal.isMultiple(of: 100) else { return }
        app.logger.warning(
            "VM command capture state shed under backpressure",
            metadata: [
                "executionId": .string(key.executionID.uuidString),
                "agentKey": .string(key.agentKey),
                "reason": .string(reason),
                "shedTotal": .stringConvertible(stateShedTotal),
                "maxBufferedExecutions": .stringConvertible(Self.maxBufferedExecutions),
            ])
    }

    private func recordOutputShedding(key: CaptureKey, droppedBytes: Int) {
        outputShedTotal += 1
        guard outputShedTotal == 1 || outputShedTotal.isMultiple(of: 100) else { return }
        app.logger.warning(
            "VM command captured output shed under backpressure",
            metadata: [
                "executionId": .string(key.executionID.uuidString),
                "agentKey": .string(key.agentKey),
                "droppedBytes": .stringConvertible(droppedBytes),
                "shedTotal": .stringConvertible(outputShedTotal),
                "aggregateLimitBytes": .stringConvertible(Self.aggregateOutputLimitBytes),
            ])
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
                    "strato.agent.identity": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func closeTimedOutSession(sessionId: String, agentKey: String) async {
        do {
            try await sendEnvelope(
                MessageEnvelope(
                    message: GuestExecCloseMessage(
                        sessionId: sessionId, reason: Self.timeoutReason)),
                agentKey)
        } catch {
            app.logger.warning(
                "Could not redeliver timed-out VM command close",
                metadata: [
                    "executionId": .string(sessionId),
                    "agentKey": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func retryStartClassification(id: UUID, agentKey: String) async {
        let key = CaptureKey(executionID: id, agentKey: agentKey)
        var nextDelay = retryDelay
        while captures[key] != nil, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
            guard captures[key] != nil, !app.didShutdown else {
                return
            }
            do {
                guard let execution = try await recordedExecution(id: id, agentKey: agentKey) else {
                    captures.removeValue(forKey: key)
                    return
                }
                // The database query suspends this actor. A terminal frame may
                // have moved the capture into pending completion meanwhile;
                // never resurrect it after that transition.
                guard captures[key] != nil else { return }
                guard execution.status == .pending else {
                    captures.removeValue(forKey: key)
                    await closeTimedOutSession(sessionId: id.uuidString, agentKey: agentKey)
                    return
                }
                captures[key]?.deadline = execution.deadline
                return
            } catch {
                app.logger.warning(
                    "Could not classify started VM command; retrying",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "strato.agent.identity": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
                nextDelay = min(nextDelay + nextDelay, .seconds(30))
            }
        }
    }

    private func retryCompletion(key: CaptureKey) async {
        var nextDelay = retryDelay
        while pendingCompletions[key] != nil, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
            guard let completion = pendingCompletions[key], !app.didShutdown else { return }
            do {
                _ = try await complete(
                    id: key.executionID,
                    capture: completion.capture,
                    fromAgentKey: key.agentKey,
                    exitCode: completion.exitCode)
                pendingCompletions.removeValue(forKey: key)
                return
            } catch {
                app.logger.warning(
                    "Could not persist completed VM command; retrying",
                    metadata: [
                        "executionId": .string(key.executionID.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
                nextDelay = min(nextDelay + nextDelay, .seconds(30))
            }
        }
    }

    private func fail(
        id: UUID,
        reason: String,
        expectedAgentKey: String? = nil
    ) async throws {
        var storedReasonScalars = String.UnicodeScalarView()
        storedReasonScalars.reserveCapacity(Validate.textLength)
        for scalar in reason.unicodeScalars.prefix(Validate.textLength) {
            storedReasonScalars.append(scalar)
        }
        let storedReason = String(storedReasonScalars)
        let transition: FailedTransition? = try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            let claimed: [TimestampedClaim]
            if let expectedAgentKey {
                claimed = try await sql.raw(
                    """
                    UPDATE vm_command_executions
                    SET status = 'failed', error = \(bind: storedReason), completed_at = clock_timestamp()
                    WHERE id = \(bind: id)
                      AND status = 'pending'
                      AND agent_key = \(bind: expectedAgentKey)
                    RETURNING id, completed_at
                    """
                ).all(decoding: TimestampedClaim.self)
            } else {
                claimed = try await sql.raw(
                    """
                    UPDATE vm_command_executions
                    SET status = 'failed', error = \(bind: storedReason), completed_at = clock_timestamp()
                    WHERE id = \(bind: id) AND status = 'pending'
                    RETURNING id, completed_at
                    """
                ).all(decoding: TimestampedClaim.self)
            }
            guard let claim = claimed.first else { return nil }
            return FailedTransition(
                context: try await Self.auditContext(id: id, on: db),
                timestamp: claim.completedAt)
        }
        guard let transition else { return }
        let auditRecord = VMGuestExecutionAudit.makeCommandCompletedRecord(
            transition.context,
            outcome: .failed,
            reason: reason,
            timestamp: transition.timestamp)
        await app.audit.recordFailOpen(auditRecord)
    }

    private static func auditContext(
        id: UUID,
        on db: any Database
    ) async throws -> VMGuestExecutionAuditContext {
        guard let execution = try await VMCommandExecution.find(id, on: db) else {
            throw Abort(.internalServerError, reason: "VM command execution is missing")
        }
        guard let payload = try await VMCommandPayload.find(id, on: db) else {
            throw Abort(.internalServerError, reason: "VM command payload is missing")
        }
        return VMGuestExecutionAuditContext(
            vmID: execution.vmID,
            organizationID: execution.organizationID,
            userID: execution.actorID,
            username: execution.actorUsername,
            apiKeyID: execution.apiKeyID,
            sourceIP: execution.sourceIP,
            adminBypass: execution.adminBypass,
            correlationID: id.uuidString,
            argv: payload.command)
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
