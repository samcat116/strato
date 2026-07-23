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
    static func authorize(
        principal: IAMPrincipal,
        action: String,
        node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent?,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        let clock = ContinuousClock()
        let start = clock.now
        return try await withSpan("iam.authorize", ofKind: .internal) { span in
            span.attributes["iam.action"] = action
            span.attributes["iam.resource_type"] = node.type.rawValue
            span.attributes["iam.principal"] = principal.subject
            let decision = try await evaluate(
                principal: principal,
                action: action,
                node: node,
                legacyEquivalent: legacyEquivalent,
                context: context,
                state: state,
                app: app,
                db: db
            )
            span.attributes["iam.decision"] = decision.allowed ? "allow" : "deny"
            Telemetry.recordAuthzDecision(
                allowed: decision.allowed, durationSeconds: (clock.now - start).asSeconds)
            return decision
        }
    }

    /// The uninstrumented check: `IAMDecisionEngine.decide` plus everything
    /// enforcement owes on top of a decision — the fail-closed error surface,
    /// the audit-state flags, and the decision-log row. `authorize(principal:…)`
    /// wraps this with the span and decision metrics.
    private static func evaluate(
        principal: IAMPrincipal,
        action: String,
        node: IAMNode,
        legacyEquivalent: LegacyCheckEquivalent?,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        let built = try await IAMDecisionEngine.compiledSet(app)

        let outcome: IAMDecisionEngine.Decision
        do {
            outcome = try await IAMDecisionEngine.decide(
                principal: principal, action: action, node: node, built: built, on: db)
        } catch let failure as IAMDecisionEngine.EvaluationFailure {
            app.logger.error(
                "Cedar evaluation failed; failing closed",
                metadata: [
                    "action": .string(action),
                    "resource": .string("\(node.type.rawValue):\(node.id.uuidString)"),
                    "error": .string("\(failure.underlying)"),
                ])
            throw Abort(.internalServerError, reason: "Authorization evaluation failed")
        }

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
            // Grants for roles the compiled schema doesn't declare are dropped
            // (under-grant) — a role created or deleted since this replica's
            // last rebuild. Transient by design (the version nudge or 30s
            // re-read converges it), but worth a trace when it happens.
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

        state?.decisionEvaluated.withLockedValue { $0 = true }
        if outcome.verdict.allowed, outcome.verdict.determiningPolicyIDs.contains("platform-system-admin") {
            state?.adminPolicyUsed.withLockedValue { $0 = true }
        }

        app.iamDecisionRecorder.recordInBackground(
            IAMDecisionRecord(
                subject: principal.subject,
                action: action,
                node: node,
                organizationID: outcome.slice.chain.first(where: { $0.type == .organization })?.id,
                skippedConditionedBindings: outcome.slice.skippedConditionedBindings,
                decision: outcome.verdict,
                policyVersion: built.version,
                legacyEquivalent: legacyEquivalent,
                context: context
            ))

        return outcome.verdict
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
            app: app,
            db: db
        )
        return decision.allowed
    }
}

extension Request {
    /// The authoritative check in the IAM action vocabulary — the primitive
    /// everything else (the legacy-vocabulary `can`, the middleware, the
    /// policy gate) resolves to.
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
            app: application,
            db: db
        )
        return decision.allowed
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

    /// Declare that this handler's authorization is row scoping or an
    /// open-by-design mutation (organization create: any authenticated user
    /// may start an org). Satisfies the default-deny middleware's handler
    /// assertion; using it is an explicit, greppable statement that "no
    /// evaluator decision" is the design, not an omission.
    func markRowScopedAuthorization() {
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
    }
}
