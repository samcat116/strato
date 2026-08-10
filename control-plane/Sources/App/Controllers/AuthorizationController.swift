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

    struct ActionCheckItem: Content {
        /// Opaque client-chosen id echoed back in the response, so the caller can
        /// correlate answers to the UI element they gate.
        let key: String
        let action: String
        let node: IAMNode
    }

    /// The subject of a check, when it is not the caller.
    struct PrincipalRequest: Content {
        let type: IAMPrincipalType
        let id: UUID
    }

    struct CheckRequest: Content {
        let checks: [ActionCheckItem]
        /// When present, the checks are evaluated for this principal instead of
        /// the caller. Admin-gated, and answered from the bindings table — see
        /// `check`.
        let principal: PrincipalRequest?

        init(checks: [ActionCheckItem], principal: PrincipalRequest? = nil) {
            self.checks = checks
            self.principal = principal
        }
    }

    struct CheckResponse: Content {
        let results: [String: Bool]
    }

    /// POST /api/authorization/check
    ///
    /// Body: `{ "checks": [ { "key", "action", "node": { "type", "id" } } ],
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
    ///   log row.
    /// - **With `principal`**: admin-gated reporting (`WhoCanService.can`) —
    ///   same decision, no decision-log row, plus the reachability gates a
    ///   real request would have hit first (disabled or nonexistent principals
    ///   answer false). A *group*
    ///   principal is answered from its bindings — a group never reaches the
    ///   evaluator itself.
    ///
    /// There is no admin fast path: guardrail forbids bind system admins, so
    /// short-circuiting to "true" could report an allow the evaluator would
    /// refuse.
    func check(req: Request) async throws -> CheckResponse {
        // "May I?" is asked about the request's acting principal — a user, or
        // the service account / workload a JWT-SVID resolved to (issue #495).
        let actingPrincipal = try req.requireActingPrincipal()

        let payload = try req.content.decode(CheckRequest.self)

        guard !payload.checks.isEmpty else {
            return CheckResponse(results: [:])
        }
        guard payload.checks.count <= Self.maxChecks else {
            throw Abort(.badRequest, reason: "Too many checks (max \(Self.maxChecks))")
        }

        if let principal = payload.principal {
            return try await checkForPrincipal(principal, payload.checks, req: req)
        }

        let context = IAMCheckContext(
            path: req.url.path, method: req.method.rawValue, requestID: req.id)

        // Resolve every item to an (action, node) pair first, then decide one
        // batch per distinct action (#687). Asking a batch endpoint's fifty
        // questions one at a time was fifty full evaluations — the shape this
        // endpoint exists to avoid.
        var asked: [(key: String, action: String, node: IAMNode)] = []
        var nodesByAction: [String: [IAMNode]] = [:]
        var results: [String: Bool] = [:]

        for item in payload.checks {
            try Self.validate(action: item.action, on: item.node)
            asked.append((item.key, item.action, item.node))
            nodesByAction[item.action, default: []].append(item.node)
        }

        var decisions: [String: [IAMNode: CedarCheckDecision]] = [:]
        for (action, nodes) in nodesByAction {
            decisions[action] = try await IAMAuthorizer.authorize(
                principal: actingPrincipal,
                action: action,
                nodes: nodes,
                context: context,
                state: req.iamAuthState,
                cache: req.iamCache,
                app: req.application,
                db: req.db
            )
        }
        for item in asked {
            results[item.key] = decisions[item.action]?[item.node]?.allowed ?? false
        }
        return CheckResponse(results: results)
    }

    /// Evaluate checks on behalf of another principal, from the bindings table.
    private func checkForPrincipal(
        _ principal: PrincipalRequest, _ checks: [ActionCheckItem], req: Request
    ) async throws -> CheckResponse {
        // Gate each distinct resource once: a batch may ask fifty questions
        // about the same VM, and the gate is a tree walk plus evaluator calls.
        var gated: Set<IAMNode> = []
        var asked: [(key: String, action: String, node: IAMNode)] = []
        var nodesByAction: [String: [IAMNode]] = [:]
        for item in checks {
            try Self.validate(action: item.action, on: item.node)
            if gated.insert(item.node).inserted {
                try await Self.requirePolicyRead(on: item.node, req: req)
            }
            asked.append((item.key, item.action, item.node))
            nodesByAction[item.action, default: []].append(item.node)
        }

        // One batch per distinct action, as in `check`.
        var answers: [String: [IAMNode: Bool]] = [:]
        for (action, nodes) in nodesByAction {
            answers[action] = try await WhoCanService.can(
                principalType: principal.type,
                principalID: principal.id,
                action: action,
                nodes: nodes,
                app: req.application,
                cache: req.iamCache,
                on: req.db
            )
        }

        var results: [String: Bool] = [:]
        for item in asked {
            results[item.key] = answers[item.action]?[item.node] ?? false
        }
        return CheckResponse(results: results)
    }

    // MARK: - who-can

    struct WhoCanRequest: Content {
        let action: String
        let node: IAMNode
    }

    struct WhoCanResponse: Content {
        let action: String
        let node: IAMNode
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
    /// Body: `{ "action", "node": { "type", "id" } }`
    /// Returns every principal that can perform the action, with the reason.
    ///
    /// Answers may include principals from other organizations: cross-org
    /// access via explicit binding is supported by design, and hiding it here
    /// would defeat the point of the endpoint.
    func whoCan(req: Request) async throws -> WhoCanResponse {
        guard req.auth.has(User.self) else {
            throw Abort(.unauthorized)
        }

        let payload = try req.content.decode(WhoCanRequest.self)
        try Self.validate(action: payload.action, on: payload.node)
        try await Self.requirePolicyRead(on: payload.node, req: req)

        let ancestors = try await IAMResourceTree.ancestors(of: payload.node, on: req.db)
        let result = try await WhoCanService.whoCan(
            action: payload.action, node: payload.node, app: req.application, on: req.db)

        return WhoCanResponse(
            action: payload.action,
            node: payload.node,
            ancestors: ancestors,
            principals: result.principals,
            openToAllAuthenticatedUsers: result.openToAllAuthenticatedUsers,
            authoredPolicies: result.authoredPolicies,
            authoredPolicyCaveat: result.authoredPolicyCaveat,
            ceilings: result.ceilings
        )
    }

    // MARK: - Helpers

    private static func validate(action: String, on node: IAMNode) throws {
        guard IAMRoleRegistry.allActions.contains(action) else {
            throw Abort(.badRequest, reason: "Unknown IAM action '\(action)'")
        }
        guard CedarSchemaBuilder.resourceTypes(for: action).contains(node.type.cedarEntityType) else {
            throw Abort(
                .badRequest,
                reason: "IAM action '\(action)' does not apply to '\(node.type.rawValue)'")
        }
    }

    /// Reading who holds access is itself an administrative act — the answer
    /// lists other people's grants: `iam:readPolicy`, the same gate the
    /// policy, role, and guardrail APIs use.
    private static func requirePolicyRead(on node: IAMNode, req: Request) async throws {
        guard try await req.can("iam:readPolicy", on: node) else {
            throw Abort(
                .forbidden,
                reason: "Reading access policy requires admin on the resource or a container above it")
        }
    }
}
