import Fluent
import Vapor

// IAM phase 5 (issue #482): the structurally default-deny authorization
// middleware, replacing SpiceDBAuthMiddleware's arrangement where only
// /api/vms and /api/sandboxes were middleware-guarded and every other route
// relied on its handler remembering to check.
//
// Every route the application registers must fall into exactly one class:
//
//  - **public**: reachable without a session. The explicit allowlist — login,
//    health, the agent mTLS surfaces, the SCIM data plane. Everything the
//    phase-5 pre-cutover audit (docs/architecture/iam.md) identified as
//    deliberately session-free.
//  - **loginOnly**: authenticated, but outside the IAM resource tree —
//    identity-plane surfaces whose authorization is row scoping by
//    construction (my API keys, my user record, my OAuth sessions, the
//    operation-initiator fallback, the can-i/who-can query endpoints which
//    gate per resource internally).
//  - **resource-mapped**: the middleware itself evaluates a Cedar check
//    derived from the method and path (VMs and sandboxes, as before —
//    handlers keep their finer checks as defense in depth).
//  - **handlerChecked**: authenticated here, authorized in the handler
//    through the evaluator. The middleware asserts after the fact that a
//    mutating handler actually evaluated a decision, so a forgotten check
//    fails the test suite instead of silently serving.
//
// A route that matches no class is denied outright, and `assertAllRoutesClassified`
// fails boot if a route is registered without one — adding an endpoint forces
// a classification decision.
//
// There is no system-admin short-circuit here anymore: admins are allowed by
// the `platform-system-admin` tier-1 policy inside the evaluator, so their
// activity lands in the decision log and tier-2 guardrails bind them too.
struct AuthorizationMiddleware: AsyncMiddleware {

    enum RouteClass {
        case isPublic
        case loginOnly
        case resource(GuardedResource)
        case handlerChecked
    }

    /// A route-prefix-guarded resource API: `/api/vms` → `virtual_machine`,
    /// `/api/sandboxes` → `sandbox`. `actionVerbs` are the POST subpaths that
    /// map to a same-named permission (sandboxes have no pause/resume, for
    /// example).
    struct GuardedResource {
        let prefix: String
        let resourceType: String
        let actionVerbs: Set<String>
    }

    private static let guardedResources: [GuardedResource] = [
        GuardedResource(
            prefix: "/api/vms",
            resourceType: "virtual_machine",
            actionVerbs: ["start", "stop", "restart", "pause", "resume"]
        ),
        GuardedResource(
            prefix: "/api/sandboxes",
            resourceType: "sandbox",
            actionVerbs: ["start", "stop", "restart", "exec"]
        ),
    ]

    /// Identity-plane prefixes: login required, authorization is row scoping
    /// in the handler, deliberately outside the IAM tree (see the pre-cutover
    /// audit in docs/architecture/iam.md for why each is here).
    private static let loginOnlyPrefixes = [
        "/api/api-keys",  // self-scoped by construction; others' keys are 404
        "/api/users",  // self-or-system-admin (register is public, matched earlier)
        "/api/operations",  // initiator-may-read fallback; non-initiators 404
        "/api/oauth",  // the caller's own device approvals and CLI sessions
        "/api/authorization",  // can-i / who-can gate per queried resource internally
    ]

    /// Route prefixes whose handlers authorize through the evaluator
    /// (`req.can` / `req.authorize` / `IAMPolicyGate`, or `req.requireSystemAdmin()`
    /// for the deliberately admin-only surfaces).
    private static let handlerCheckedPrefixes = [
        "/api/organizations",
        "/api/projects",
        "/api/volumes",
        "/api/networks",
        "/api/images",
        "/api/floating-ips",
        "/api/floating-ip-pools",
        "/api/agents",
        "/api/sites",
        "/api/quotas",
        "/api/iam",
        "/api/hierarchy",
        "/api/audit-events",
        "/api/workload-identity",
        // SCIM token management (the data plane under /scim/v2 is public,
        // matched earlier).
        "/organizations",
    ]

    /// Classify a path (a concrete request path, or a registered route
    /// pattern — the predicates only inspect constant segments, so both
    /// work). Returns nil for a path no class claims: denied at runtime,
    /// rejected at boot.
    static func classify(path: String) -> RouteClass? {
        // Public allowlist. Split into small sub-expressions: a single long
        // `||` chain trips the Swift type-checker.
        let exactPublic: Set<String> = [
            "/api/docs", "/api/openapi.yaml",
        ]
        // `/ssf/events` is the RFC 8935 push-delivery endpoint: transmitters
        // authenticate with a per-stream bearer token checked in-handler.
        // `/api/public/` serves the login page (SSO provider discovery), so it
        // must be reachable without a session.
        // `/oauth/` is the RFC 8628 device-grant surface: the polling CLI has
        // no credentials yet. The approval/management endpoints live under
        // `/api/oauth/` and stay session-gated.
        let publicPrefixes = [
            "/health", "/auth", "/api/users/register", "/agent/ws", "/ssf/events/", "/api/public/",
            "/oauth/",
        ]
        // Image-download URLs: agents fetch base images with their SPIFFE SVID
        // over mTLS, not a session; the handler authenticates the forwarded
        // client certificate (or a user session) itself.
        let isAgentDownload = path.hasPrefix("/api/projects/") && path.hasSuffix("/download")
        // Snapshot artifact transfer (issue #428): agents stream exported
        // snapshot artifacts up and down with their SPIFFE SVID over mTLS;
        // the handler authenticates the forwarded client certificate before
        // touching any bytes.
        let isAgentSnapshotArtifact =
            path.hasPrefix("/api/sandboxes/") && path.contains("/snapshots/")
            && path.contains("/artifacts/")
        // Routes whose path has a dynamic segment before the public part, so a
        // flat prefix can't express them: exempt when the path starts with
        // `prefix` AND contains `infix`. The SCIM data plane
        // (/organizations/:id/scim/v2/**) is like /ssf/events/: IdPs
        // authenticate with an org-scoped `scim_` bearer token checked
        // in-handler and never carry a user session. (Token *management* lives
        // under /organizations/:id/settings/scim-tokens and stays guarded.)
        let publicPrefixInfixPairs: [(prefix: String, infix: String)] = [
            ("/organizations/", "/scim/v2")
        ]
        let isPublicPrefixInfix = publicPrefixInfixPairs.contains { pair in
            path.hasPrefix(pair.prefix) && path.contains(pair.infix)
        }
        if exactPublic.contains(path) || publicPrefixes.contains(where: { path.hasPrefix($0) })
            || isAgentDownload || isAgentSnapshotArtifact || isPublicPrefixInfix
        {
            return .isPublic
        }

        if let resource = guardedResources.first(where: { path.hasPrefix($0.prefix) }) {
            return .resource(resource)
        }
        if loginOnlyPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .loginOnly
        }
        if handlerCheckedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .handlerChecked
        }
        return nil
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let path = request.url.path

        // Individual tests register ad-hoc routes (a bare `/resource` behind a
        // scope middleware, say) that no production class covers. They declare
        // those prefixes via `testOnlyLoginRoutePrefixes`; honored only under
        // `.testing`, so production classification stays closed.
        var classified = Self.classify(path: path)
        if classified == nil, request.application.environment == .testing,
            request.application.testOnlyLoginRoutePrefixes.contains(where: { path.hasPrefix($0) })
        {
            classified = .loginOnly
        }

        guard let routeClass = classified else {
            // Boot refuses to start with an unclassified route registered
            // (`assertAllRoutesClassified`), so this is a request for a path
            // that matches no route at all — or a gap in that assertion.
            // Either way: default deny.
            request.logger.error("Request for unclassified path denied", metadata: ["path": .string(path)])
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }

        if case .isPublic = routeClass {
            return try await next.respond(to: request)
        }

        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized, reason: "User not authenticated")
        }

        switch routeClass {
        case .isPublic:
            fatalError("unreachable: handled above")
        case .loginOnly:
            return try await next.respond(to: request)
        case .resource(let resource):
            try await checkResourcePermissions(request: request, user: user, resource: resource)
            return try await next.respond(to: request)
        case .handlerChecked:
            let response = try await next.respond(to: request)
            try Self.assertHandlerEvaluated(request: request, response: response)
            return response
        }
    }

    /// The structural backstop for handler-checked routes: a *mutating*
    /// request that succeeded without any evaluator decision is a handler that
    /// forgot its authorization check. Under `.testing` that is a hard 500 so
    /// the test suite catches it on the spot; in production it serves (the
    /// handler already ran — denying now would not undo it) but logs at error
    /// level so it cannot pass unnoticed.
    ///
    /// Reads are not asserted: list endpoints legitimately evaluate nothing
    /// when their per-row scoping matches no rows, and object reads on the
    /// mapped resources are covered by the middleware itself.
    private static func assertHandlerEvaluated(request: Request, response: Response) throws {
        switch request.method {
        case .GET, .HEAD, .OPTIONS:
            return
        default:
            break
        }
        guard response.status.code < 400, response.status != .switchingProtocols else { return }
        guard !request.iamAuthState.decisionEvaluated.withLockedValue({ $0 }) else { return }

        request.logger.error(
            "Mutating handler served without an authorization decision",
            metadata: [
                "path": .string(request.url.path),
                "method": .string(request.method.rawValue),
            ])
        if request.application.environment == .testing {
            throw Abort(
                .internalServerError,
                reason: "Handler for \(request.method.rawValue) \(request.url.path) evaluated no authorization decision"
            )
        }
    }

    private func checkResourcePermissions(
        request: Request, user: User, resource: GuardedResource
    ) async throws {
        let method = request.method
        let pathComponents = request.url.path.split(separator: "/")

        // Snapshot subresource (issue #426): creating, deleting, or restoring
        // a sandbox snapshot is guarded by the parent resource's `snapshot`
        // permission (finer per-snapshot checks live in the handlers);
        // listing follows plain `read`. Without this carve-out the generic
        // mapping below would demand `delete` on the *sandbox* to delete one
        // of its snapshots.
        let isSnapshotSubresource = pathComponents.count >= 4 && pathComponents[3] == "snapshots"

        // Determine required permission based on HTTP method and path
        let permission: String
        switch method {
        case .GET:
            permission = "read"
        case .POST:
            // Special handling for lifecycle actions
            if isSnapshotSubresource {
                permission = "snapshot"
            } else if pathComponents.count >= 4 {
                let action = String(pathComponents[3])
                permission = resource.actionVerbs.contains(action) ? action : "update"
            } else {
                permission = "create"
            }
        case .PUT, .PATCH:
            permission = "update"
        case .DELETE:
            permission = isSnapshotSubresource ? "snapshot" : "delete"
        default:
            throw Abort(.methodNotAllowed)
        }

        // For object-level operations, extract the resource ID
        var resourceId = "*"  // Default for collection operations
        if pathComponents.count >= 3 {
            resourceId = String(pathComponents[2])
            // A malformed id is a malformed request, not a denied one: the
            // evaluator could only ever deny it, and a 400 tells the caller
            // what is actually wrong. (Both guarded prefixes have no static
            // segments in this position.)
            guard UUID(uuidString: resourceId) != nil else {
                throw Abort(.badRequest, reason: "Invalid resource ID")
            }
        }

        guard let userId = user.id?.uuidString, !userId.isEmpty else {
            throw Abort(.forbidden, reason: "Invalid user session")
        }

        // Collection-level operations (list, create) gate on the caller's
        // current organization — bare membership grants `org:read`, so this is
        // "are you anyone here at all"; the handler does the real
        // project-scoped check for creates.
        if (permission == "read" && resourceId == "*")
            || (permission == "create" && resourceId == "*")
        {
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.forbidden, reason: "No current organization set")
            }

            let hasPermission = try await request.spicedb.checkPermission(
                subject: userId,
                permission: "view_organization",
                resource: "organization",
                resourceId: currentOrgId.uuidString
            )

            if !hasPermission {
                throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
            }
        } else {
            // Object-level: the method/path-derived permission on the resource
            // itself, evaluated through the Cedar policy set.
            let hasPermission = try await request.spicedb.checkPermission(
                subject: userId,
                permission: permission,
                resource: resource.resourceType,
                resourceId: resourceId
            )

            if !hasPermission {
                throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
            }
        }
    }
}

extension Application {
    private struct TestOnlyLoginRoutePrefixesKey: StorageKey {
        typealias Value = [String]
    }

    /// Test-only: prefixes of ad-hoc routes a test registers after boot,
    /// treated as `loginOnly` by `AuthorizationMiddleware`. Consulted only
    /// under `.testing`; a no-op everywhere else.
    var testOnlyLoginRoutePrefixes: [String] {
        get { storage[TestOnlyLoginRoutePrefixesKey.self] ?? [] }
        set { storage[TestOnlyLoginRoutePrefixesKey.self] = newValue }
    }

    /// Fail boot if any registered route escapes `AuthorizationMiddleware`'s
    /// classification — the property that makes the middleware *structurally*
    /// default-deny: an endpoint cannot ship without an explicit decision
    /// about who may reach it.
    ///
    /// Route patterns are rendered with `:param`/`*`/`**` placeholders; the
    /// classifier only tests constant leading segments, so patterns classify
    /// exactly like the concrete paths they match.
    func assertAllRoutesClassified() throws {
        var unclassified: [String] = []
        for route in routes.all {
            let path =
                "/"
                + route.path.map { component -> String in
                    switch component {
                    case .constant(let constant): return constant
                    case .parameter(let name): return ":\(name)"
                    case .anything: return "*"
                    case .catchall: return "**"
                    }
                }.joined(separator: "/")
            if AuthorizationMiddleware.classify(path: path) == nil {
                unclassified.append("\(route.method.rawValue) \(path)")
            }
        }
        guard unclassified.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "Routes registered without an authorization classification: "
                    + unclassified.sorted().joined(separator: ", ")
                    + " — add them to AuthorizationMiddleware's route classes"
            )
        }
    }
}
