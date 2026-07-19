import Fluent
import Vapor

/// The authorization query surface: "can I?", "can *they*?", and "who can?".
///
/// Read-only — it answers questions about access and never mutates anything.
/// Two of the four APIs the design calls for on day one of the new IAM system
/// (docs/architecture/iam.md); the policy simulator and decision logs land with
/// later phases.
struct AuthorizationController: RouteCollection {
    /// Cap on checks per request — keeps a single call bounded (see `checkBulk`).
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
    /// The two forms answer from different stores, deliberately:
    ///
    /// - **No `principal`** (the caller asks about themselves): answered by
    ///   SpiceDB, which is what actually gates requests today. `permission` is a
    ///   SpiceDB permission name (`manage_project`).
    /// - **With `principal`**: answered from the `role_bindings` table + the
    ///   resource tree, so it agrees with `who-can`. `permission` is an IAM
    ///   action name (`vm:start`) — a different vocabulary, because the
    ///   bindings model has no SpiceDB permissions in it.
    ///
    /// The split exists because SpiceDB remains authoritative through phase 1.
    /// At cutover (#482) both forms collapse onto the evaluator and the
    /// vocabularies become one.
    func check(req: Request) async throws -> CheckResponse {
        guard let user = req.auth.get(User.self) else {
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

        // System admins can do everything — answer without hitting SpiceDB.
        if user.isSystemAdmin {
            var results: [String: Bool] = [:]
            for item in payload.checks {
                results[item.key] = true
            }
            return CheckResponse(results: results)
        }

        let queries = payload.checks.map {
            PermissionQuery(
                key: $0.key,
                permission: $0.permission,
                resourceType: $0.resourceType,
                resourceId: $0.resourceId
            )
        }

        let results = try await req.spicedb.checkBulk(subject: user.id?.uuidString ?? "", queries)
        return CheckResponse(results: results)
    }

    /// Evaluate checks on behalf of another principal, from the bindings table.
    private func checkForPrincipal(
        _ principal: PrincipalRequest, _ checks: [PermissionCheckItem], caller: User, req: Request
    ) async throws -> CheckResponse {
        // Gate each distinct resource once: a batch may ask fifty questions
        // about the same VM, and the gate is a tree walk plus SpiceDB calls.
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
        let result = try await WhoCanService.whoCan(action: payload.action, node: node, on: req.db)

        return WhoCanResponse(
            resource: node,
            action: payload.action,
            ancestors: ancestors,
            principals: result.principals,
            openToAllAuthenticatedUsers: result.openToAllAuthenticatedUsers
        )
    }

    // MARK: - Helpers

    /// Parse a `(resourceType, resourceId)` pair into a tree node. An unknown
    /// type is a `400`, not a `403` — naming a type that does not exist is a
    /// malformed request, not a denied one.
    private static func node(resourceType: String, resourceId: String) throws -> IAMNode {
        guard let type = IAMNodeType(rawValue: resourceType) else {
            throw Abort(.badRequest, reason: "Unknown resource type '\(resourceType)'")
        }
        guard let id = UUID(uuidString: resourceId) else {
            throw Abort(.badRequest, reason: "Resource id must be a UUID")
        }
        return IAMNode(type: type, id: id)
    }

    /// The SpiceDB permission standing for "administrative control of this
    /// node" — the grantee set allowed to read who holds access here.
    ///
    /// Containers have an explicit `manage_*`. Individual resources have no
    /// `manage` in `schema.zed`; their `delete` is the permission whose
    /// grantees are exactly the resource owner plus project admins, which is
    /// the set we want. Gating a *read* on `delete` reads oddly, so: this is a
    /// grantee-set equivalence, not a claim that the caller may delete
    /// anything. At cutover it becomes `iam:readPolicy` and the indirection
    /// goes away.
    ///
    /// Every node type maps to something — a type with no entry here would
    /// silently fall through to its containers and deny its own owners.
    private static func adminPermission(for nodeType: IAMNodeType) -> String {
        switch nodeType {
        case .organization: return "manage_organization"
        case .organizationalUnit: return "manage_ou"
        case .project: return "manage_project"
        case .site, .agent: return "manage"
        case .virtualMachine, .sandbox, .image, .volume, .network,
            .volumeSnapshot, .sandboxSnapshot:
            return "delete"
        }
    }

    /// Reading who holds access is itself an administrative act — the answer
    /// lists other people's grants. Require system admin, or admin over the
    /// resource itself or any container above it.
    ///
    /// The resource node is checked too, not just its containers: resource-level
    /// grants exist from day one, so a VM's owner can audit their own VM without
    /// holding project admin.
    ///
    /// Gated through SpiceDB because it is what enforces today; this moves to
    /// `iam:readPolicy` through the evaluator at cutover.
    private static func requirePolicyRead(on node: IAMNode, caller: User, req: Request) async throws {
        if caller.isSystemAdmin { return }
        guard let callerID = caller.id?.uuidString else { throw Abort(.unauthorized) }

        let chain = try await IAMResourceTree.ancestors(of: node, on: req.db)
        for ancestor in chain {
            let allowed = try await req.spicedb.checkPermission(
                subject: callerID,
                permission: adminPermission(for: ancestor.type),
                resource: ancestor.type.rawValue,
                resourceId: ancestor.id.uuidString
            )
            if allowed { return }
        }
        throw Abort(.forbidden, reason: "Reading access policy requires admin on the resource or a container above it")
    }
}
