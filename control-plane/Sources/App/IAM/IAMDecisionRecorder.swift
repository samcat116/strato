import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

// IAM phase 5 (issue #482): the decision log, recording the authoritative
// Cedar verdicts.
//
// Every check `IAMAuthorizer` evaluates is recorded in `iam_decision_logs` —
// off the request path, in a background task — with the deciding policy, the
// tier, and the policy-set version. The reverse-shadow comparison that watched
// SpiceDB for disagreement during the cutover rollback window went with
// SpiceDB itself (issue #483); the `spicedb_*` columns keep their historical
// names and now carry the legacy-vocabulary question ("none" for the retired
// comparison verdict).

/// Decision-log configuration, from the environment.
struct IAMDecisionLogConfig: Sendable {
    /// Whether decision rows are written at all (`IAM_DECISION_LOG_ENABLED`).
    /// On by default in every environment except `.testing`: hundreds of
    /// unrelated controller tests would each pay a background insert per
    /// check for rows nothing reads. The IAM suites that assert on rows opt
    /// in.
    var recordDecisions: Bool
    /// Days to keep decision rows (`IAM_DECISION_LOG_RETENTION_DAYS`); the
    /// log records every authorization decision, so unbounded growth is the
    /// default failure mode. Non-positive disables the sweep.
    var retentionDays: Int
    /// How many recordings may hold database connections at once
    /// (`IAM_DECISION_LOG_MAX_CONCURRENCY`). See `IAMRecordingGate`.
    var maxConcurrentEvaluations: Int
    /// How many recordings may queue for a slot before the excess is shed
    /// (`IAM_DECISION_LOG_MAX_QUEUE_DEPTH`). See `IAMRecordingGate`.
    var maxQueueDepth: Int

    static func fromEnvironment(_ environment: Environment) -> IAMDecisionLogConfig {
        IAMDecisionLogConfig(
            recordDecisions: Environment.get("IAM_DECISION_LOG_ENABLED").flatMap(Bool.init)
                ?? (environment != .testing),
            retentionDays: Environment.get("IAM_DECISION_LOG_RETENTION_DAYS").flatMap(Int.init) ?? 30,
            maxConcurrentEvaluations: Environment.get("IAM_DECISION_LOG_MAX_CONCURRENCY")
                .flatMap(Int.init) ?? 4,
            maxQueueDepth: Environment.get("IAM_DECISION_LOG_MAX_QUEUE_DEPTH")
                .flatMap(Int.init) ?? 512
        )
    }
}

/// Bounds how much of the database decision recording may occupy at once.
///
/// Recording is off the request path but *not* off the connection pool: each
/// record holds a connection for its insert, while Fluent's Postgres pool
/// defaults to one connection per event loop. Unbounded fan-out therefore
/// starves the handlers recording is supposed to be invisible to.
///
/// `maxConcurrent` caps the recordings holding connections simultaneously.
/// `maxQueueDepth` caps the ones waiting, because a queue that grows without
/// limit only moves the unboundedness from connections to memory. Overflow is
/// shed and counted, never silently dropped: a decision log that sheds is a
/// log whose coverage has a number attached to it.
actor IAMRecordingGate {
    /// Whether a recording got a slot, and if not, how many have been shed.
    enum Outcome: Equatable, Sendable {
        case admitted
        case shed(total: Int)
    }

    private let maxConcurrent: Int
    private let maxQueueDepth: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var shedTotal = 0

    init(maxConcurrent: Int, maxQueueDepth: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxQueueDepth = max(0, maxQueueDepth)
    }

    /// Take a slot, waiting for one if the backlog has room.
    func acquire() async -> Outcome {
        if inFlight < maxConcurrent {
            inFlight += 1
            return .admitted
        }
        guard waiters.count < maxQueueDepth else {
            shedTotal += 1
            return .shed(total: shedTotal)
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return .admitted
    }

    /// Give the slot back, handing it straight to the longest-waiting check —
    /// `inFlight` stays at the ceiling when the slot transfers rather than
    /// dropping to zero and letting a burst back in.
    func release() {
        if waiters.isEmpty {
            inFlight -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Snapshot for tests and diagnostics.
    var stats: (inFlight: Int, queued: Int, shed: Int) {
        (inFlight, waiters.count, shedTotal)
    }
}

/// One evaluated, authoritative decision to record. A value type so it can
/// cross into the background task after the request is gone.
struct IAMDecisionRecord: Sendable {
    let subject: String
    let action: String
    let node: IAMNode
    let organizationID: UUID?
    let skippedConditionedBindings: Int
    let decision: CedarCheckDecision
    let policyVersion: Int
    /// The legacy-vocabulary question the check was phrased in, when it has
    /// one. Checks born in the IAM action vocabulary have none.
    let legacyEquivalent: LegacyCheckEquivalent?
    let context: IAMCheckContext
}

/// Writes the decision log.
final class IAMDecisionRecorder: Sendable {
    /// `spicedb_decision` value for every row since the reverse-shadow
    /// comparison retired with SpiceDB (#483); the column keeps its historical
    /// name so existing rows and API consumers stay readable.
    static let noComparison = "none"

    private let app: Application
    let config: IAMDecisionLogConfig
    private let logger: Logger
    private let retentionTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// Keeps decision recording from starving request handlers of connections.
    let gate: IAMRecordingGate

    init(app: Application, config: IAMDecisionLogConfig) {
        self.app = app
        self.config = config
        self.logger = app.logger
        self.gate = IAMRecordingGate(
            maxConcurrent: config.maxConcurrentEvaluations,
            maxQueueDepth: config.maxQueueDepth)
    }

    /// Record `record` off the request path. The spawn is tracked by the
    /// background-task registry so shutdown drains in-flight recordings, and
    /// gated so the fan-out cannot outgrow the connection pool.
    func recordInBackground(_ record: IAMDecisionRecord) {
        recordInBackground([record])
    }

    /// Record a batch of decisions as one gated write (#687).
    ///
    /// A batched list decision produces a row per item, and spawning them
    /// individually is what pushed a hundred-VM list into the shed ceiling: a
    /// hundred tasks, each queueing for one of four slots, each holding a
    /// connection for one insert. One task and one multi-row insert costs the
    /// gate a single slot no matter how many rows — which is what makes the
    /// decision log survive list scoping at all.
    func recordInBackground(_ records: [IAMDecisionRecord]) {
        guard config.recordDecisions, !records.isEmpty else { return }
        spawnGated { await self.record(records) }
    }

    /// Record a check the legacy-vocabulary boundary could not translate.
    /// Enforcement failed closed (the request was denied); the row keeps the
    /// gap visible and countable, exactly as untranslated checks were during
    /// the forward-shadow phase.
    func recordUntranslatedDenial(
        subject: String, equivalent: LegacyCheckEquivalent, context: IAMCheckContext
    ) {
        guard config.recordDecisions else { return }
        spawnGated {
            let entry = IAMDecisionLog()
            entry.requestID = context.requestID
            entry.path = context.path
            entry.method = context.method
            entry.subject = subject
            entry.spicedbPermission = equivalent.permission
            entry.resourceType = equivalent.resourceType
            entry.resourceID = equivalent.resourceID
            entry.spicedbDecision = Self.noComparison
            entry.cedarDecision = "untranslated"
            await self.save(entry)
        }
    }

    private func spawnGated(_ work: @escaping @Sendable () async -> Void) {
        app.backgroundTasks.spawn { [self] in
            switch await gate.acquire() {
            case .shed(let total):
                // Log the first shed and then every hundredth: a saturated
                // gate is a standing condition, not an incident to repeat.
                if total == 1 || total % 100 == 0 {
                    logger.warning(
                        "IAM decision recording shed under backpressure",
                        metadata: [
                            "shed_total": .string("\(total)"),
                            "max_concurrency": .string("\(config.maxConcurrentEvaluations)"),
                            "max_queue_depth": .string("\(config.maxQueueDepth)"),
                        ])
                }
                return
            case .admitted:
                // A recording that waited through shutdown skips the database
                // work and releases immediately, so the queue behind it drains
                // at once instead of each waiter starting fresh queries while
                // Fluent tears its pools down.
                if !Task.isCancelled {
                    await work()
                }
                await gate.release()
            }
        }
    }

    /// Build the decision row and save it. Never throws: a recording failure
    /// is a log line, never a request failure (the request's verdict was
    /// already enforced inline).
    func record(_ record: IAMDecisionRecord) async {
        await self.record([record])
    }

    /// Build every row and write them together. Internal so tests can drive it
    /// directly.
    func record(_ records: [IAMDecisionRecord]) async {
        guard !records.isEmpty else { return }
        await save(records.map(entry(for:)))
    }

    private func entry(for record: IAMDecisionRecord) -> IAMDecisionLog {
        let entry = IAMDecisionLog()
        entry.requestID = record.context.requestID
        entry.path = record.context.path
        entry.method = record.context.method
        entry.subject = record.subject
        entry.iamAction = record.action
        entry.nodeType = record.node.type.rawValue
        entry.nodeID = record.node.id
        entry.organizationID = record.organizationID
        entry.skippedConditionedBindings = record.skippedConditionedBindings
        entry.policyVersion = record.policyVersion
        entry.cedarDecision = record.decision.allowed ? "allow" : "deny"
        entry.tier = record.decision.tier
        do {
            entry.determiningPoliciesJSON = try CedarText.json(record.decision.determiningPolicyIDs)
        } catch {
            // Naming what decided is the point of the row; losing it silently
            // would leave an unexplainable verdict behind.
            logger.error(
                "Failed to encode determining policy ids",
                metadata: [
                    "policies": .string(record.decision.determiningPolicyIDs.joined(separator: ",")),
                    "error": .string("\(error)"),
                ])
        }
        if !record.decision.evaluationErrors.isEmpty {
            entry.cedarErrors = record.decision.evaluationErrors.joined(separator: "; ")
        }

        // The historically named spicedb_* columns carry the legacy-vocabulary
        // question when there was one; for native-vocabulary checks they
        // mirror the tree coordinates so the row is still self-describing.
        entry.spicedbPermission = record.legacyEquivalent?.permission ?? record.action
        entry.resourceType = record.legacyEquivalent?.resourceType ?? record.node.type.rawValue
        entry.resourceID = record.legacyEquivalent?.resourceID ?? record.node.id.uuidString
        entry.spicedbDecision = Self.noComparison

        return entry
    }

    private func save(_ entry: IAMDecisionLog) async {
        await save([entry])
    }

    private func save(_ entries: [IAMDecisionLog]) async {
        // `liveDB`, not `app.db`: a recording cancelled by shutdown's drain
        // must bail rather than force-unwrap cleared storage (the
        // FluentProvider teardown crash, see `Application.liveDB`).
        guard let db = app.liveDB, !entries.isEmpty else { return }
        do {
            // One statement for the whole batch — Fluent's array `create`
            // is a multi-row INSERT.
            try await entries.create(on: db)
        } catch {
            logger.error(
                "Failed to write IAM decision log entries",
                metadata: [
                    "count": .stringConvertible(entries.count),
                    "error": .string("\(error)"),
                ])
        }
    }

    // MARK: Retention sweep

    /// Mirrors the audit retention sweep: hourly passes, cluster-singleton via
    /// the coordination sweep lock, whole-day granularity.
    static let retentionSweepIntervalSeconds = 3600
    static let retentionSweepLockTTLSeconds = 3300

    /// Arm the periodic retention sweep; a no-op when retention is disabled.
    func startRetentionSweep() {
        guard config.retentionDays > 0 else {
            logger.warning("IAM decision-log retention disabled; decision rows are kept forever")
            return
        }
        retentionTask.withLockedValue { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sweepExpiredEntries()
                    do {
                        try await Task.sleep(for: .seconds(Self.retentionSweepIntervalSeconds))
                    } catch {
                        break  // cancelled
                    }
                }
            }
        }
    }

    /// Cancel the retention sweep at shutdown so the periodic delete never
    /// outlives the application.
    func shutdown() {
        retentionTask.withLockedValue { task in
            task?.cancel()
            task = nil
        }
    }

    /// One retention pass. Internal so tests can drive it directly.
    func sweepExpiredEntries() async {
        let days = config.retentionDays
        guard days > 0 else { return }
        guard
            await app.coordination.acquireSweepLock(
                "iam_decision_log_retention", ttlSeconds: Self.retentionSweepLockTTLSeconds)
        else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        guard let db = app.liveDB else { return }
        do {
            try await IAMDecisionLog.query(on: db)
                .filter(\.$createdAt < cutoff)
                .delete()
        } catch {
            logger.error("IAM decision-log retention sweep failed: \(error)")
        }
    }
}

// MARK: - Application accessors

extension Application {
    private struct IAMDecisionLogConfigKey: StorageKey {
        typealias Value = IAMDecisionLogConfig
    }

    /// Decision-log configuration. Settable so tests can enable recording
    /// (off by default under `.testing`) before the recorder is first built.
    var iamDecisionLogConfig: IAMDecisionLogConfig {
        get { storage[IAMDecisionLogConfigKey.self] ?? .fromEnvironment(environment) }
        set { setStorageValue(IAMDecisionLogConfigKey.self, to: newValue) }
    }

    private struct IAMDecisionRecorderKey: StorageKey, LockKey {
        typealias Value = IAMDecisionRecorder
    }

    /// The decision recorder, created on first use with the current config.
    var iamDecisionRecorder: IAMDecisionRecorder {
        lazyService(IAMDecisionRecorderKey.self) {
            IAMDecisionRecorder(app: self, config: iamDecisionLogConfig)
        }
    }

    /// The recorder if something already created it — shutdown must not
    /// instantiate the service just to shut it down.
    var iamDecisionRecorderIfCreated: IAMDecisionRecorder? {
        storage[IAMDecisionRecorderKey.self]
    }
}

/// Arms the decision-log retention sweep at boot and cancels it at shutdown.
struct IAMDecisionLogLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        // Armed even when recording is off: an operator who disables
        // recording because the table has grown is the last person who should
        // also lose the sweep that prunes it. The sweep no-ops on its own when
        // retention is disabled.
        application.iamDecisionRecorder.startRetentionSweep()
    }

    func shutdownAsync(_ application: Application) async {
        application.iamDecisionRecorderIfCreated?.shutdown()
    }
}
