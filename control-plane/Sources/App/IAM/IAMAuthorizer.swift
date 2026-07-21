import Fluent
import NIOConcurrencyHelpers
import Vapor

// IAM phase 5 (issue #482): the authoritative evaluator.
//
// Cedar now gates requests. Every check — middleware, `req.can`, and the ~55
// handler sites still speaking SpiceDB vocabulary through `req.spicedb` —
// funnels into `IAMAuthorizer.authorize`: load the entity slice, evaluate the
// compiled policy set inline, record the decision, and (while SpiceDB is still
// deployed, until #483) compare SpiceDB's verdict in the background as the
// reverse of the phase-4 shadow. The system-admin bypass is gone from code:
// admins are allowed by the `platform-system-admin` tier-1 policy, which means
// their decisions appear in the decision log and tier-2 guardrail forbids
// bind them like everyone else.

/// The SpiceDB question a check corresponds to, when it has one — carried so
/// the background comparison asks SpiceDB the *original* question rather than
/// a back-translation. Checks born in Cedar vocabulary (the middleware's, or
/// `iam:readPolicy`) may have no equivalent; they skip the comparison.
struct SpiceDBCheckEquivalent: Sendable {
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
/// request storage) so the Sendable `req.spicedb` decorator can carry it into
/// its check calls.
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
    ///
    /// Fails closed at every seam: no compiled policy set is a 503 (the
    /// replica cannot answer authorization questions, which is different from
    /// "no"), and an engine evaluation failure is a 500 — never a silent
    /// allow, never a silent deny that would look like policy.
    static func authorize(
        userID: UUID,
        action: String,
        node: IAMNode,
        spicedbEquivalent: SpiceDBCheckEquivalent?,
        context: IAMCheckContext,
        state: IAMRequestAuthState?,
        app: Application,
        db: any Database
    ) async throws -> CedarCheckDecision {
        guard let built = await app.cedarPolicySet.current else {
            // Boot builds the set before serving; reaching this means every
            // rebuild since has failed and there was never a good one. Denying
            // with 403 would look like policy — say what it is.
            app.logger.error("IAM check with no compiled Cedar policy set; failing closed")
            throw Abort(.serviceUnavailable, reason: "Authorization system is not ready")
        }

        let slice = try await EntitySliceLoader.load(userID: userID, node: node, on: db)

        let decision: CedarCheckDecision
        do {
            decision = try await built.artifact.authorize(
                principal: slice.principal,
                action: action,
                resource: slice.resource,
                context: slice.baseContextValue,
                entitiesJSON: slice.entitiesJSON())
        } catch {
            app.logger.error(
                "Cedar evaluation failed; failing closed",
                metadata: [
                    "action": .string(action),
                    "resource": .string("\(node.type.rawValue):\(node.id.uuidString)"),
                    "error": .string("\(error)"),
                ])
            throw Abort(.internalServerError, reason: "Authorization evaluation failed")
        }

        state?.decisionEvaluated.withLockedValue { $0 = true }
        if decision.allowed, decision.determiningPolicyIDs.contains("platform-system-admin") {
            state?.adminPolicyUsed.withLockedValue { $0 = true }
        }

        app.iamDecisionRecorder.recordInBackground(
            IAMDecisionRecord(
                subject: userID.uuidString,
                action: action,
                node: node,
                organizationID: slice.chain.first(where: { $0.type == .organization })?.id,
                skippedConditionedBindings: slice.skippedConditionedBindings,
                decision: decision,
                policyVersion: built.version,
                spicedbEquivalent: spicedbEquivalent,
                context: context
            ))

        return decision
    }

    /// Evaluate a check still phrased in the legacy SpiceDB vocabulary: the
    /// per-handler `req.can`/`req.authorize` form and every
    /// `req.spicedb.checkPermission` site. Translation failures fail closed —
    /// denied, logged, recorded — because an unmapped pair is a check site
    /// nobody mapped, not an allowance.
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
        let equivalent = SpiceDBCheckEquivalent(
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
            spicedbEquivalent: equivalent,
            context: context,
            state: state,
            app: app,
            db: db
        )
        return decision.allowed
    }
}

// MARK: - The authoritative `req.spicedb` decorator

/// Wraps the SpiceDB service so every *permission check* is answered by the
/// Cedar evaluator while every *write* still reaches SpiceDB (the dual-write
/// continues until #483 deletes it, keeping rollback open). Returned by
/// `Request.spicedb`, which is what makes the cutover total: all handler and
/// middleware check sites go through that accessor, so none of them needed to
/// change and new ones are covered by construction.
struct CedarAuthoritativeSpiceDBService: SpiceDBServiceProtocol {
    let inner: any SpiceDBServiceProtocol
    let app: Application
    let db: any Database
    let state: IAMRequestAuthState
    let context: IAMCheckContext

    func checkPermission(
        subject: String, permission: String, resource: String, resourceId: String
    ) async throws -> Bool {
        guard let userID = UUID(uuidString: subject) else {
            // Every check site passes a user id; anything else is a caller
            // bug, and the safe answer to a question about nobody is no.
            app.logger.error(
                "Authorization check with non-UUID subject denied",
                metadata: ["subject": .string(subject), "path": .string(context.path)])
            return false
        }
        return try await IAMAuthorizer.checkLegacyVocabulary(
            userID: userID,
            permission: permission,
            resourceType: resource,
            resourceID: resourceId,
            context: context,
            state: state,
            app: app,
            db: db
        )
    }

    /// Group-based checks collapse into the same evaluator: Cedar resolves
    /// group grants natively through the principal's group parent edges, so
    /// the direct/group distinction SpiceDB needed no longer exists.
    func checkGroupBasedPermission(
        userID: String, permission: String, resource: String, resourceId: String
    ) async throws -> Bool {
        try await checkPermission(
            subject: userID, permission: permission, resource: resource, resourceId: resourceId)
    }

    // Everything below forwards untouched: reads and relationship writes keep
    // SpiceDB's data fresh for the reverse shadow and the rollback window.

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
        spicedbEquivalent: SpiceDBCheckEquivalent? = nil
    ) async throws -> Bool {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        let decision = try await IAMAuthorizer.authorize(
            userID: userID,
            action: action,
            node: node,
            spicedbEquivalent: spicedbEquivalent,
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
        spicedbEquivalent: SpiceDBCheckEquivalent? = nil
    ) async throws {
        guard try await can(action, on: node, spicedbEquivalent: spicedbEquivalent) else {
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
