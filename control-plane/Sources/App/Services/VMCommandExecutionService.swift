import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Owns the live capture window for durable, non-interactive VM commands.
/// PostgreSQL owns status; this actor owns bounded bytes from
/// `guest_exec_started` until the terminal result is durably committed.
actor VMCommandExecutionService {
    static let outputLimitBytes = GuestExecRecordedStateMessage.outputLimitBytes
    static let completionBudget: TimeInterval = 300
    private static let timeoutReason = "Command execution timed out"

    private enum PayloadRevisionPolicy {
        case authoritative(Int64)
        case legacy(expectedRevision: Int64?)

        var authoritativeRevision: Int64? {
            guard case .authoritative(let revision) = self else { return nil }
            return revision
        }
    }

    private struct Capture {
        let agentKey: String
        var deadline: Date
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        /// Highest full agent snapshot represented by these bytes, used to
        /// reject delayed local running frames.
        var authoritativeRevision: Int64? = nil
        /// Database compare-and-write rule for the next persistence attempt.
        /// Legacy deltas retain the revision they were based on but never
        /// claim to be a newer authoritative snapshot.
        var revisionPolicy: PayloadRevisionPolicy = .legacy(expectedRevision: nil)
        /// True when these bytes already include (or authoritatively replace)
        /// any result currently stored in `vm_command_payloads`.
        var replacesPersistedResult = false
        /// Actor-local ABA guard. Every dictionary write receives a new token,
        /// so a sweep cannot evict a capture that changed while it awaited I/O.
        var mutationToken: UInt64 = 0

        mutating func prepareForLegacyFrame() {
            if case .authoritative(let revision) = revisionPolicy {
                revisionPolicy = .legacy(expectedRevision: revision)
            }
        }

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

    private enum PersistenceOutcome: Equatable {
        case persisted
        case duplicate
        case discarded
    }

    private struct StalePayloadWrite: Error {}

    private enum RunningClassification {
        case pending(deadline: Date, acceptsSnapshot: Bool)
        case terminal
        case unknown
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
    private let beforeClassifyStart: (@Sendable () async throws -> Void)?
    private let beforePersistResult: (@Sendable () async throws -> Void)?
    private let beforeSweepPersistence: (@Sendable () async throws -> Void)?
    private let retryDelay: Duration
    private var captures: [UUID: Capture] = [:]
    private var pendingCompletions: [UUID: PendingCompletion] = [:]
    private var nextCaptureMutationToken: UInt64 = 0

    init(
        app: Application,
        sendEnvelope: (@Sendable (MessageEnvelope, String) async throws -> Void)? = nil,
        beforeClassifyStart: (@Sendable () async throws -> Void)? = nil,
        beforePersistResult: (@Sendable () async throws -> Void)? = nil,
        beforeSweepPersistence: (@Sendable () async throws -> Void)? = nil,
        retryDelay: Duration = .seconds(1)
    ) {
        self.app = app
        self.beforeClassifyStart = beforeClassifyStart
        self.beforePersistResult = beforePersistResult
        self.beforeSweepPersistence = beforeSweepPersistence
        self.retryDelay = retryDelay
        self.sendEnvelope =
            sendEnvelope ?? { [weak app] envelope, agentKey in
                guard let app else { throw CancellationError() }
                try await app.replicaBridge.deliver(envelope, agentKey: agentKey)
            }
    }

    private func storeCapture(_ unstampedCapture: Capture, id: UUID) {
        var capture = unstampedCapture
        nextCaptureMutationToken &+= 1
        capture.mutationToken = nextCaptureMutationToken
        captures[id] = capture
    }

    @discardableResult
    private func storeNewerAuthoritativeCapture(_ capture: Capture, id: UUID) -> Bool {
        guard let revision = capture.authoritativeRevision else { return false }
        if let currentRevision = captures[id]?.authoritativeRevision,
            currentRevision >= revision
        {
            return false
        }
        storeCapture(capture, id: id)
        return true
    }

    private func removeCaptureUnlessNewer(id: UUID, than revision: Int64) {
        guard let currentRevision = captures[id]?.authoritativeRevision,
            currentRevision > revision
        else {
            captures.removeValue(forKey: id)
            return
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

            storeCapture(
                Capture(agentKey: execution.agentKey, deadline: execution.deadline), id: id)
            await closeStdin(sessionId: sessionId, id: id, agentKey: agentKey)
            return true
        } catch {
            // The process has already started, so falling through would lose
            // all later frames. Install a bounded provisional capture while
            // the durable classification is retried.
            storeCapture(
                Capture(
                    agentKey: agentKey,
                    deadline: Date().addingTimeInterval(Self.completionBudget)),
                id: id)
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
    ) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        guard app.guestExecSessionManager.getSession(sessionId: sessionId) == nil else {
            return false
        }

        var capture: Capture
        if let existing = captures[id] {
            guard existing.agentKey == agentKey else { return false }
            capture = existing
        } else if let completion = pendingCompletions[id] {
            return completion.capture.agentKey == agentKey
        } else {
            do {
                guard
                    let execution = try await recordedExecution(
                        id: id, agentKey: agentKey, acceptingSweptFailure: true)
                else { return false }
                capture = try await restoredCapture(id: id, execution: execution)
            } catch {
                // A database outage must not turn a potentially recorded frame
                // into an interactive one and discard it. Keep at most the
                // normal one-MiB capture while ownership is retried. Every
                // terminal database claim still includes agent_key, so this
                // provisional classification cannot complete another agent's
                // command.
                capture = Capture(
                    agentKey: agentKey,
                    deadline: Date().addingTimeInterval(Self.completionBudget))
                app.logger.warning(
                    "Could not classify VM command output; retrying",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
                Task { [weak self] in
                    await self?.retryClassification(
                        id: id, agentKey: agentKey, acceptingSweptFailure: true)
                }
            }
        }
        capture.prepareForLegacyFrame()
        guard stream == "stdout" || stream == "stderr" else {
            capture.truncated = true
            storeCapture(capture, id: id)
            return true
        }
        capture.append(data, stream: stream)
        storeCapture(capture, id: id)
        return true
    }

    func handleExit(sessionId: String, fromAgentKey agentKey: String, exitCode: Int) async -> Bool {
        guard let id = UUID(uuidString: sessionId) else { return false }
        guard app.guestExecSessionManager.getSession(sessionId: sessionId) == nil else {
            return false
        }

        var capture: Capture
        if let existing = captures[id] {
            guard existing.agentKey == agentKey else { return false }
            capture = existing
        } else if let completion = pendingCompletions[id] {
            return completion.capture.agentKey == agentKey
        } else {
            do {
                guard
                    let execution = try await recordedExecution(
                        id: id, agentKey: agentKey, acceptingSweptFailure: true)
                else { return false }
                capture = try await restoredCapture(id: id, execution: execution)
            } catch {
                capture = Capture(
                    agentKey: agentKey,
                    deadline: Date().addingTimeInterval(Self.completionBudget))
                app.logger.warning(
                    "Could not classify VM command exit; retaining it provisionally",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
        capture.prepareForLegacyFrame()
        captures.removeValue(forKey: id)
        let completion = PendingCompletion(capture: capture, exitCode: exitCode)
        pendingCompletions[id] = completion
        do {
            _ = try await complete(id: id, capture: capture, exitCode: exitCode)
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
        guard app.guestExecSessionManager.getSession(sessionId: sessionId) == nil else {
            return false
        }
        let hadCapture = captures[id] != nil
        var capture =
            captures[id]
            ?? Capture(
                agentKey: agentKey,
                deadline: Date().addingTimeInterval(Self.completionBudget))
        guard capture.agentKey == agentKey else { return false }
        capture.prepareForLegacyFrame()
        capture.truncated = true

        do {
            let outcome = try await persistClosed(
                id: id,
                capture: capture,
                reason: reason ?? "Guest command session closed without an exit code")
            switch outcome {
            case .persisted, .duplicate:
                captures.removeValue(forKey: id)
                pendingCompletions.removeValue(forKey: id)
                return true
            case .discarded:
                if hadCapture { captures.removeValue(forKey: id) }
                return hadCapture
            }
        } catch {
            app.logger.error("Could not fail closed recorded VM command: \(error)")
            // A known recorded capture must not fall through to the
            // interactive manager. Retain it so the deadline sweep gets
            // another opportunity to persist the partial bytes.
            return hadCapture
        }
    }

    /// Apply the agent's level-triggered, authoritative snapshot for a
    /// recorded command. Terminal states are acknowledged only after their
    /// result transaction commits, after the same agent's row proves the
    /// result was already terminal, or after a successful database lookup
    /// proves the snapshot is stale and can be deliberately discarded. A
    /// failed database operation leaves the agent holding it for replay.
    func handleRecordedState(
        _ message: GuestExecRecordedStateMessage, fromAgentKey agentKey: String
    ) async -> Bool {
        guard let id = UUID(uuidString: message.sessionId) else { return false }
        guard app.guestExecSessionManager.getSession(sessionId: message.sessionId) == nil else {
            return false
        }
        guard var capture = capture(from: message, agentKey: agentKey) else {
            app.logger.warning(
                "Received malformed recorded VM command state",
                metadata: [
                    "executionId": .string(message.sessionId),
                    "agentKey": .string(agentKey),
                    "status": .string(message.status.rawValue),
                ])
            // The agent cannot repair an invariant violation in an immutable
            // terminal snapshot. Convert it into an explicit, truncated
            // failure so ACK still means the sole retained terminal evidence
            // reached a durable verdict. Unknown or differently owned rows are
            // deliberately discarded by the same ownership-checked claim. A
            // database failure receives no ACK and is retried by the agent.
            guard message.status.isTerminal else {
                await closeRecordedSession(
                    id: id, agentKey: agentKey,
                    reason: "recorded command reported malformed running state")
                return true
            }
            var malformedCapture = Capture(
                agentKey: agentKey,
                deadline: Date().addingTimeInterval(Self.completionBudget))
            guard message.revision >= 0 else {
                app.logger.warning(
                    "Retaining malformed recorded VM command terminal state with a negative revision",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "revision": .stringConvertible(message.revision),
                    ])
                return true
            }
            malformedCapture.authoritativeRevision = message.revision
            malformedCapture.revisionPolicy = .authoritative(message.revision)
            malformedCapture.truncated = true
            do {
                let outcome = try await persistClosed(
                    id: id,
                    capture: malformedCapture,
                    reason:
                        "Recorded guest command reported a malformed terminal state; the command may have partially run"
                )
                if outcome == .discarded {
                    app.logger.warning(
                        "Discarded malformed recorded VM command terminal state for an unknown or differently owned execution",
                        metadata: [
                            "executionId": .string(id.uuidString),
                            "agentKey": .string(agentKey),
                        ])
                }
                removeCaptureUnlessNewer(id: id, than: message.revision)
                pendingCompletions.removeValue(forKey: id)
                await acknowledgeRecordedSession(id: id, agentKey: agentKey)
            } catch {
                app.logger.warning(
                    "Could not persist malformed recorded VM command terminal state; awaiting replay",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return true
        }

        switch message.status {
        case .running:
            do {
                switch try await classifyRunningSnapshot(
                    id: id, agentKey: agentKey, capture: capture)
                {
                case .unknown:
                    removeCaptureUnlessNewer(id: id, than: message.revision)
                    await closeRecordedSession(
                        id: id, agentKey: agentKey,
                        reason: "recorded command is unknown to the control plane")
                    return true
                case .terminal:
                    removeCaptureUnlessNewer(id: id, than: message.revision)
                    await closeRecordedSession(
                        id: id, agentKey: agentKey,
                        reason: "recorded command is already terminal")
                    return true
                case .pending(let deadline, let acceptsSnapshot):
                    guard acceptsSnapshot else { return true }
                    capture.deadline = deadline
                    storeNewerAuthoritativeCapture(capture, id: id)
                }
            } catch {
                let stored = storeNewerAuthoritativeCapture(capture, id: id)
                app.logger.warning(
                    "Could not classify running recorded VM command; retrying",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
                if stored {
                    Task { [weak self] in
                        await self?.retryRunningClassification(id: id, agentKey: agentKey)
                    }
                }
            }
            return true

        case .exited:
            guard let exitCode = message.exitCode else { return true }
            do {
                let outcome = try await complete(
                    id: id, capture: capture, exitCode: exitCode)
                if outcome == .discarded {
                    app.logger.warning(
                        "Discarded recorded VM command exit for an unknown or differently owned execution",
                        metadata: [
                            "executionId": .string(id.uuidString),
                            "agentKey": .string(agentKey),
                        ])
                }
                removeCaptureUnlessNewer(id: id, than: message.revision)
                pendingCompletions.removeValue(forKey: id)
                await acknowledgeRecordedSession(id: id, agentKey: agentKey)
            } catch {
                app.logger.warning(
                    "Could not persist recorded VM command exit; awaiting replay",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return true

        case .closed:
            capture.truncated = true
            do {
                let outcome = try await persistClosed(
                    id: id, capture: capture,
                    reason: message.reason ?? "Guest command session closed without an exit code")
                if outcome == .discarded {
                    app.logger.warning(
                        "Discarded recorded VM command close for an unknown or differently owned execution",
                        metadata: [
                            "executionId": .string(id.uuidString),
                            "agentKey": .string(agentKey),
                        ])
                }
                removeCaptureUnlessNewer(id: id, than: message.revision)
                pendingCompletions.removeValue(forKey: id)
                await acknowledgeRecordedSession(id: id, agentKey: agentKey)
            } catch {
                app.logger.warning(
                    "Could not persist closed recorded VM command; awaiting replay",
                    metadata: [
                        "executionId": .string(id.uuidString),
                        "agentKey": .string(agentKey),
                        "error": .string(error.localizedDescription),
                    ])
            }
            return true
        }
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
        let expiredCaptures = captures.filter { $0.value.deadline <= now }
        guard app.db is any SQLDatabase else { return }
        do {
            try await beforeSweepPersistence?()
            let (timedOut, payloadWrites) = try await app.db.transaction { db in
                guard let sql = db as? any SQLDatabase else {
                    throw Abort(.internalServerError)
                }
                let timedOut = try await sql.raw(
                    """
                    UPDATE vm_command_executions
                    SET status = 'failed', error = \(bind: Self.timeoutReason), completed_at = \(bind: now)
                    WHERE status = 'pending' AND deadline <= \(bind: now)
                    RETURNING id, agent_key
                    """
                ).all(decoding: TimedOut.self)
                let newlyTimedOut = Dictionary(
                    uniqueKeysWithValues: timedOut.map { ($0.id, $0.agentKey) })
                var payloadWrites: Set<UUID> = []
                for (id, originalCapture) in expiredCaptures {
                    var capture = originalCapture
                    let ownsTimedOutRow: Bool
                    if let timedOutAgentKey = newlyTimedOut[id] {
                        ownsTimedOutRow = timedOutAgentKey == capture.agentKey
                    } else {
                        let execution = try await VMCommandExecution.query(on: db)
                            .filter(\.$id == id)
                            .filter(\.$agentKey == capture.agentKey)
                            .first()
                        ownsTimedOutRow =
                            execution?.status == .failed
                            && execution?.error == Self.timeoutReason
                    }
                    guard ownsTimedOutRow else { continue }
                    capture.truncated = true
                    if try await self.recordPayload(
                        id: id, capture: capture, exitCode: nil, on: db)
                    {
                        payloadWrites.insert(id)
                    }
                }
                return (timedOut, payloadWrites)
            }

            // Also bound actor-local memory if a database state transition
            // raced a suspended classification query and therefore did not
            // return this id from the conditional update above. Wait until the
            // transaction commits so every newly timed-out capture is flushed
            // before eviction.
            for (id, expiredCapture) in expiredCaptures {
                guard var current = captures[id] else { continue }
                if current.mutationToken == expiredCapture.mutationToken {
                    captures.removeValue(forKey: id)
                } else if payloadWrites.contains(id) {
                    // The current capture is the same full prefix plus a
                    // mutation accepted while the sweep was suspended. Mark
                    // it as replacing the just-persisted stale snapshot so a
                    // late legacy exit cannot append that prefix twice.
                    current.replacesPersistedResult = true
                    storeCapture(current, id: id)
                }
            }
            for execution in timedOut {
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

    private func complete(
        id: UUID, capture: Capture, exitCode: Int
    ) async throws -> PersistenceOutcome {
        try await beforePersistResult?()
        do {
            return try await app.db.transaction { db in
                guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
                let claimed: [Claimed]
                switch capture.revisionPolicy {
                case .authoritative:
                    // A newer authoritative terminal snapshot may correct a
                    // result a legacy fallback already marked succeeded.
                    claimed = try await sql.raw(
                        """
                        UPDATE vm_command_executions
                        SET status = 'succeeded', error = NULL, completed_at = now()
                        WHERE id = \(bind: id)
                          AND agent_key = \(bind: capture.agentKey)
                          AND status IN ('pending', 'failed', 'succeeded')
                        RETURNING id
                        """
                    ).all(decoding: Claimed.self)
                case .legacy:
                    claimed = try await sql.raw(
                        """
                        UPDATE vm_command_executions
                        SET status = 'succeeded', error = NULL, completed_at = now()
                        WHERE id = \(bind: id)
                          AND agent_key = \(bind: capture.agentKey)
                          AND status IN ('pending', 'failed')
                        RETURNING id
                        """
                    ).all(decoding: Claimed.self)
                }
                if !claimed.isEmpty {
                    guard
                        try await self.recordPayload(
                            id: id, capture: capture, exitCode: exitCode, on: db)
                    else { throw StalePayloadWrite() }
                    return .persisted
                }

                guard
                    let execution = try await VMCommandExecution.query(on: db)
                        .filter(\.$id == id)
                        .filter(\.$agentKey == capture.agentKey)
                        .first()
                else { return .discarded }
                return execution.status == .succeeded ? .duplicate : .discarded
            }
        } catch is StalePayloadWrite {
            // The thrown sentinel rolled the status claim back with the stale
            // payload write. Classify against the now-current durable row so a
            // legacy delta cannot leave `succeeded` with an older/no result.
            return try await persistenceOutcomeAfterRejectedWrite(
                id: id, agentKey: capture.agentKey)
        }
    }

    private func ownedExecution(id: UUID, agentKey: String) async throws -> VMCommandExecution? {
        try await beforeClassifyStart?()
        return try await VMCommandExecution.query(on: app.db)
            .filter(\.$id == id)
            .filter(\.$agentKey == agentKey)
            .first()
    }

    /// Classify a running snapshot and advance its durable watermark in the
    /// same transaction. Locking the execution first serializes this with
    /// terminal claims; the payload UPDATE is still a revision-checked atomic
    /// compare-and-write across replicas.
    private func classifyRunningSnapshot(
        id: UUID, agentKey: String, capture: Capture
    ) async throws -> RunningClassification {
        guard case .authoritative(let revision) = capture.revisionPolicy else {
            return .unknown
        }
        try await beforeClassifyStart?()
        return try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            let locked = try await sql.raw(
                """
                SELECT id
                FROM vm_command_executions
                WHERE id = \(bind: id) AND agent_key = \(bind: agentKey)
                FOR UPDATE
                """
            ).all(decoding: Claimed.self)
            guard !locked.isEmpty,
                let execution = try await VMCommandExecution.query(on: db)
                    .filter(\.$id == id)
                    .filter(\.$agentKey == agentKey)
                    .first()
            else { return .unknown }
            guard execution.status == .pending else { return .terminal }
            guard let payload = try await VMCommandPayload.find(id, on: db) else {
                throw Abort(.internalServerError, reason: "VM command payload is missing")
            }

            if let currentRevision = payload.resultRevision, currentRevision >= revision {
                return .pending(
                    deadline: execution.deadline,
                    acceptsSnapshot: currentRevision == revision)
            }

            let advanced = try await sql.raw(
                """
                UPDATE vm_command_payloads
                SET stdout = \(bind: capture.stdout),
                    stderr = \(bind: capture.stderr),
                    exit_code = NULL,
                    truncated = \(bind: capture.truncated),
                    result_revision = \(bind: revision)
                WHERE execution_id = \(bind: id)
                  AND (result_revision IS NULL OR result_revision < \(bind: revision))
                RETURNING execution_id AS id
                """
            ).all(decoding: Claimed.self)
            return .pending(
                deadline: execution.deadline,
                acceptsSnapshot: !advanced.isEmpty)
        }
    }

    private func recordedExecution(
        id: UUID, agentKey: String, acceptingSweptFailure: Bool = false
    ) async throws -> VMCommandExecution? {
        guard let execution = try await ownedExecution(id: id, agentKey: agentKey) else {
            return nil
        }
        if execution.status == .pending { return execution }
        if acceptingSweptFailure, execution.status == .failed,
            execution.error == Self.timeoutReason
        {
            return execution
        }
        return nil
    }

    /// Rehydrate partial bytes that a deadline sweep flushed before evicting
    /// its actor-local capture. Ownership and the accepted swept-failure state
    /// are established by `recordedExecution` before this lookup. Appending
    /// through `Capture` re-applies the combined one-MiB ceiling even if a
    /// malformed database row somehow exceeds the schema constraint.
    private func restoredCapture(
        id: UUID, execution: VMCommandExecution
    ) async throws -> Capture {
        var capture = Capture(
            agentKey: execution.agentKey,
            deadline: execution.status == .pending
                ? execution.deadline
                : Date().addingTimeInterval(Self.completionBudget))
        guard execution.status == .failed,
            let payload = try await VMCommandPayload.find(id, on: app.db)
        else { return capture }

        capture.append(payload.stdout ?? Data(), stream: "stdout")
        capture.append(payload.stderr ?? Data(), stream: "stderr")
        capture.truncated = capture.truncated || (payload.truncated ?? false)
        capture.authoritativeRevision = payload.resultRevision
        capture.revisionPolicy = .legacy(expectedRevision: payload.resultRevision)
        capture.replacesPersistedResult = true
        return capture
    }

    private func capture(
        from message: GuestExecRecordedStateMessage, agentKey: String
    ) -> Capture? {
        let fieldsAreValid: Bool
        switch message.status {
        case .running:
            fieldsAreValid = message.exitCode == nil && message.reason == nil
        case .exited:
            fieldsAreValid = message.exitCode != nil && message.reason == nil
        case .closed:
            fieldsAreValid = message.exitCode == nil && message.reason != nil
        }
        guard fieldsAreValid, message.revision >= 0, let stdout = message.rawStdout,
            let stderr = message.rawStderr
        else { return nil }

        var capture = Capture(
            agentKey: agentKey,
            deadline: Date().addingTimeInterval(Self.completionBudget))
        capture.authoritativeRevision = message.revision
        capture.revisionPolicy = .authoritative(message.revision)
        capture.append(stdout, stream: "stdout")
        capture.append(stderr, stream: "stderr")
        capture.truncated = capture.truncated || message.truncated
        capture.replacesPersistedResult = true
        return capture
    }

    private func recordPayload(
        id: UUID, capture: Capture, exitCode: Int?, on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard let payload = try await VMCommandPayload.find(id, on: db) else {
            throw Abort(.internalServerError, reason: "VM command payload is missing")
        }
        var persistedCapture = capture
        if !capture.replacesPersistedResult,
            payload.stdout != nil || payload.stderr != nil || payload.truncated != nil
        {
            // A transient classification error can leave only post-sweep
            // bytes in memory. Merge the previously flushed prefix inside the
            // same transaction that claims completion, preserving stream
            // order and re-applying the combined output ceiling.
            var merged = Capture(agentKey: capture.agentKey, deadline: capture.deadline)
            merged.append(payload.stdout ?? Data(), stream: "stdout")
            merged.append(payload.stderr ?? Data(), stream: "stderr")
            merged.append(capture.stdout, stream: "stdout")
            merged.append(capture.stderr, stream: "stderr")
            merged.truncated =
                merged.truncated || (payload.truncated ?? false) || capture.truncated
            merged.authoritativeRevision = capture.authoritativeRevision
            merged.revisionPolicy = capture.revisionPolicy
            merged.replacesPersistedResult = true
            persistedCapture = merged
        }

        let updated: [Claimed]
        switch persistedCapture.revisionPolicy {
        case .authoritative(let revision):
            updated = try await sql.raw(
                """
                UPDATE vm_command_payloads
                SET stdout = \(bind: persistedCapture.stdout),
                    stderr = \(bind: persistedCapture.stderr),
                    exit_code = \(bind: exitCode),
                    truncated = \(bind: persistedCapture.truncated),
                    result_revision = \(bind: revision)
                WHERE execution_id = \(bind: id)
                  AND (
                    result_revision IS NULL
                    OR result_revision < \(bind: revision)
                    OR (
                        result_revision = \(bind: revision)
                        AND stdout IS NULL AND stderr IS NULL
                        AND exit_code IS NULL AND truncated IS NULL
                    )
                    OR (
                        result_revision = \(bind: revision)
                        AND \(bind: persistedCapture.truncated) = TRUE
                        AND truncated IS DISTINCT FROM TRUE
                    )
                  )
                RETURNING execution_id AS id
                """
            ).all(decoding: Claimed.self)
        case .legacy(let expectedRevision):
            // A legacy delta is valid only against the exact watermark its
            // capture was built from. `IS NOT DISTINCT FROM` gives nil the
            // required SQL-null equality without letting it match a revision.
            updated = try await sql.raw(
                """
                UPDATE vm_command_payloads
                SET stdout = \(bind: persistedCapture.stdout),
                    stderr = \(bind: persistedCapture.stderr),
                    exit_code = \(bind: exitCode),
                    truncated = \(bind: persistedCapture.truncated)
                WHERE execution_id = \(bind: id)
                  AND result_revision IS NOT DISTINCT FROM \(bind: expectedRevision)
                RETURNING execution_id AS id
                """
            ).all(decoding: Claimed.self)
        }
        return !updated.isEmpty
    }

    private func persistClosed(
        id: UUID, capture: Capture, reason: String
    ) async throws -> PersistenceOutcome {
        try await beforePersistResult?()
        do {
            return try await app.db.transaction { db in
                guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
                let claimed: [Claimed]
                switch capture.revisionPolicy {
                case .authoritative:
                    claimed = try await sql.raw(
                        """
                        UPDATE vm_command_executions
                        SET status = 'failed', error = \(bind: String(reason.prefix(4_096))), completed_at = now()
                        WHERE id = \(bind: id)
                          AND agent_key = \(bind: capture.agentKey)
                          AND status IN ('pending', 'failed', 'succeeded')
                        RETURNING id
                        """
                    ).all(decoding: Claimed.self)
                case .legacy:
                    claimed = try await sql.raw(
                        """
                        UPDATE vm_command_executions
                        SET status = 'failed', error = \(bind: String(reason.prefix(4_096))), completed_at = now()
                        WHERE id = \(bind: id)
                          AND agent_key = \(bind: capture.agentKey)
                          AND status IN ('pending', 'failed')
                        RETURNING id
                        """
                    ).all(decoding: Claimed.self)
                }
                if !claimed.isEmpty {
                    guard
                        try await self.recordPayload(
                            id: id, capture: capture, exitCode: nil, on: db)
                    else { throw StalePayloadWrite() }
                    return .persisted
                }

                guard
                    let execution = try await VMCommandExecution.query(on: db)
                        .filter(\.$id == id)
                        .filter(\.$agentKey == capture.agentKey)
                        .first()
                else { return .discarded }
                return execution.status == .succeeded ? .duplicate : .discarded
            }
        } catch is StalePayloadWrite {
            return try await persistenceOutcomeAfterRejectedWrite(
                id: id, agentKey: capture.agentKey)
        }
    }

    private func persistenceOutcomeAfterRejectedWrite(
        id: UUID, agentKey: String
    ) async throws -> PersistenceOutcome {
        guard
            let execution = try await VMCommandExecution.query(on: app.db)
                .filter(\.$id == id)
                .filter(\.$agentKey == agentKey)
                .first()
        else { return .discarded }
        return execution.status == .succeeded ? .duplicate : .discarded
    }

    private func acknowledgeRecordedSession(id: UUID, agentKey: String) async {
        do {
            try await sendEnvelope(
                MessageEnvelope(
                    message: GuestExecRecordedAckMessage(sessionId: id.uuidString)),
                agentKey)
        } catch {
            // The agent retains terminal state until this typed ACK arrives,
            // so delivery failure is recoverable on its next reconnect.
            app.logger.warning(
                "Could not acknowledge recorded VM command state",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "agentKey": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func closeRecordedSession(id: UUID, agentKey: String, reason: String) async {
        do {
            try await sendEnvelope(
                MessageEnvelope(
                    message: GuestExecCloseMessage(
                        sessionId: id.uuidString, reason: reason)),
                agentKey)
        } catch {
            app.logger.warning(
                "Could not close stale recorded VM command session",
                metadata: [
                    "executionId": .string(id.uuidString),
                    "agentKey": .string(agentKey),
                    "error": .string(error.localizedDescription),
                ])
        }
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
        await retryClassification(id: id, agentKey: agentKey, acceptingSweptFailure: false)
    }

    private func retryClassification(
        id: UUID, agentKey: String, acceptingSweptFailure: Bool
    ) async {
        var nextDelay = retryDelay
        while captures[id]?.agentKey == agentKey, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
            guard captures[id]?.agentKey == agentKey, !app.didShutdown else {
                return
            }
            do {
                guard
                    let execution = try await recordedExecution(
                        id: id, agentKey: agentKey,
                        acceptingSweptFailure: acceptingSweptFailure)
                else {
                    captures.removeValue(forKey: id)
                    return
                }
                // The database query suspends this actor. A terminal frame may
                // have moved the capture into pending completion meanwhile;
                // never resurrect it after that transition.
                guard var capture = captures[id], capture.agentKey == agentKey else { return }
                capture.deadline =
                    execution.status == .pending
                    ? execution.deadline
                    : Date().addingTimeInterval(Self.completionBudget)
                storeCapture(capture, id: id)
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

    private func retryRunningClassification(id: UUID, agentKey: String) async {
        var nextDelay = retryDelay
        while captures[id]?.agentKey == agentKey, !app.didShutdown {
            try? await Task.sleep(for: nextDelay)
            guard let candidate = captures[id], candidate.agentKey == agentKey,
                candidate.authoritativeRevision != nil,
                !app.didShutdown
            else { return }
            do {
                let classification = try await classifyRunningSnapshot(
                    id: id, agentKey: agentKey, capture: candidate)
                guard captures[id]?.mutationToken == candidate.mutationToken else {
                    return
                }
                switch classification {
                case .unknown:
                    captures.removeValue(forKey: id)
                    await closeRecordedSession(
                        id: id, agentKey: agentKey,
                        reason: "recorded command is unknown to the control plane")
                    return
                case .terminal:
                    captures.removeValue(forKey: id)
                    await closeRecordedSession(
                        id: id, agentKey: agentKey,
                        reason: "recorded command is already terminal")
                    return
                case .pending(let deadline, let acceptsSnapshot):
                    guard acceptsSnapshot else {
                        captures.removeValue(forKey: id)
                        return
                    }
                    var capture = candidate
                    capture.deadline = deadline
                    storeCapture(capture, id: id)
                    return
                }
            } catch {
                app.logger.warning(
                    "Could not classify running recorded VM command; retrying",
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
                _ = try await complete(
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
            status != .pending
            ? try await VMCommandPayload.find(executionID, on: db)
            : nil
        return try operationResponse(payload: payload)
    }

    func operationResponse(payload: VMCommandPayload?) throws -> OperationResponse {
        let executionID = try requireID()
        let result = payload.flatMap { payload -> VMCommandResultResponse? in
            guard let stdout = payload.stdout, let stderr = payload.stderr,
                let truncated = payload.truncated
            else { return nil }
            return VMCommandResultResponse(
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: payload.exitCode,
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
