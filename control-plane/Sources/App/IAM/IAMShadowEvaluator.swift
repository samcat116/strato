import Fluent
import Foundation
import NIOConcurrencyHelpers
import Vapor

// IAM phase 4 (issue #481): shadow evaluation and the decision log.
//
// Every SpiceDB permission check also runs through the compiled Cedar policy
// set — off the request path, in a background task — and every decision is
// recorded in `iam_decision_logs` with both verdicts, the deciding policy, the
// policy-set version, and the tier. Verdict mismatches are burned down against
// docs/architecture/iam.md before cutover (#482); two classes are expected and
// confirm correctness rather than refute it (org-member project visibility
// removed; nested-folder admin inheritance fixed).

/// Shadow-evaluation configuration, from the environment.
struct IAMShadowConfig: Sendable {
    /// Whether checks are shadowed at all (`IAM_SHADOW_EVAL_ENABLED`). On by
    /// default in every environment except `.testing`, where the background
    /// evaluation would race hundreds of unrelated tests' teardown; shadow
    /// tests opt in explicitly.
    var enabled: Bool
    /// Days to keep decision rows (`IAM_DECISION_LOG_RETENTION_DAYS`); the
    /// log records every authorization decision, so unbounded growth is the
    /// default failure mode. Non-positive disables the sweep.
    var retentionDays: Int
    /// How many evaluations may hold database connections at once
    /// (`IAM_SHADOW_EVAL_MAX_CONCURRENCY`). See `IAMShadowGate`.
    var maxConcurrentEvaluations: Int
    /// How many evaluations may queue for a slot before the excess is shed
    /// (`IAM_SHADOW_EVAL_MAX_QUEUE_DEPTH`). See `IAMShadowGate`.
    var maxQueueDepth: Int

    static func fromEnvironment(_ environment: Environment) -> IAMShadowConfig {
        IAMShadowConfig(
            enabled: Environment.get("IAM_SHADOW_EVAL_ENABLED").flatMap(Bool.init)
                ?? (environment != .testing),
            retentionDays: Environment.get("IAM_DECISION_LOG_RETENTION_DAYS").flatMap(Int.init) ?? 30,
            maxConcurrentEvaluations: Environment.get("IAM_SHADOW_EVAL_MAX_CONCURRENCY")
                .flatMap(Int.init) ?? 4,
            maxQueueDepth: Environment.get("IAM_SHADOW_EVAL_MAX_QUEUE_DEPTH")
                .flatMap(Int.init) ?? 512
        )
    }
}

/// Bounds how much of the database shadow evaluation may occupy at once.
///
/// Shadowing is off the request path but *not* off the connection pool: each
/// check is roughly ten sequential queries (`EntitySliceLoader.load` walks the
/// ancestor chain a level at a time, then reads groups, org memberships, and
/// bindings) plus the decision-row insert, while Fluent's Postgres pool
/// defaults to one connection per event loop. Unbounded fan-out therefore
/// starves the handlers shadowing is supposed to be invisible to.
///
/// `maxConcurrent` caps the evaluations holding connections simultaneously.
/// `maxQueueDepth` caps the ones waiting, because a queue that grows without
/// limit only moves the unboundedness from connections to memory — and a check
/// that waits long enough is evaluated against a policy set that has moved on.
/// Overflow is shed and counted, never silently dropped: a burn-down run that
/// sheds is a run whose coverage has a number attached to it.
actor IAMShadowGate {
    /// Whether a check got a slot, and if not, how many have been shed.
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

/// One check to shadow: the SpiceDB question and its verdict, plus the request
/// coordinates for the log row. A value type so it can cross into the
/// background task after the request is gone.
struct IAMShadowCheck: Sendable {
    let subject: String
    let permission: String
    let resourceType: String
    let resourceID: String
    let spicedbAllowed: Bool
    let path: String
    let method: String
    let requestID: String?
}

/// Runs the Cedar side of each check and writes the decision log.
final class IAMShadowEvaluator: Sendable {
    private let app: Application
    let config: IAMShadowConfig
    private let logger: Logger
    private let retentionTask = NIOLockedValueBox<Task<Void, Never>?>(nil)
    /// Keeps shadow evaluation from starving request handlers of connections.
    let gate: IAMShadowGate

    init(app: Application, config: IAMShadowConfig) {
        self.app = app
        self.config = config
        self.logger = app.logger
        self.gate = IAMShadowGate(
            maxConcurrent: config.maxConcurrentEvaluations,
            maxQueueDepth: config.maxQueueDepth)
    }

    /// Shadow `check` off the request path. The spawn is tracked by the
    /// background-task registry so shutdown drains in-flight evaluations, and
    /// gated so the fan-out cannot outgrow the connection pool.
    func shadowInBackground(_ check: IAMShadowCheck) {
        guard config.enabled else { return }
        app.backgroundTasks.spawn { [self] in
            switch await gate.acquire() {
            case .shed(let total):
                // Log the first shed and then every hundredth: a saturated
                // gate is a standing condition, not an incident to repeat.
                if total == 1 || total % 100 == 0 {
                    logger.warning(
                        "IAM shadow evaluation shed under backpressure",
                        metadata: [
                            "shed_total": .string("\(total)"),
                            "max_concurrency": .string("\(config.maxConcurrentEvaluations)"),
                            "max_queue_depth": .string("\(config.maxQueueDepth)"),
                        ])
                }
                return
            case .admitted:
                // A check that waited through shutdown skips the database work
                // and releases immediately, so the queue behind it drains at
                // once instead of each waiter starting fresh queries while
                // Fluent tears its pools down.
                if !Task.isCancelled {
                    await shadow(check)
                }
                await gate.release()
            }
        }
    }

    /// Evaluate one check through Cedar and record the decision. Never throws:
    /// a shadow failure is a log line and a decision row saying so, never a
    /// request failure.
    func shadow(_ check: IAMShadowCheck) async {
        let entry = IAMDecisionLog()
        entry.requestID = check.requestID
        entry.path = check.path
        entry.method = check.method
        entry.subject = check.subject
        entry.spicedbPermission = check.permission
        entry.resourceType = check.resourceType
        entry.resourceID = check.resourceID
        entry.spicedbDecision = check.spicedbAllowed ? "allow" : "deny"

        await evaluate(check, into: entry)

        if entry.decisionsMatch == false {
            // The mismatch line carries everything the burn-down needs without
            // opening the database: both verdicts, what decided, and which
            // policy-set version decided it.
            logger.warning(
                "IAM shadow-evaluation mismatch",
                metadata: [
                    "permission": .string(check.permission),
                    "iam_action": .string(entry.iamAction ?? "-"),
                    "resource": .string("\(check.resourceType):\(check.resourceID)"),
                    "subject": .string(check.subject),
                    "spicedb": .string(entry.spicedbDecision),
                    "cedar": .string(entry.cedarDecision),
                    "determining_policies": .string(entry.determiningPoliciesJSON ?? "[]"),
                    "tier": .string(entry.tier ?? "-"),
                    "policy_version": .string(entry.policyVersion.map(String.init) ?? "-"),
                    "path": .string(check.path),
                ])
        }

        do {
            try await entry.save(on: app.db)
        } catch {
            logger.error(
                "Failed to write IAM decision log entry",
                metadata: ["error": .string("\(error)")])
        }
    }

    /// The Cedar half: translate, load the slice, evaluate, and fill the
    /// entry's Cedar-side fields.
    private func evaluate(_ check: IAMShadowCheck, into entry: IAMDecisionLog) async {
        guard
            let translation = IAMShadowTranslator.translate(
                permission: check.permission,
                resourceType: check.resourceType,
                resourceID: check.resourceID,
                path: check.path),
            let userID = UUID(uuidString: check.subject)
        else {
            entry.cedarDecision = "untranslated"
            return
        }
        entry.iamAction = translation.action
        entry.nodeType = translation.node.type.rawValue
        entry.nodeID = translation.node.id

        guard let built = await app.cedarPolicySet.current else {
            // No compiled set yet (boot races, or a build that has never
            // succeeded) — recorded, not silently dropped, so a replica that
            // never compiles shows up as a wall of `skipped` rows.
            entry.cedarDecision = "skipped"
            return
        }
        entry.policyVersion = built.version

        do {
            let slice = try await EntitySliceLoader.load(
                userID: userID, node: translation.node, on: app.db)
            entry.organizationID = slice.chain.first(where: { $0.type == .organization })?.id
            entry.skippedConditionedBindings = slice.skippedConditionedBindings

            let decision = try built.artifact.authorize(
                principal: slice.principal,
                action: translation.action,
                resource: slice.resource,
                context: slice.baseContextValue,
                entitiesJSON: slice.entitiesJSON())

            entry.cedarDecision = decision.allowed ? "allow" : "deny"
            entry.decisionsMatch = decision.allowed == check.spicedbAllowed
            entry.tier = decision.tier
            do {
                entry.determiningPoliciesJSON = try CedarText.json(decision.determiningPolicyIDs)
            } catch {
                // Naming what decided is the point of the row; losing it
                // silently would leave an unexplainable verdict behind.
                logger.error(
                    "Failed to encode determining policy ids",
                    metadata: [
                        "policies": .string(decision.determiningPolicyIDs.joined(separator: ",")),
                        "error": .string("\(error)"),
                    ])
            }
            if !decision.evaluationErrors.isEmpty {
                entry.cedarErrors = decision.evaluationErrors.joined(separator: "; ")
            }
        } catch {
            entry.cedarDecision = "error"
            entry.cedarErrors = "\(error)"
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
        do {
            try await IAMDecisionLog.query(on: app.db)
                .filter(\.$createdAt < cutoff)
                .delete()
        } catch {
            logger.error("IAM decision-log retention sweep failed: \(error)")
        }
    }
}

// MARK: - The shadowing decorator

/// Wraps a `SpiceDBServiceProtocol` so every permission check is shadowed
/// through Cedar. Returned by `Request.spicedb`, which is what makes coverage
/// total: all ~50 handler and middleware check sites go through that accessor,
/// so none of them needed to change and new ones are covered by construction.
struct ShadowingSpiceDBService: SpiceDBServiceProtocol {
    let inner: any SpiceDBServiceProtocol
    let shadow: IAMShadowEvaluator
    let path: String
    let method: String
    let requestID: String?

    func checkPermission(
        subject: String, permission: String, resource: String, resourceId: String
    ) async throws -> Bool {
        let allowed = try await inner.checkPermission(
            subject: subject, permission: permission, resource: resource, resourceId: resourceId)
        shadow.shadowInBackground(
            IAMShadowCheck(
                subject: subject,
                permission: permission,
                resourceType: resource,
                resourceID: resourceId,
                spicedbAllowed: allowed,
                path: path,
                method: method,
                requestID: requestID
            ))
        return allowed
    }

    // Everything below forwards untouched: shadow evaluation observes
    // decisions, never writes or relationship state.

    func readSchema() async throws -> String? {
        try await inner.readSchema()
    }

    func writeSchema(_ schema: String) async throws {
        try await inner.writeSchema(schema)
    }

    func writeRelationship(
        entity: String, entityId: String, relation: String, subject: String, subjectId: String
    ) async throws {
        try await inner.writeRelationship(
            entity: entity, entityId: entityId, relation: relation, subject: subject, subjectId: subjectId)
    }

    func deleteRelationship(
        entity: String, entityId: String, relation: String, subject: String, subjectId: String
    ) async throws {
        try await inner.deleteRelationship(
            entity: entity, entityId: entityId, relation: relation, subject: subject, subjectId: subjectId)
    }

    func touchRelationships(_ tuples: [RelationshipTuple]) async throws {
        try await inner.touchRelationships(tuples)
    }

    func readRelationships(resourceType: String, relation: String?) async throws -> [RelationshipTuple] {
        try await inner.readRelationships(resourceType: resourceType, relation: relation)
    }

    func setOrganizationRole(
        userID: String, organizationID: String, oldRole: String?, newRole: String
    ) async throws {
        try await inner.setOrganizationRole(
            userID: userID, organizationID: organizationID, oldRole: oldRole, newRole: newRole)
    }

    func removeOrganizationMember(userID: String, organizationID: String, role: String) async throws {
        try await inner.removeOrganizationMember(userID: userID, organizationID: organizationID, role: role)
    }

    func addUserToGroup(userID: String, groupID: String) async throws {
        try await inner.addUserToGroup(userID: userID, groupID: groupID)
    }

    func removeUserFromGroup(userID: String, groupID: String) async throws {
        try await inner.removeUserFromGroup(userID: userID, groupID: groupID)
    }

    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await inner.addGroupToProject(groupID: groupID, projectID: projectID, role: role)
    }

    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await inner.removeGroupFromProject(groupID: groupID, projectID: projectID, role: role)
    }

    func checkGroupBasedPermission(
        userID: String, permission: String, resource: String, resourceId: String
    ) async throws -> Bool {
        try await inner.checkGroupBasedPermission(
            userID: userID, permission: permission, resource: resource, resourceId: resourceId)
    }
}

// MARK: - Application accessors

extension Application {
    private struct IAMShadowConfigKey: StorageKey {
        typealias Value = IAMShadowConfig
    }

    /// Shadow-evaluation configuration. Settable so tests can enable shadowing
    /// (off by default under `.testing`) before the evaluator is first built.
    var iamShadowConfig: IAMShadowConfig {
        get { storage[IAMShadowConfigKey.self] ?? .fromEnvironment(environment) }
        set { storage[IAMShadowConfigKey.self] = newValue }
    }

    private struct IAMShadowEvaluatorKey: StorageKey, LockKey {
        typealias Value = IAMShadowEvaluator
    }

    /// The shadow evaluator, created on first use with the current config.
    var iamShadow: IAMShadowEvaluator {
        lazyService(IAMShadowEvaluatorKey.self) {
            IAMShadowEvaluator(app: self, config: iamShadowConfig)
        }
    }

    /// The evaluator if something already created it — shutdown must not
    /// instantiate the service just to shut it down.
    var iamShadowIfCreated: IAMShadowEvaluator? {
        storage[IAMShadowEvaluatorKey.self]
    }
}

/// Arms the decision-log retention sweep at boot and cancels it at shutdown.
struct IAMShadowLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        // Armed regardless of `enabled`: the kill switch stops *new* rows, and
        // an operator who reaches for it because the table has grown is the
        // last person who should also lose the sweep that prunes it. The sweep
        // no-ops on its own when retention is disabled.
        application.iamShadow.startRetentionSweep()
    }

    func shutdownAsync(_ application: Application) async {
        application.iamShadowIfCreated?.shutdown()
    }
}
