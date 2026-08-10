import Fluent
import Foundation
import NIOConcurrencyHelpers
import Tracing
import Vapor

// IAM phase 5 (issue #482): the decision log, recording the authoritative
// Cedar verdicts.
//
// Every check `IAMAuthorizer` evaluates is recorded in `iam_decision_logs` —
// off the request path, in a background task — with its canonical action and
// node, the deciding policy, the tier, and the policy-set version.

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
    /// How many decisions may wait for the drain before the excess is shed
    /// (`IAM_DECISION_LOG_MAX_QUEUE_DEPTH`). See `IAMDecisionQueue`.
    var maxQueueDepth: Int
    /// How many queued decisions one drain pass writes together
    /// (`IAM_DECISION_LOG_MAX_BATCH_SIZE`); a batch becomes a single
    /// multi-row insert.
    var maxBatchSize: Int

    static func fromEnvironment(_ environment: Environment) -> IAMDecisionLogConfig {
        IAMDecisionLogConfig(
            recordDecisions: Environment.get("IAM_DECISION_LOG_ENABLED").flatMap(Bool.init)
                ?? (environment != .testing),
            retentionDays: Environment.get("IAM_DECISION_LOG_RETENTION_DAYS").flatMap(Int.init) ?? 30,
            maxQueueDepth: Environment.get("IAM_DECISION_LOG_MAX_QUEUE_DEPTH")
                .flatMap(Int.init) ?? 2048,
            maxBatchSize: Environment.get("IAM_DECISION_LOG_MAX_BATCH_SIZE")
                .flatMap(Int.init) ?? 128
        )
    }
}

/// One decision waiting to be written. The row is built in the drain, not at
/// the check site, so the request path pays nothing beyond the enqueue.
enum PendingIAMDecision: Sendable {
    /// A decision the evaluator reached.
    case evaluated(IAMDecisionRecord)
    /// A request refused because a restricted credential reached a surface the
    /// evaluator does not gate — the only credential denial left without a
    /// Cedar verdict behind it, recorded so every authorization refusal is
    /// attributable here (STR-116, STR-115).
    case credentialRestricted(
        subject: String,
        credential: CredentialReference?,
        context: IAMCheckContext)
}

/// Why a restricted credential was refused without an evaluator decision. Each
/// case names a surface that authorizes by construction rather than by
/// deciding, so there was no action to intersect the restriction with.
enum CredentialDenialReason: String, Sendable {
    /// A mutation on an identity-plane route (`/api/api-keys`, `/api/oauth`, …)
    /// whose authorization is row scoping to the caller's own record.
    case loginOnlyMutation = "login_only_mutation"
    /// A mutation on a session-free public route (registration, the device
    /// grant).
    case publicMutation = "public_mutation"
    /// A node-less platform surface gated by `requireSystemAdmin()`.
    case platformAdminSurface = "platform_admin_surface"
    /// A mutation whose handler declared its authorization to be row scoping
    /// (`markRowScopedAuthorization`).
    case rowScopedMutation = "row_scoped_mutation"

    /// The 403 reason phrase. Deliberately says *restricted*, not "forbidden":
    /// the caller's bindings may well permit this, and the fix is a wider
    /// credential rather than a wider grant.
    var deniedReason: String {
        switch self {
        case .loginOnlyMutation, .publicMutation:
            return "This credential is restricted and cannot perform identity or account operations"
        case .platformAdminSurface:
            return "This credential is restricted and cannot reach platform administration"
        case .rowScopedMutation:
            return "This credential is restricted and cannot perform this operation"
        }
    }
}

/// The buffer between a check and its decision row (issue #736).
///
/// Recording has always been off the request path, but it was one background
/// task and one single-row insert *per check* — so a VM create, which
/// authorizes three times, spawned three tasks that each took a connection
/// from the pool the create was already saturating with its own queries. The
/// wait for a connection is what showed up in the traces (up to ~530ms on a
/// loaded host), not the insert.
///
/// Decisions now queue here and a single drain task ships them in batches, one
/// multi-row insert each: one connection held at a time no matter how many
/// checks are in flight. The batching is self-regulating — an idle drain
/// writes each row as it arrives, while a drain waiting on a connection
/// accumulates, so the rows coalesce exactly when the pool is contended, which
/// is the condition that made this hurt.
///
/// The queue is bounded and its overflow counted rather than silently dropped,
/// as the audit queue is: a decision log that sheds is a log whose coverage
/// has a number attached to it. Producers never wait for room — the point is
/// that authorization does not block on its own bookkeeping — so the
/// backpressure valve is shedding, not queuing the caller.
actor IAMDecisionQueue {
    /// What `enqueue` did with a group of decisions. Partial acceptance is
    /// deliberate: a hundred-node list decision arriving at a nearly full
    /// queue should write the rows that fit rather than lose all hundred.
    struct EnqueueOutcome: Equatable, Sendable {
        var accepted: Int
        var shed: Int
        /// Running total of everything ever shed, for the warning's counter.
        var shedTotal: Int
        /// True when the caller must start the drain because none is running.
        var startDrain: Bool
    }

    /// Ceiling on how many decisions one batch may carry.
    ///
    /// A batch becomes a single multi-row INSERT — Fluent's collection
    /// `create` builds one query and does not chunk — and Postgres refuses a
    /// statement with more than 65535 bind parameters. `IAMDecisionLog`
    /// persists 21 columns, so the hard limit is ~3100 rows; 1024 keeps a wide
    /// margin while being far more than any drain needs. Without it an
    /// operator who set `IAM_DECISION_LOG_MAX_BATCH_SIZE` into the thousands
    /// would lose *every* batch to a failing insert.
    static let maxSupportedBatchSize = 1024

    private let maxQueueDepth: Int
    private let maxBatchSize: Int
    private var pending: [PendingIAMDecision] = []
    private var draining = false
    private var shedTotal = 0
    /// Batches handed out by `nextBatch` and not yet reported written. An
    /// empty `pending` is not the same as "everything is written": the batch
    /// in the air belongs to whoever claimed it.
    private var inFlight = 0

    init(maxQueueDepth: Int, maxBatchSize: Int) {
        self.maxQueueDepth = max(1, maxQueueDepth)
        self.maxBatchSize = min(max(1, maxBatchSize), Self.maxSupportedBatchSize)
    }

    func enqueue(_ decisions: [PendingIAMDecision]) -> EnqueueOutcome {
        let room = max(0, maxQueueDepth - pending.count)
        let accepted = min(room, decisions.count)
        let shed = decisions.count - accepted
        if accepted > 0 {
            pending.append(contentsOf: decisions.prefix(accepted))
        }
        shedTotal += shed
        // Anything buffered with no drain live needs one started — including
        // the case where this enqueue was shed entirely but a previous drain
        // was cancelled (shutdown) with rows still queued behind it.
        var startDrain = false
        if !pending.isEmpty, !draining {
            draining = true
            startDrain = true
        }
        return EnqueueOutcome(
            accepted: accepted, shed: shed, shedTotal: shedTotal, startDrain: startDrain)
    }

    /// Take the next batch, or nil when the buffer is empty. The caller owns
    /// the batch until it reports back through `finishBatch`.
    ///
    /// The drain task passes `endDrainWhenEmpty: true`, so running dry also
    /// clears the flag that says a drain is live. Both halves happen in one
    /// actor step, so an `enqueue` racing a finishing drain either lands in
    /// that drain's batch or starts a fresh one — never neither. `flush`
    /// passes false: it borrows work from a drain that is still running and
    /// must not retire it.
    func nextBatch(endDrainWhenEmpty: Bool = true) -> [PendingIAMDecision]? {
        guard !pending.isEmpty else {
            if endDrainWhenEmpty { draining = false }
            return nil
        }
        let batch = Array(pending.prefix(maxBatchSize))
        pending.removeFirst(batch.count)
        inFlight += 1
        return batch
    }

    /// Report a claimed batch written (or given up on).
    func finishBatch() {
        inFlight = max(0, inFlight - 1)
    }

    /// Nothing queued and nothing in the air — the condition `flush` waits for.
    var isIdle: Bool {
        pending.isEmpty && inFlight == 0
    }

    /// Retire the drain without emptying the buffer — for a drain task that
    /// was cancelled rather than one that ran dry.
    func endDrain() {
        draining = false
    }

    /// Snapshot for tests and diagnostics.
    var stats: (queued: Int, draining: Bool, shed: Int) {
        (pending.count, draining, shedTotal)
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
    /// The API key or CLI session the request arrived on, when it arrived on
    /// one. Recorded for allows as well as denies: "what has this token been
    /// doing" is the question an audit asks first.
    let credential: CredentialReference?
    let context: IAMCheckContext
}

/// Writes the decision log.
final class IAMDecisionRecorder: Sendable {
    private let app: Application
    let config: IAMDecisionLogConfig
    private let logger: Logger
    private let retentionTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// The buffer feeding the drain; keeps recording off the request path and
    /// off all but one connection.
    let queue: IAMDecisionQueue
    /// How many insert passes the drain has made. Tests assert on it: the
    /// point of the queue is that a burst of checks costs one write, and a
    /// regression that reintroduced a write per check should show up as a
    /// number rather than as a slow endpoint nobody profiled.
    let writeCount = NIOLockedValueBox<Int>(0)

    init(app: Application, config: IAMDecisionLogConfig) {
        self.app = app
        self.config = config
        self.logger = app.logger
        self.queue = IAMDecisionQueue(
            maxQueueDepth: config.maxQueueDepth, maxBatchSize: config.maxBatchSize)
        if config.maxBatchSize > IAMDecisionQueue.maxSupportedBatchSize {
            app.logger.warning(
                "IAM_DECISION_LOG_MAX_BATCH_SIZE exceeds the supported ceiling; clamping",
                metadata: [
                    "requested": .stringConvertible(config.maxBatchSize),
                    "ceiling": .stringConvertible(IAMDecisionQueue.maxSupportedBatchSize),
                ])
        }
        if Environment.get("IAM_DECISION_LOG_MAX_CONCURRENCY") != nil {
            app.logger.warning(
                """
                IAM_DECISION_LOG_MAX_CONCURRENCY is no longer read; decision rows are written by a \
                single batching drain (see IAM_DECISION_LOG_MAX_BATCH_SIZE)
                """)
        }
    }

    /// Queue a check's decisions for the drain. Returns as soon as they are
    /// buffered — the only thing the request path pays for its decision rows.
    /// A batched list decision (#687) produces a row per item and rides the
    /// same drain as a lone check's single row.
    func record(_ records: [IAMDecisionRecord]) async {
        guard !records.isEmpty else { return }
        await enqueue(records.map(PendingIAMDecision.evaluated))
    }

    /// Record a restricted credential refused on a surface the evaluator does
    /// not gate. Every other restriction denial is an ordinary Cedar deny row
    /// carrying the `credential-restriction` policy id; these few have no
    /// verdict behind them and would otherwise be 403s the decision log cannot
    /// explain.
    func recordCredentialRestriction(
        subject: String,
        credential: CredentialReference?,
        context: IAMCheckContext
    ) async {
        await enqueue(
            [.credentialRestricted(subject: subject, credential: credential, context: context)])
    }

    private func enqueue(_ decisions: [PendingIAMDecision]) async {
        guard config.recordDecisions, !decisions.isEmpty else { return }
        let outcome = await queue.enqueue(decisions)
        if outcome.shed > 0 {
            // Log the first drop and then every hundredth: a saturated queue
            // is a standing condition, not an incident to repeat per decision.
            let total = outcome.shedTotal
            let previous = total - outcome.shed
            if previous == 0 || previous / 100 != total / 100 {
                logger.warning(
                    "IAM decision recording shed under backpressure",
                    metadata: [
                        "shed_total": .stringConvertible(total),
                        "max_queue_depth": .stringConvertible(config.maxQueueDepth),
                    ])
            }
        }
        guard outcome.startDrain else { return }
        // Tracked by the background-task registry so shutdown drains the
        // buffer before Fluent tears its pools down. The drain runs with no
        // service context: it outlives the request that happened to start it
        // and writes other requests' decisions too, so its inserts belong in a
        // trace of their own rather than nested under one arbitrary
        // `iam.authorize` span.
        app.backgroundTasks.spawn { [self] in
            await ServiceContext.$current.withValue(nil) { await drainQueue() }
        }
    }

    /// Write queued decisions until the buffer is empty. Only one drain task
    /// runs at a time — the queue hands out the drain flag — so decision
    /// recording never holds more than one connection.
    private func drainQueue() async {
        while !Task.isCancelled, let batch = await queue.nextBatch() {
            await write(batch)
            await queue.finishBatch()
        }
        // Cancelled (shutdown's grace period expired) rather than run dry:
        // retire the drain explicitly, so anything enqueued afterwards starts
        // a fresh one instead of waiting on a task that is gone.
        if Task.isCancelled {
            await queue.endDrain()
        }
    }

    /// Build every row in the batch and write them together. Internal so tests
    /// can drive a pass directly. Never throws: a recording failure is a log
    /// line, never a request failure (the request's verdict was already
    /// enforced inline).
    func write(_ decisions: [PendingIAMDecision]) async {
        guard !decisions.isEmpty else { return }
        await save(decisions.map(entry(for:)))
    }

    /// Write everything queued and return once the queue is idle — the
    /// determinism hook for tests, and the shutdown drain that guarantees a
    /// graceful stop loses no decisions.
    ///
    /// "Idle" means more than an empty buffer: a drain task that already
    /// claimed a batch is still writing it, and returning while that batch is
    /// in the air would hand callers the same false "everything is written" an
    /// empty queue used to imply. Bounded by `timeout`, so a wedged database
    /// cannot stall shutdown.
    func flush(waitingUpTo timeout: Duration = .seconds(10)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let batch = await queue.nextBatch(endDrainWhenEmpty: false) {
                await write(batch)
                await queue.finishBatch()
                continue
            }
            if await queue.isIdle { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let remaining = await queue.stats
        if remaining.queued > 0 {
            logger.warning(
                "IAM decision-log flush timed out with decisions still queued",
                metadata: ["queued": .stringConvertible(remaining.queued)])
        }
    }

    private func entry(for decision: PendingIAMDecision) -> IAMDecisionLog {
        switch decision {
        case .evaluated(let record):
            return entry(for: record)
        case .credentialRestricted(let subject, let credential, let context):
            let entry = IAMDecisionLog()
            entry.requestID = context.requestID
            entry.path = context.path
            entry.method = context.method
            entry.subject = subject
            entry.decision = "credential_restricted"
            entry.tier = CedarCheckDecision.credentialTier
            entry.credentialType = credential?.kind.rawValue
            entry.credentialID = credential?.id
            return entry
        }
    }

    private func entry(for record: IAMDecisionRecord) -> IAMDecisionLog {
        let entry = IAMDecisionLog()
        entry.requestID = record.context.requestID
        entry.path = record.context.path
        entry.method = record.context.method
        entry.subject = record.subject
        entry.action = record.action
        entry.nodeType = record.node.type.rawValue
        entry.nodeID = record.node.id
        entry.organizationID = record.organizationID
        entry.skippedConditionedBindings = record.skippedConditionedBindings
        entry.policyVersion = record.policyVersion
        entry.decision = record.decision.allowed ? "allow" : "deny"
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

        entry.credentialType = record.credential?.kind.rawValue
        entry.credentialID = record.credential?.id

        return entry
    }

    private func save(_ entries: [IAMDecisionLog]) async {
        // `liveDB`, not `app.db`: a recording cancelled by shutdown's drain
        // must bail rather than force-unwrap cleared storage (the
        // FluentProvider teardown crash, see `Application.liveDB`).
        guard let db = app.liveDB, !entries.isEmpty else { return }
        writeCount.withLockedValue { $0 += 1 }
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
        guard let recorder = application.iamDecisionRecorderIfCreated else { return }
        // Write out whatever is still queued before Fluent's pools close. The
        // drain task is tracked by the background-task registry, but that
        // registry's own drain is bounded and runs from a different lifecycle
        // handler, so an explicit flush here leaves nothing behind either way.
        await recorder.flush(waitingUpTo: .seconds(5))
        recorder.shutdown()
    }
}
