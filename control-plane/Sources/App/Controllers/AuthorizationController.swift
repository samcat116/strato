import Fluent
import Vapor

/// The authorization query surface: "can I?", "can *they*?", and "who can?".
///
/// Read-only — it answers questions about access and never mutates anything.
/// Two of the four APIs the design calls for on day one of the new IAM system
/// (docs/architecture/iam.md); the policy simulator and decision logs land with
/// later phases.
struct AuthorizationController: RouteCollection {
    /// Cap on checks per request — keeps a single call bounded.
    private static let maxChecks = 50

    func boot(routes: RoutesBuilder) throws {
        let authorization = routes.grouped("api", "authorization")
        authorization.post("check", use: check)
        authorization.post("who-can", use: whoCan)
    }

    struct PermissionCheckItem: Content {
        /// Opaque client-chosen id echoed back in the response, so the caller can
        /// correlate answers to the UI element they gate.
        let key: String
        let resourceType: String
        let resourceId: String
        let permission: String
    }

    /// The subject of a check, when it is not the caller.
    struct PrincipalRequest: Content {
        let type: IAMPrincipalType
        let id: UUID
    }

    struct CheckRequest: Content {
        let checks: [PermissionCheckItem]
        /// When present, the checks are evaluated for this principal instead of
        /// the caller. Admin-gated, and answered from the bindings table — see
        /// `check`.
        let principal: PrincipalRequest?

        init(checks: [PermissionCheckItem], principal: PrincipalRequest? = nil) {
            self.checks = checks
            self.principal = principal
        }
    }

    struct CheckResponse: Content {
        let results: [String: Bool]
    }

    /// POST /api/authorization/check
    ///
    /// Body: `{ "checks": [ { "key", "resourceType", "resourceId", "permission" } ],
    ///          "principal": { "type", "id" }? }`
    /// Returns: `{ "results": { "<key>": true/false, ... } }`
    ///
    /// Both forms are decided by the same evaluator (`IAMDecisionEngine`) over
    /// the same compiled policy set, so every answer is the answer enforcement
    /// would give — guardrails, authored policies, and platform permits
    /// included:
    ///
    /// - **No `principal`** (the caller asks about themselves): the
    ///   authoritative enforcement path (`req.can`), which records a decision
    ///   log row. `permission` accepts an IAM action name (`vm:start`) or, for
    ///   callers not yet migrated, a legacy permission name (`manage_project`),
    ///   translated the same way `req.can` translates.
    /// - **With `principal`**: admin-gated reporting (`WhoCanService.can`) —
    ///   same decision, no decision-log row, plus the reachability gates a
    ///   real request would have hit first (disabled or nonexistent principals
    ///   answer false). `permission` is an IAM action name. A *group*
    ///   principal is answered from its bindings — a group never reaches the
    ///   evaluator itself.
    ///
    /// There is no admin fast path: guardrail forbids bind system admins, so
    /// short-circuiting to "true" could report an allow the evaluator would
    /// refuse.
    func check(req: Request) async throws -> CheckResponse {
        guard let user = req.auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }

        let payload = try req.content.decode(CheckRequest.self)

        guard !payload.checks.isEmpty else {
            return CheckResponse(results: [:])
        }
        guard payload.checks.count <= Self.maxChecks else {
            throw Abort(.badRequest, reason: "Too many checks (max \(Self.maxChecks))")
        }

        if let principal = payload.principal {
            return try await checkForPrincipal(principal, payload.checks, caller: user, req: req)
        }

        var results: [String: Bool] = [:]
        for item in payload.checks {
            // Action names carry a `:`; anything else is the legacy
            // vocabulary and goes through the same translation as `req.can`.
            if item.permission.contains(":") {
                let node = try Self.node(resourceType: item.resourceType, resourceId: item.resourceId)
                results[item.key] = try await req.can(item.permission, on: node)
            } else {
                results[item.key] = try await IAMAuthorizer.checkLegacyVocabulary(
                    userID: userID,
                    permission: item.permission,
                    resourceType: item.resourceType,
                    resourceID: item.resourceId,
                    context: IAMCheckContext(
                        path: req.url.path, method: req.method.rawValue, requestID: req.id),
                    state: req.iamAuthState,
                    app: req.application,
                    db: req.db
                )
            }
        }
        return CheckResponse(results: results)
    }

    /// Evaluate checks on behalf of another principal, from the bindings table.
    private func checkForPrincipal(
        _ principal: PrincipalRequest, _ checks: [PermissionCheckItem], caller: User, req: Request
    ) async throws -> CheckResponse {
        // Gate each distinct resource once: a batch may ask fifty questions
        // about the same VM, and the gate is a tree walk plus evaluator calls.
        var gated: Set<IAMNode> = []
        var results: [String: Bool] = [:]
        for item in checks {
            let node = try Self.node(resourceType: item.resourceType, resourceId: item.resourceId)
            if gated.insert(node).inserted {
                try await Self.requirePolicyRead(on: node, caller: caller, req: req)
            }
            results[item.key] = try await WhoCanService.can(
                principalType: principal.type,
                principalID: principal.id,
                action: item.permission,
                node: node,
                app: req.application,
                on: req.db
            )
        }
        return CheckResponse(results: results)
    }

    // MARK: - who-can

    struct WhoCanRequest: Content {
        let resourceType: String
        let resourceId: String
        let action: String
    }

    struct WhoCanResponse: Content {
        let resource: IAMNode
        let action: String
        /// The chain the answer was assembled from, resource first — makes an
        /// inherited grant explicable without a second round trip.
        let ancestors: [IAMNode]
        let principals: [WhoCanEntry]
        /// When true, `principals` is not the whole answer — every
        /// authenticated user can perform this action here. See
        /// `WhoCanResult`.
        let openToAllAuthenticatedUsers: Bool
        /// Authored policies (issue #606) that may bear on this action, matched
        /// best-effort. Their principals are not in `principals`.
        let authoredPolicies: [WhoCanPolicyMatch]
        /// When true, an authored permit policy above bears on this query and
        /// its principals could not be enumerated — `principals` is again
        /// partial.
        let authoredPolicyCaveat: Bool
        /// The ceilings in force on this resource (guardrails + authored
        /// forbids). Which grants each neutralises is on the entries
        /// (`ceilinged`); this is the "what constrains this resource" summary
        /// (#610).
        let ceilings: [WhoCanCeiling]
    }

    /// POST /api/authorization/who-can
    ///
    /// Body: `{ "resourceType", "resourceId", "action" }`
    /// Returns every principal that can perform the action, with the reason.
    ///
    /// Answers may include principals from other organizations: cross-org
    /// access via explicit binding is supported by design, and hiding it here
    /// would defeat the point of the endpoint.
    func whoCan(req: Request) async throws -> WhoCanResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let payload = try req.content.decode(WhoCanRequest.self)
        let node = try Self.node(resourceType: payload.resourceType, resourceId: payload.resourceId)
        try await Self.requirePolicyRead(on: node, caller: user, req: req)

        let ancestors = try await IAMResourceTree.ancestors(of: node, on: req.db)
        let result = try await WhoCanService.whoCan(
            action: payload.action, node: node, app: req.application, on: req.db)

        return WhoCanResponse(
            resource: node,
            action: payload.action,
            ancestors: ancestors,
            principals: result.principals,
            openToAllAuthenticatedUsers: result.openToAllAuthenticatedUsers,
            authoredPolicies: result.authoredPolicies,
            authoredPolicyCaveat: result.authoredPolicyCaveat,
            ceilings: result.ceilings
        )
    }

    // MARK: - Helpers

    private static func node(resourceType: String, resourceId: String) throws -> IAMNode {
        try IAMPolicyGate.node(resourceType: resourceType, resourceId: resourceId)
    }

    /// Reading who holds access is itself an administrative act — the answer
    /// lists other people's grants. See `IAMPolicyGate` for the rule.
    private static func requirePolicyRead(on node: IAMNode, caller: User, req: Request) async throws {
        try await IAMPolicyGate.requirePolicyRead(
            on: node,
            deniedReason: "Reading access policy requires admin on the resource or a container above it",
            req: req
        )
    }
}
