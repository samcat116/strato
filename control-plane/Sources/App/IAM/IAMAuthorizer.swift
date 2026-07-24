import Fluent
import NIOConcurrencyHelpers
import Tracing
import Vapor

// IAM phase 5 (issue #482): the authoritative evaluator. SpiceDB itself is
// gone (issue #483); the legacy permission vocabulary survives only as the
// `req.can(_:on:id:)` spelling that `IAMActionTranslator` maps into IAM
// actions.
//
// Cedar gates requests. Every check — middleware, `req.can` in either
// vocabulary — funnels into `IAMAuthorizer.authorize`: decide through
// `IAMDecisionEngine` (the one evaluator, shared with `WhoCanService`), record
// the decision. The system-admin bypass is gone from code: admins are allowed
// by the `platform-system-admin` tier-1 policy, which means their decisions
// appear in the decision log and tier-2 guardrail forbids bind them like
// everyone else.

/// The legacy-vocabulary question a check was phrased in, when it has one —
/// carried into the decision log so rows record what was literally asked at
/// the check site, not a back-translation. Checks born in the IAM action
/// vocabulary (the middleware's, or `iam:readPolicy`) have none.
struct LegacyCheckEquivalent: Sendable {
    let permission: String
    let resourceType: String
    let resourceID: String
}

/// Request coordinates for the decision log.
struct IAMCheckContext: Sendable {
    let path: String
    let method: String
    let requestID: String?
}

/// Per-request authorization state shared between the evaluator entry points
/// and the middleware/audit layers. A class with locked fields (not plain
/// request storage) so Sendable helpers can carry it into their check calls.
final class IAMRequestAuthState: Sendable {
    /// Whether any decision this request was allowed by the
    /// `platform-system-admin` policy — the audit trail's admin-bypass marker,
    /// now derived from the evaluator instead of a code short-circuit.
    let adminPolicyUsed = NIOLockedValueBox(false)
    /// Whether any authorization decision was evaluated for this request at
    /// all. The default-deny middleware asserts this on handler-checked routes
    /// so a handler that forgets its check fails loudly instead of silently
    /// serving.
    let decisionEvaluated = NIOLockedValueBox(false)
}

extension Request {
    private struct IAMRequestAuthStateKey: StorageKey {
        typealias Value = IAMRequestAuthState
    }

    /// This request's authorization state, created on first use.
    var iamAuthState: IAMRequestAuthState {
        if let existing = storage[IAMRequestAuthStateKey.self] { return existing }
        let created = IAMRequestAuthState()
        storage[IAMRequestAuthStateKey.self] = created
        return created
    }
}

/// The authoritative Cedar check (issue #482).
enum IAMAuthorizer {

    /// Evaluate "may `userID` perform `action` on `node`?" against the
    /// compiled policy set, record the decision, and return it.
    static func authorize(
        userID: UUID,
        action: String,
        node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent?,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        cache: IAMRequestCache? = nil,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        try await authorize(
            principal: .user(userID),
            action: action,
            node: node,
            legacyEquivalent: legacyEquivalent,
            context: context,
            state: state,
            cache: cache,
            app: app,
            db: db
        )
    }

    /// Evaluate "may `principal` perform `action` on `node`?" — the typed
    /// form covering machine principals (issue #491) as well as users.
    ///
    /// Fails closed at every seam: no compiled policy set is a 503 (the
    /// replica cannot answer authorization questions, which is different from
    /// "no"), and an engine evaluation failure is a 500 — never a silent
    /// allow, never a silent deny that would look like policy.
    ///
    /// Every check funnels here, so this is where authorization is observed: a
    /// span per evaluation (nesting under the request span) plus the allow/deny
    /// rate and evaluation latency as metrics. A thrown 503/500 records the
    /// error on the span but is not counted as an allow/deny decision.
    ///
    /// A repeat of a triple this request already decided is answered from
    /// `cache` (#686) — the object routes ask the same question twice on
    /// purpose, middleware then handler. The repeat still gets a span (marked
    /// `iam.cache_hit`) so the double-check stays visible in a trace, but it is
    /// not counted as a second decision or written to the decision log: it is
    /// one decision, consulted twice.
    static func authorize(
        principal: IAMPrincipal,
        action: String,
        node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent?,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        cache: IAMRequestCache? = nil,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        let clock = ContinuousClock()
        let start = clock.now
        return try await withSpan("iam.authorize", ofKind: .internal) { span in
            span.attributes["iam.action"] = action
            span.attributes["iam.resource_type"] = node.type.rawValue
            span.attributes["iam.principal"] = principal.subject
            let key = IAMRequestCache.DecisionKey(principal: principal, action: action, node: node)
            if let memoized = cache?.decision(for: key) {
                span.attributes["iam.cache_hit"] = true
                span.attributes["iam.decision"] = memoized.allowed ? "allow" : "deny"
                markAuditState(memoized, state: state)
                return memoized
            }
            let decisions = try await evaluate(
                principal: principal,
                action: action,
                nodes: [node],
                legacyEquivalents: legacyEquivalent.map { [node: $0] } ?? [:],
                context: context,
                state: state,
                cache: cache,
                app: app,
                db: db
            )
            guard let decision = decisions[node] else {
                // Unreachable: the batch is total over its inputs. Failing
                // closed beats a force-unwrap in the enforcement path.
                throw Abort(.internalServerError, reason: "Authorization evaluation failed")
            }
            span.attributes["iam.cache_hit"] = false
            span.attributes["iam.decision"] = decision.allowed ? "allow" : "deny"
            Telemetry.recordAuthzDecision(
                allowed: decision.allowed, durationSeconds: (clock.now - start).asSeconds)
            return decision
        }
    }

    /// Evaluate one action for one principal over many nodes (#687) — the
    /// list-filtering primitive behind `Request.canFilter`.
    ///
    /// A list endpoint used to pay a full evaluation per row: a hundred VMs
    /// meant ~700 queries and a hundred decision-log inserts to answer one
    /// question a hundred times. Here the whole batch shares one entity-slice
    /// load, and the decision rows go in as one insert.
    ///
    /// The decisions are the same decisions the per-node path makes — same
    /// evaluator, same compiled set, same recording — so a filtered list agrees
    /// with the object route it links to. Nodes already decided this request
    /// are answered from `cache` and not re-recorded.
    ///
    /// - Parameter legacyEquivalents: the legacy-vocabulary question each node
    ///   was asked in, for the callers that still speak it (the batch check
    ///   endpoint). The decision log records what was literally asked at the
    ///   check site, so a batched legacy check must carry its phrasing exactly
    ///   as the per-check path does.
    static func authorize(
        principal: IAMPrincipal,
        action: String,
        nodes: [IAMNode],
        legacyEquivalents: [IAMNode: LegacyCheckEquivalent] = [:],
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        cache: IAMRequestCache? = nil,
        app: Application,
        db: any Database
    ) async throws -> [IAMNode: CedarCheckDecision] {
        guard !nodes.isEmpty else { return [:] }
        let clock = ContinuousClock()
        let start = clock.now
        return try await withSpan("iam.authorize_batch", ofKind: .internal) { span in
            span.attributes["iam.action"] = action
            span.attributes["iam.principal"] = principal.subject
            span.attributes["iam.batch_size"] = nodes.count

            var decisions: [IAMNode: CedarCheckDecision] = [:]
            var pending: [IAMNode] = []
            for node in Set(nodes) {
                let key = IAMRequestCache.DecisionKey(principal: principal, action: action, node: node)
                if let memoized = cache?.decision(for: key) {
                    markAuditState(memoized, state: state)
                    decisions[node] = memoized
                } else {
                    pending.append(node)
                }
            }
            span.attributes["iam.cache_hits"] = decisions.count
            guard !pending.isEmpty else { return decisions }

            let evaluated = try await evaluate(
                principal: principal,
                action: action,
                nodes: pending,
                legacyEquivalents: legacyEquivalents,
                context: context,
                state: state,
                cache: cache,
                app: app,
                db: db
            )
            decisions.merge(evaluated) { _, new in new }

            // One elapsed time covers the batch, so the per-decision timer gets
            // the amortized share — the number an operator reads as "what a
            // check costs", which is exactly what batching changed.
            let perDecision = (clock.now - start).asSeconds / Double(evaluated.count)
            for decision in evaluated.values {
                Telemetry.recordAuthzDecision(allowed: decision.allowed, durationSeconds: perDecision)
            }
            span.attributes["iam.allowed"] = decisions.values.filter(\.allowed).count
            return decisions
        }
    }

    /// The audit flags a decision sets, applied on every consultation — a
    /// memoized answer is still an answer this request acted on, and the
    /// default-deny middleware's "did the handler check anything?" assertion
    /// must see it.
    private static func markAuditState(_ decision: CedarCheckDecision, state: IAMRequestAuthState?) {
        state?.decisionEvaluated.withLockedValue { $0 = true }
        if decision.allowed, decision.determiningPolicyIDs.contains("platform-system-admin") {
            state?.adminPolicyUsed.withLockedValue { $0 = true }
        }
    }

    /// The uninstrumented check: `IAMDecisionEngine.decide` plus everything
    /// enforcement owes on top of a decision — the fail-closed error surface,
    /// the audit-state flags, the memoization, and the decision-log rows. Both
    /// `authorize` entry points wrap this with their span and decision metrics,
    /// so a batched list decision and a single object check are the same
    /// decision made the same way.
    private static func evaluate(
        principal: IAMPrincipal,
        action: String,
        nodes: [IAMNode],
        legacyEquivalents: [IAMNode: LegacyCheckEquivalent],
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        cache: IAMRequestCache?,
        app: Application,
        db: any Database
    ) async throws -> [IAMNode: CedarCheckDecision] {
        let built = try await IAMDecisionEngine.compiledSet(app)
        let targets = nodes.map { IAMCheckTarget(principal: principal, node: $0) }

        let outcomes: [IAMCheckTarget: IAMDecisionEngine.Decision]
        do {
            outcomes = try await IAMDecisionEngine.decide(
                targets, action: action, built: built, cache: cache, on: db)
        } catch let failure as IAMDecisionEngine.EvaluationFailure {
            app.logger.error(
                "Cedar evaluation failed; failing closed",
                metadata: [
                    "action": .string(action),
                    "resource": .string(resourceMetadata(nodes)),
                    "error": .string("\(failure.underlying)"),
                ])
            throw Abort(.internalServerError, reason: "Authorization evaluation failed")
        }

        var decisions: [IAMNode: CedarCheckDecision] = [:]
        decisions.reserveCapacity(outcomes.count)
        var records: [IAMDecisionRecord] = []
        records.reserveCapacity(outcomes.count)

        for (target, outcome) in outcomes {
            let node = target.node
            if outcome.deniedForTruncatedChain {
                app.logger.error(
                    "IAM check denied: ancestor chain does not reach an organization; a guardrail anchored above the break could not apply",
                    metadata: [
                        "action": .string(action),
                        "resource": .string("\(node.type.rawValue):\(node.id.uuidString)"),
                        "chain": .string(
                            outcome.slice.chain.map { "\($0.type.rawValue):\($0.id.uuidString)" }
                                .joined(separator: " -> ")),
                    ])
            } else {
                // Grants for roles the compiled schema doesn't declare are
                // dropped (under-grant) — a role created or deleted since this
                // replica's last rebuild. Transient by design (the version
                // nudge or 30s re-read converges it), but worth a trace when it
                // happens.
                let droppedRoleIDs = outcome.slice.grants.roleIDs.subtracting(built.roleIDs)
                if !droppedRoleIDs.isEmpty {
                    app.logger.info(
                        "IAM check dropped grants for roles the compiled policy set does not know yet",
                        metadata: [
                            "role_ids": .string(droppedRoleIDs.map(\.uuidString).sorted().joined(separator: ",")),
                            "policy_version": .stringConvertible(built.version),
                        ])
                }
            }

            markAuditState(outcome.verdict, state: state)
            cache?.store(
                decision: outcome.verdict,
                for: IAMRequestCache.DecisionKey(principal: principal, action: action, node: node))
            decisions[node] = outcome.verdict
            records.append(
                IAMDecisionRecord(
                    subject: principal.subject,
                    action: action,
                    node: node,
                    organizationID: outcome.slice.chain.first(where: { $0.type == .organization })?.id,
                    skippedConditionedBindings: outcome.slice.skippedConditionedBindings,
                    decision: outcome.verdict,
                    policyVersion: built.version,
                    legacyEquivalent: legacyEquivalents[node],
                    context: context
                ))
        }

        app.iamDecisionRecorder.recordInBackground(records)
        return decisions
    }

    /// The `resource` log field for a failed evaluation: the node for a single
    /// check, a count for a batch (naming a hundred VMs would bury the error).
    private static func resourceMetadata(_ nodes: [IAMNode]) -> String {
        guard let first = nodes.first, nodes.count == 1 else {
            return "\(nodes.count) nodes"
        }
        return "\(first.type.rawValue):\(first.id.uuidString)"
    }

    /// Evaluate a check still phrased in the legacy (pre-Cedar) permission
    /// vocabulary: the per-handler `req.can`/`req.authorize` form and the
    /// middleware's method/path-derived checks. Translation failures fail
    /// closed — denied, logged, recorded — because an unmapped pair is a check
    /// site nobody mapped, not an allowance.
    static func checkLegacyVocabulary(
        userID: UUID,
        permission: String,
        resourceType: String,
        resourceID: String,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        cache: IAMRequestCache? = nil,
        app: Application,
        db: any Database
    ) async throws -> Bool {
        let equivalent = LegacyCheckEquivalent(
            permission: permission, resourceType: resourceType, resourceID: resourceID)
        guard
            let translation = IAMActionTranslator.translate(
                permission: permission,
                resourceType: resourceType,
                resourceID: resourceID,
                path: context.path)
        else {
            app.logger.error(
                "Untranslatable authorization check denied (no IAM action mapping)",
                metadata: [
                    "permission": .string(permission),
                    "resource": .string("\(resourceType):\(resourceID)"),
                    "path": .string(context.path),
                ])
            state?.decisionEvaluated.withLockedValue { $0 = true }
            app.iamDecisionRecorder.recordUntranslatedDenial(
                subject: userID.uuidString, equivalent: equivalent, context: context)
            return false
        }
        let decision = try await authorize(
            userID: userID,
            action: translation.action,
            node: translation.node,
            legacyEquivalent: equivalent,
            context: context,
            state: state,
            cache: cache,
            app: app,
            db: db
        )
        return decision.allowed
    }
}

extension Request {
    /// The authoritative check in the IAM action vocabulary — the primitive
    /// everything else (the legacy-vocabulary `can`, the middleware, the
    /// controllers' policy-admin gates) resolves to.
    ///
    /// - Throws: `.unauthorized` if unauthenticated; `.serviceUnavailable` /
    ///   `.internalServerError` when the evaluator cannot answer (fail
    ///   closed).
    func can(
        _ action: String,
        on node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent? = nil
    ) async throws -> Bool {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        let decision = try await IAMAuthorizer.authorize(
            userID: userID,
            action: action,
            node: node,
            legacyEquivalent: legacyEquivalent,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: id),
            state: iamAuthState,
            cache: iamCache,
            app: application,
            db: db
        )
        return decision.allowed
    }

    /// Scope a list: the subset of `nodes` the current user may `action`,
    /// decided in one batch (#687).
    ///
    /// The list-filtering counterpart to `can` — same evaluator, same compiled
    /// set, same decision log — for handlers that would otherwise loop `can`
    /// per row and turn a page of results into hundreds of queries. Callers
    /// filter their own rows against the returned set, keeping their ordering
    /// and their DTO mapping.
    ///
    /// - Throws: `.unauthorized` if unauthenticated; `.serviceUnavailable` /
    ///   `.internalServerError` when the evaluator cannot answer (fail
    ///   closed) — a list that cannot be scoped is an error, never a
    ///   silently-empty page.
    func canFilter(_ action: String, on nodes: [IAMNode]) async throws -> Set<IAMNode> {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        let decisions = try await IAMAuthorizer.authorize(
            principal: .user(userID),
            action: action,
            nodes: nodes,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: id),
            state: iamAuthState,
            cache: iamCache,
            app: application,
            db: db
        )
        return Set(decisions.filter { $0.value.allowed }.keys)
    }

    /// Enforce `action` on `node`, throwing `.forbidden` when denied.
    func authorize(
        _ action: String,
        on node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent? = nil
    ) async throws {
        guard try await can(action, on: node, legacyEquivalent: legacyEquivalent) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    /// Whether the current user holds `permission` on the given resource, in
    /// the legacy (pre-Cedar) permission vocabulary. This spelling survives so
    /// the ~55 handler sites need not churn: it translates the
    /// (permission, resourceType) pair to the IAM action naming the act being
    /// gated — the same mapping shadow evaluation validated — and evaluates it
    /// through `checkLegacyVocabulary`. New code should prefer the
    /// action-vocabulary form above.
    ///
    /// There is no system-admin short-circuit anymore: admins are allowed by
    /// the `platform-system-admin` tier-1 policy, which lands their decisions
    /// in the decision log and lets guardrail forbids bind them.
    ///
    /// A pair the translator cannot map fails closed — denied, logged, and
    /// recorded as `untranslated` in the decision log — because an
    /// untranslatable check is a check site nobody mapped, not an allowance.
    ///
    /// - Throws: `.unauthorized` if the request is unauthenticated.
    func can(_ permission: String, on resourceType: String, id: String) async throws -> Bool {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        return try await IAMAuthorizer.checkLegacyVocabulary(
            userID: userID,
            permission: permission,
            resourceType: resourceType,
            resourceID: id,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: self.id),
            state: iamAuthState,
            cache: iamCache,
            app: application,
            db: db
        )
    }

    /// Enforce `permission` on the given resource, throwing `.forbidden` when
    /// the current user lacks it.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.forbidden` if the check fails.
    func authorize(_ permission: String, on resourceType: String, id: String) async throws {
        guard try await can(permission, on: resourceType, id: id) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    /// Convenience overload taking a `UUID` resource id.
    func authorize(_ permission: String, on resourceType: String, id: UUID) async throws {
        try await authorize(permission, on: resourceType, id: id.uuidString)
    }

    /// Gate a deliberately admin-only surface (hierarchy repair, audit-event
    /// queries, decision logs, workload identity — platform plumbing with no
    /// node in the IAM tree to attach a policy to).
    ///
    /// This is a gate, not a bypass: it can only *deny*, and it satisfies the
    /// default-deny middleware's handler assertion so admin-only mutations
    /// count as having made an authorization decision.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.forbidden` for
    ///   non-admins.
    func requireSystemAdmin(_ deniedReason: String = "System administrator access required") throws -> User {
        guard let user = auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: deniedReason)
        }
        // Admin-privileged access outside the IAM tree still belongs in the
        // admin audit trail (pre-cutover, the middleware bypass flagged every
        // admin request; the evaluator now flags evaluator-gated ones, and
        // this keeps the admin-only surfaces covered too).
        iamAuthState.adminPolicyUsed.withLockedValue { $0 = true }
        return user
    }

    /// The list-side companion to `requireSystemAdmin()`, for a row that has
    /// no IAM node to check: a pre-scoping agent, agent enrollment, or
    /// floating-IP pool with no owning organization. The item endpoints gate
    /// these with `requireSystemAdmin()`; a list must decide per row rather
    /// than throw, so this returns the same verdict as a Bool and marks the
    /// same audit state.
    ///
    /// Like the throwing form this can only *deny*: a scoped row never reaches
    /// it, because a scoped row has a node and goes through `can`.
    func allowsScopelessPlatformRow() -> Bool {
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
        guard let user = auth.get(User.self), user.isSystemAdmin else { return false }
        iamAuthState.adminPolicyUsed.withLockedValue { $0 = true }
        return true
    }

    /// Declare that this handler's authorization is row scoping or an
    /// open-by-design mutation (organization create: any authenticated user
    /// may start an org). Satisfies the default-deny middleware's handler
    /// assertion; using it is an explicit, greppable statement that "no
    /// evaluator decision" is the design, not an omission.
    func markRowScopedAuthorization() {
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
    }
}
