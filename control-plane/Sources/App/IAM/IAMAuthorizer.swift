import Fluent
import NIOConcurrencyHelpers
import Tracing
import Vapor

// Cedar gates requests. Every check — middleware or `req.can` — funnels into
// `IAMAuthorizer.authorize`: decide through
// `IAMDecisionEngine` (the one evaluator, shared with `WhoCanService`), record
// the decision. The system-admin bypass is gone from code: admins are allowed
// by the `platform-system-admin` tier-1 policy, which means their decisions
// appear in the decision log and tier-2 guardrail forbids bind them like
// everyone else.

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
    let adminPolicyUsed: NIOLockedValueBox<Bool>
    /// Whether any authorization decision was evaluated for this request at
    /// all. The default-deny middleware asserts this on handler-checked routes
    /// so a handler that forgets its check fails loudly instead of silently
    /// serving.
    let decisionEvaluated: NIOLockedValueBox<Bool>
    /// What the credential this request arrived on permits (STR-115). Rides
    /// here rather than as a parameter on `authorize` because it has exactly
    /// this object's lifetime — per-request, ambient, set once — and because a
    /// defaulted parameter is fail-*open* when a call site forgets it, which is
    /// the wrong failure mode for a ceiling.
    ///
    /// It belongs to the credential, not the principal, so it survives an
    /// impersonation: a user acting as a service account through a restricted
    /// key stays restricted.
    ///
    /// Held in a box rather than a `let` for the same fail-open reason. This
    /// object is created on first use, and "first use" is only guaranteed to be
    /// after authentication by middleware *ordering*, which nothing enforces —
    /// a future middleware registered above the authenticators that so much as
    /// reads `adminBypassUsed` would otherwise freeze `.unrestricted` here and
    /// hand every restricted credential on that request full principal power.
    /// `Request.iamAuthState` refreshes both fields on every access instead, so
    /// the answer is derived from the request rather than snapshotted from it.
    private let restrictionBox: NIOLockedValueBox<CredentialRestriction>
    private let credentialBox: NIOLockedValueBox<CredentialReference?>

    var restriction: CredentialRestriction { restrictionBox.withLockedValue { $0 } }
    /// Which credential that was, for decision-log attribution.
    var credential: CredentialReference? { credentialBox.withLockedValue { $0 } }

    init(restriction: CredentialRestriction = .unrestricted, credential: CredentialReference? = nil) {
        self.adminPolicyUsed = NIOLockedValueBox(false)
        self.decisionEvaluated = NIOLockedValueBox(false)
        self.restrictionBox = NIOLockedValueBox(restriction)
        self.credentialBox = NIOLockedValueBox(credential)
    }

    /// Re-derive the credential half from the request that owns this state.
    fileprivate func refreshCredential(
        restriction: CredentialRestriction, credential: CredentialReference?
    ) {
        restrictionBox.withLockedValue { $0 = restriction }
        credentialBox.withLockedValue { $0 = credential }
    }

    /// This state with the credential ceiling suspended (STR-203) — for the one
    /// kind of check an enforcement point *substitutes* for the question it is
    /// really gating, because at that moment it has nothing to gate yet.
    ///
    /// `GET /api/vms` is answered by `vm:read` on each row, but the middleware
    /// has no rows, so it asks "are you anyone in this organization at all"
    /// instead and leaves the per-row work to the handler. A restriction,
    /// though, is stated in the vocabulary of the *act* — `vm:read`, in project
    /// P — and neither half of that can be true of `org:read` on an
    /// organization: a project never appears in an organization's ancestor
    /// chain, and `vm:read` does not cover `org:read`. Intersecting the ceiling
    /// with the substituted question therefore denied it twice over, and a
    /// project-scoped token 403'd on the list while succeeding on every item
    /// route beneath it.
    ///
    /// So the ceiling is suspended for the probe and applied in full
    /// downstream, where there is an act to apply it to: `canFilter("vm:read")`
    /// on the list, `create_resources` on the resolved project for a create.
    /// **This is not a bypass** — the bindings half is decided exactly as
    /// before, so a non-member is refused here as it always was; what changes
    /// is that a *member* holding a narrowed token reaches the handler and gets
    /// a filtered, possibly empty page, which is what `/api/volumes` has always
    /// done for the same caller.
    ///
    /// Two things are deliberately *not* suspended. The audit flags are the
    /// same boxes, not copies: a probe allowed by `platform-system-admin` is
    /// still an admin bypass this request made, and a probe is still a decision
    /// the default-deny backstop must see. And the credential reference rides
    /// along, so the probe's decision row is attributed like any other —
    /// suspending the ceiling does not make the check anonymous.
    ///
    /// Do not reach for this at a site that is the *last* check before a
    /// resource is served.
    func membershipProbe() -> IAMRequestAuthState {
        // An unrestricted request asks the identical question either way, so it
        // keeps the identical object: the common session/user path is
        // byte-for-byte what it was.
        guard !restriction.isUnrestricted else { return self }
        return IAMRequestAuthState(suspendingCeilingOf: self)
    }

    /// The derived probe state. Frozen rather than refreshed, and that is safe
    /// here for the reason it would not be on the stored state: this object is
    /// built at the call site from a state the `Request.iamAuthState` accessor
    /// has just refreshed, used for exactly one check, and dropped. It never
    /// reaches request storage, so `refreshCredential` never sees it.
    private init(suspendingCeilingOf other: IAMRequestAuthState) {
        self.adminPolicyUsed = other.adminPolicyUsed
        self.decisionEvaluated = other.decisionEvaluated
        self.restrictionBox = NIOLockedValueBox(.unrestricted)
        self.credentialBox = NIOLockedValueBox(other.credential)
    }

    /// The state for a check that is not serving a request: `WhoCanService`'s
    /// reporting, the policy simulator, tests. Named rather than defaulted so
    /// "this check has no credential behind it" is a deliberate, greppable
    /// statement instead of an omission.
    static let detached = IAMRequestAuthState()
}

extension Request {
    private struct IAMRequestAuthStateKey: StorageKey {
        typealias Value = IAMRequestAuthState
    }

    /// This request's authorization state, created on first use.
    ///
    /// The audit flags accumulate across the request, so the object persists;
    /// the credential half is re-derived on every access, so a state that
    /// happened to be created before the authenticators ran cannot leave a
    /// restricted credential looking unrestricted (see `restrictionBox`).
    var iamAuthState: IAMRequestAuthState {
        if let existing = storage[IAMRequestAuthStateKey.self] {
            existing.refreshCredential(restriction: credentialRestriction, credential: credential)
            return existing
        }
        let created = IAMRequestAuthState(restriction: credentialRestriction, credential: credential)
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
        context: IAMCheckContext,
        state: IAMRequestAuthState,
        cache: IAMRequestCache? = nil,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        try await authorize(
            principal: .user(userID),
            action: action,
            node: node,
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
        context: IAMCheckContext,
        state: IAMRequestAuthState,
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
            let key = IAMRequestCache.DecisionKey(
                principal: principal, action: action, node: node, restriction: state.restriction)
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
    static func authorize(
        principal: IAMPrincipal,
        action: String,
        nodes: [IAMNode],
        context: IAMCheckContext,
        state: IAMRequestAuthState,
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
                let key = IAMRequestCache.DecisionKey(
                    principal: principal, action: action, node: node, restriction: state.restriction)
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
    private static func markAuditState(_ decision: CedarCheckDecision, state: IAMRequestAuthState) {
        state.decisionEvaluated.withLockedValue { $0 = true }
        if decision.allowed, decision.determiningPolicyIDs.contains("platform-system-admin") {
            state.adminPolicyUsed.withLockedValue { $0 = true }
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
        context: IAMCheckContext,
        state: IAMRequestAuthState,
        cache: IAMRequestCache?,
        app: Application,
        db: any Database
    ) async throws -> [IAMNode: CedarCheckDecision] {
        let built = try await IAMDecisionEngine.compiledSet(app)
        let targets = nodes.map { IAMCheckTarget(principal: principal, node: $0) }

        let outcomes: [IAMCheckTarget: IAMDecisionEngine.Decision]
        do {
            outcomes = try await app.policySetVersion.withIAMPersistence { iam in
                try await IAMDecisionEngine.decide(
                    targets,
                    action: action,
                    built: built,
                    cache: cache,
                    restriction: state.restriction,
                    using: iam,
                    on: db
                )
            }
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
                for: IAMRequestCache.DecisionKey(
                    principal: principal, action: action, node: node, restriction: state.restriction))
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
                    credential: state.credential,
                    context: context
                ))
        }

        await app.iamDecisionRecorder.record(records)
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

}

extension Request {
    /// The authoritative check in the IAM action vocabulary.
    ///
    /// Asks about the request's *acting principal*: the authenticated user, or
    /// the service account / workload a JWT-SVID resolved to (issue #495). The
    /// evaluator has taken a typed principal since #491, so machine principals
    /// are evaluated by the same policy set against the same bindings.
    ///
    /// - Throws: `.unauthorized` if unauthenticated; `.serviceUnavailable` /
    ///   `.internalServerError` when the evaluator cannot answer (fail
    ///   closed).
    func can(_ action: String, on node: IAMNode) async throws -> Bool {
        let principal = try requireActingPrincipal()
        let decision = try await IAMAuthorizer.authorize(
            principal: principal,
            action: action,
            node: node,
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
        let principal = try requireActingPrincipal()
        let decisions = try await IAMAuthorizer.authorize(
            principal: principal,
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
    func authorize(_ action: String, on node: IAMNode) async throws {
        guard try await can(action, on: node) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    /// `can(_:on:)` for a **membership probe** — a check that stands in for
    /// the question actually being gated, decided with this request's
    /// credential ceiling suspended (STR-203).
    ///
    /// See `IAMRequestAuthState.membershipProbe()` for why the substitution and
    /// the ceiling cannot both be applied, and for when this is emphatically
    /// the wrong spelling: it belongs only where a per-resource decision on the
    /// same request stands behind it.
    func canAsMembershipProbe(_ action: String, on node: IAMNode) async throws -> Bool {
        let principal = try requireActingPrincipal()
        let decision = try await IAMAuthorizer.authorize(
            principal: principal,
            action: action,
            node: node,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: self.id),
            state: iamAuthState.membershipProbe(),
            cache: iamCache,
            app: application,
            db: db
        )
        return decision.allowed
    }

    /// Gate a deliberately admin-only surface (hierarchy repair, audit-event
    /// queries, decision logs, workload identity — platform plumbing with no
    /// node in the IAM tree to attach a policy to).
    ///
    /// This is a gate, not a bypass: it can only *deny*, and it satisfies the
    /// default-deny middleware's handler assertion so admin-only mutations
    /// count as having made an authorization decision.
    ///
    /// System administrator is a property of a *user* record, so a machine
    /// principal can never satisfy this gate. It is denied explicitly (403 with
    /// a reason) rather than falling through to the bare 401 a missing user
    /// would produce: the credential authenticated, it simply cannot hold this
    /// privilege (issue #495).
    ///
    /// A restricted credential is refused here too, because there is no action
    /// to intersect its restriction with (STR-115). A node-scoped credential is
    /// refused outright — a token issued for one project has no business on a
    /// global platform surface — and a read-only one only on mutations.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.forbidden` for
    ///   non-admins, workload principals, and restricted credentials.
    func requireSystemAdmin(_ deniedReason: String = "System administrator access required") async throws -> User {
        guard let user = auth.get(User.self) else {
            iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
            if isWorkloadAuthenticated {
                throw Abort(.forbidden, reason: deniedReason)
            }
            throw Abort(.unauthorized)
        }
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: deniedReason)
        }
        try await denyRestrictedCredential(on: .platformAdminSurface)
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
    ///
    /// - Parameter action: the action the row would be listed under
    ///   (`agent:list`, `operation:read`). A credential restriction applies
    ///   here as far as it can: the action half against `action`, and the node
    ///   half by refusing outright — a scopeless row is by definition outside
    ///   every subtree, so a subtree-scoped credential should not see it. A
    ///   legacy `read` credential, whose restriction is every `:read` and
    ///   `:list` and has no node, keeps seeing exactly the rows it sees today.
    func allowsScopelessPlatformRow(action: String) -> Bool {
        // An action the registry does not know matches no restriction pattern,
        // so a typo here would quietly hide every scopeless row from every
        // restricted credential — a filtering bug that looks like policy.
        // `precondition`, not `assert`: `assert` compiles out under `-O`, which
        // is exactly the build the failure would ship in. Every call site
        // passes a literal, so this can only fire on a wrong binary — never on
        // input — and it fires on the first such request in any environment.
        precondition(
            IAMRoleRegistry.allActions.contains(action),
            "allowsScopelessPlatformRow called with '\(action)', which is not a registry action")
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
        guard let user = auth.get(User.self), user.isSystemAdmin else { return false }
        let restriction = iamAuthState.restriction
        guard restriction.node == nil, restriction.permits(action: action) else { return false }
        iamAuthState.adminPolicyUsed.withLockedValue { $0 = true }
        return true
    }

    /// Declare that this handler's authorization is row scoping or an
    /// open-by-design mutation (organization create: any authenticated user
    /// may start an org). Satisfies the default-deny middleware's handler
    /// assertion; using it is an explicit, greppable statement that "no
    /// evaluator decision" is the design, not an omission.
    ///
    /// Throws for a restricted credential on a mutation: row scoping says who
    /// the rows belong to, not what a token may do to them, so there is nothing
    /// here for a restriction to intersect with (STR-115).
    func markRowScopedAuthorization() async throws {
        iamAuthState.decisionEvaluated.withLockedValue { $0 = true }
        try await denyRestrictedCredential(on: .rowScopedMutation)
    }

    /// Refuse a restricted credential that reached a surface with no evaluator
    /// decision behind it, recording the refusal so it is attributable in
    /// `iam_decision_logs` like every other denial.
    ///
    /// Safe methods pass: these surfaces read the caller's own rows or platform
    /// inventory, and the restriction's action half is checked where an action
    /// exists to check it (`allowsScopelessPlatformRow`). A node-scoped
    /// credential is refused on any method — nothing here lives under a node.
    private func denyRestrictedCredential(on reason: CredentialDenialReason) async throws {
        let restriction = iamAuthState.restriction
        guard !restriction.isUnrestricted else { return }
        if restriction.node == nil {
            switch method {
            case .GET, .HEAD, .OPTIONS: return
            default: break
            }
        }
        await recordCredentialRestrictionDenial(reason)
        throw Abort(.forbidden, reason: reason.deniedReason)
    }

    /// Write the decision row for a credential refused outside the evaluator.
    func recordCredentialRestrictionDenial(_ reason: CredentialDenialReason) async {
        // The acting principal's own subject spelling, so the row matches every
        // other decision-log subject rather than reconstructing the user UUID
        // here and drifting if that convention ever changes.
        await application.iamDecisionRecorder.recordCredentialRestriction(
            subject: actingPrincipal?.subject ?? "",
            credential: credential,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: id))
    }
}
