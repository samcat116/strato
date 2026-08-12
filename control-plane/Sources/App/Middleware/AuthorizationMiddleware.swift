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
//  - **resource-mapped**: the middleware itself evaluates an explicit
//    canonical action and IAM node derived from the route metadata (VMs and sandboxes —
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

    enum RouteClass: Equatable {
        case isPublic
        case loginOnly
        case resource(GuardedResource)
        case handlerChecked
    }

    /// A route-prefix-guarded resource API. Every field is already in the
    /// canonical IAM vocabulary; the middleware never translates a legacy
    /// permission or resource-type string.
    struct GuardedResource: Equatable {
        let prefix: String
        let nodeType: IAMNodeType
        let readAction: String
        let createAction: String
        let updateAction: String
        let deleteAction: String
        let snapshotAction: String
        let actionVerbs: [String: String]
    }

    private static let guardedResources: [GuardedResource] = [
        GuardedResource(
            prefix: "/api/vms",
            nodeType: .virtualMachine,
            readAction: "vm:read",
            createAction: "vm:create",
            updateAction: "vm:update",
            deleteAction: "vm:delete",
            snapshotAction: "vm:snapshot",
            // `exec` and `run` are listed ahead of the routes that will serve
            // them (issue #804). Both fallbacks are weaker than the act they
            // would gate: an unlisted POST subpath falls back to `update` and
            // an unlisted GET to `read`, so leaving these out would hand
            // in-guest execution an editor — or, for the WebSocket attach, a
            // *viewer* — action the moment the route appeared, with
            // nothing to announce it. A verb with no route behind it costs
            // nothing: the path 404s either way.
            actionVerbs: [
                "start": "vm:start", "stop": "vm:stop", "restart": "vm:restart",
                "pause": "vm:pause", "resume": "vm:resume", "exec": "vm:exec",
                "run": "vm:runCommand",
            ]
        ),
        GuardedResource(
            prefix: "/api/sandboxes",
            nodeType: .sandbox,
            readAction: "sandbox:read",
            createAction: "sandbox:create",
            updateAction: "sandbox:update",
            deleteAction: "sandbox:delete",
            snapshotAction: "sandbox:snapshot",
            actionVerbs: [
                "start": "sandbox:start", "stop": "sandbox:stop", "restart": "sandbox:restart",
                "exec": "sandbox:exec",
            ]
        ),
    ]

    /// Identity-plane prefixes: login required, authorization is row scoping
    /// in the handler, deliberately outside the IAM tree (see the pre-cutover
    /// audit in docs/architecture/iam.md for why each is here).
    private static let loginOnlyPrefixes = [
        "/api/api-keys",  // self-scoped by construction; others' keys are 404
        // The caller's own passkeys. Self-scoped by construction — the path
        // says `me`, so there is no other user's record to reach — and matched
        // before the `/api/users` handler-checked prefix below.
        "/api/users/me",
        "/api/operations",  // initiator-may-read fallback; non-initiators 404
        "/api/oauth",  // the caller's own device approvals and CLI sessions
        "/api/authorization",  // can-i / who-can gate per queried resource internally
    ]

    /// Route prefixes whose handlers authorize through the evaluator
    /// (`req.can` / `req.authorize` with a canonical action and IAM node, or
    /// `req.requireSystemAdmin()` for the deliberately admin-only surfaces).
    private static let handlerCheckedPrefixes = [
        // Identity plane. A user record is a Cedar resource (`IAMNodeType.user`),
        // so reading, updating and deleting one is an ordinary evaluator check:
        // `platform-user-self` for your own record, `platform-system-admin` for
        // anyone else's. Only `POST /api/users` (invite) stays on the admin gate,
        // having no record yet to name. `/api/users/register` is public and is
        // matched earlier.
        "/api/users",
        "/api/organizations",
        "/api/projects",
        "/api/volumes",
        "/api/networks",
        "/api/load-balancers",
        "/api/images",
        "/api/floating-ips",
        "/api/floating-ip-pools",
        "/api/security-groups",
        "/api/dns-zones",
        "/api/agents",
        "/api/agent-enrollments",
        "/api/sites",
        "/api/quotas",
        "/api/iam",
        "/api/hierarchy",
        "/api/audit-events",
        "/api/workload-identity",
        // Workload principals (issue #491): service-account CRUD authorizes
        // per-node via the evaluator; the registry surface is system-admin.
        "/api/service-accounts",
        "/api/workload-registrations",
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
        // `/agent/desired-state` is the desired-state long-poll (STR-146):
        // agents fetch their sync with their SPIFFE SVID over mTLS, and the
        // handler authenticates the forwarded client certificate itself.
        // Matched *exactly*, not as a prefix — `publicPrefixes` below is
        // `hasPrefix`, so listing it there would silently make a future
        // `/agent/desired-state-history` public too.
        let exactPublic: Set<String> = [
            "/api/docs", "/api/openapi.yaml", "/agent/desired-state",
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
        // Guest JWT-SVID minting authenticates the hosting agent's forwarded
        // client certificate in-handler, then performs its own placement and
        // audience-policy checks. A user session is neither accepted nor a
        // substitute for that SVID-mTLS identity.
        let isAgentGuestIdentityMint =
            path.hasPrefix("/agent/vms/") && path.hasSuffix("/jwt-svid")
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
            || isAgentDownload || isAgentGuestIdentityMint || isAgentSnapshotArtifact
            || isPublicPrefixInfix
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

    /// A request's class, with the test-only override applied.
    ///
    /// Individual tests register ad-hoc routes (a bare `/resource` behind the
    /// credential-restriction middleware, say) that no production class covers.
    /// They declare those prefixes via `testOnlyLoginRoutePrefixes`; honored
    /// only under `.testing`, so production classification stays closed.
    ///
    /// Shared with `CredentialRestrictionMiddleware`, which decides whether an
    /// evaluator decision is coming from the same classification this one
    /// enforces. Two spellings of "is this route evaluator-gated" would be two
    /// chances to disagree, and the disagreement that matters is the one where
    /// both decide the other is handling it.
    static func classify(request: Request) -> RouteClass? {
        let path = request.url.path
        if let classified = classify(path: path) { return classified }
        if request.application.environment == .testing,
            request.application.testOnlyLoginRoutePrefixes.contains(where: { path.hasPrefix($0) })
        {
            return .loginOnly
        }
        return nil
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let path = request.url.path

        guard let routeClass = Self.classify(request: request) else {
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

        // The acting principal: a session/API-key user, or the machine
        // principal a JWT-SVID resolved to (issue #495).
        guard let principal = request.actingPrincipal else {
            throw Abort(.unauthorized, reason: "User not authenticated")
        }

        switch routeClass {
        case .isPublic:
            fatalError("unreachable: handled above")
        case .loginOnly:
            // These are the self-scoped identity-plane routes: "my API keys",
            // "my passkeys", "my OAuth sessions". Their authorization *is* the
            // row scoping to the caller's own user record, which a machine
            // principal has none of — so there is nothing here to scope to, and
            // letting one through would fall into handlers that assume a user.
            if request.auth.get(User.self) == nil {
                throw Abort(
                    .forbidden,
                    reason: "This endpoint is only available to user principals, not workload credentials")
            }
            return try await next.respond(to: request)
        case .resource(let resource):
            try await checkResourcePermissions(
                request: request, principal: principal, resource: resource)
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

    /// The canonical IAM action a method and path demand on a guarded
    /// resource. Lifted out of `checkResourcePermissions` so it can be asserted
    /// directly: this is where a mis-derived verb becomes a route gated on a
    /// weaker action than it needs, which no integration test would notice
    /// as long as the request still succeeds. Returns nil for a method the
    /// mapping does not cover (the caller answers 405).
    static func action(
        method: HTTPMethod, pathComponents: [Substring], resource: GuardedResource
    ) -> String? {
        // Snapshot subresource (issue #426, and full-VM checkpoints in #564):
        // creating, deleting, or restoring a snapshot is guarded by the parent
        // resource's `snapshot` action (finer per-snapshot checks live in
        // the handlers); listing follows plain `read`. Without this carve-out
        // the generic mapping below would demand `delete` on the *VM or
        // sandbox* to delete one of its snapshots. Both guarded prefixes nest
        // snapshots at the same depth, so one rule covers them.
        let isSnapshotSubresource = pathComponents.count >= 4 && pathComponents[3] == "snapshots"

        // The verb this path names, if any — read once and consulted by both
        // GET and POST (issue #804).
        //
        // Two subpath shapes reach the same verb list. A direct subpath
        // (`/api/vms/:id/start`) names it at index 3; an `/actions/<verb>`
        // subpath names it one segment deeper, and without that hop the read
        // would find the literal `actions` and miss the list entirely. Both
        // shapes are honored because the two halves of in-guest execution
        // arrive in different ones — the interactive attach generalizes the
        // sandbox WebSocket route (`…/exec/:sessionID/attach`), the recorded
        // run is specified as `…/actions/run` — and a derivation that covered
        // only one would silently hand the other to a fallback.
        let subpathVerb: String? = {
            guard !isSnapshotSubresource, pathComponents.count >= 4 else { return nil }
            let isActionsSubpath = pathComponents[3] == "actions" && pathComponents.count >= 5
            let candidate = String(pathComponents[isActionsSubpath ? 4 : 3])
            return resource.actionVerbs[candidate]
        }()

        switch method {
        case .GET:
            // A named verb wins over the `read` default, because an
            // interactive session is a WebSocket *upgrade* — a GET — and
            // deriving `read` for it would gate a root shell on a **viewer**
            // action, which is worse than the `update` fallback the POST
            // branch already had to guard against. Both of this middleware's
            // backstops are blind to that shape: the verb list below never
            // fires on a GET, and `assertHandlerEvaluated` returns early for
            // GET and for `.switchingProtocols`, so a WebSocket handler that
            // forgot its own check would not fail the suite either. Nothing
            // else changes — a GET whose subpath is not a registered verb
            // (`/status`, `/operations`, `/console`, snapshot listing) still
            // reads.
            return subpathVerb ?? resource.readAction
        case .POST:
            // Special handling for lifecycle actions
            if isSnapshotSubresource {
                return resource.snapshotAction
            } else if pathComponents.count >= 4 {
                return subpathVerb ?? resource.updateAction
            } else {
                return resource.createAction
            }
        case .PUT, .PATCH:
            return resource.updateAction
        case .DELETE:
            return isSnapshotSubresource ? resource.snapshotAction : resource.deleteAction
        default:
            return nil
        }
    }

    private func checkResourcePermissions(
        request: Request, principal: IAMPrincipal, resource: GuardedResource
    ) async throws {
        let pathComponents = request.url.path.split(separator: "/")
        guard
            let routeAction = Self.action(
                method: request.method, pathComponents: pathComponents, resource: resource)
        else { throw Abort(.methodNotAllowed) }

        // Validate the route's own metadata before a collection request swaps
        // the concrete action for its organization-membership probe. Otherwise
        // a misspelled `createAction` could still enter the handler because the
        // substituted `org:read` check is valid.
        guard IAMRoleRegistry.allActions.contains(routeAction),
            CedarSchemaBuilder.resourceTypes(for: routeAction).contains(resource.nodeType.cedarEntityType)
        else {
            throw Abort(.internalServerError, reason: "Route names an invalid IAM action and node")
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

        // Collection-level operations (list, create) gate on the caller's
        // organization — bare membership grants `org:read`, so this is "are you
        // anyone here at all"; the handler does the real project-scoped check
        // for creates and the real per-row check for lists. A user's comes from
        // their current organization; a machine principal's from where it was
        // registered (issue #495) — it holds nothing by membership, so this
        // only narrows which org's collection it is talking about.
        //
        // Because that question is *substituted* rather than asked, it is a
        // membership probe and does not carry the credential's own ceiling
        // (STR-203): a restriction is stated as `vm:read` in project P, and
        // neither half of that can be true of `org:read` on an organization, so
        // intersecting it here 403'd the list while every item route beneath it
        // succeeded. The ceiling applies in full where there is an act to apply
        // it to — `canFilter("vm:read")` in the handler, `vm:create` on the
        // resolved project for a create.
        let check: (action: String, node: IAMNode)
        let isMembershipProbe =
            resourceId == "*" && (routeAction == resource.readAction || routeAction == resource.createAction)
        if isMembershipProbe {
            guard let currentOrgId = try await request.actingOrganizationID() else {
                throw Abort(.forbidden, reason: "No current organization set")
            }
            check = ("org:read", IAMNode(type: .organization, id: currentOrgId))
        } else {
            guard let id = UUID(uuidString: resourceId) else {
                throw Abort(.badRequest, reason: "Invalid resource ID")
            }
            check = (routeAction, IAMNode(type: resource.nodeType, id: id))
        }

        // Route metadata must resolve to a registry action applicable to the
        // typed node before the handler runs. A bad constant is a server bug,
        // never a request-shaped deny.
        guard IAMRoleRegistry.allActions.contains(check.action),
            CedarSchemaBuilder.resourceTypes(for: check.action).contains(check.node.type.cedarEntityType)
        else {
            throw Abort(.internalServerError, reason: "Route names an invalid IAM action and node")
        }

        let decision = try await IAMAuthorizer.authorize(
            principal: principal,
            action: check.action,
            node: check.node,
            context: IAMCheckContext(
                path: request.url.path, method: request.method.rawValue, requestID: request.id),
            state: isMembershipProbe
                ? request.iamAuthState.membershipProbe() : request.iamAuthState,
            cache: request.iamCache,
            app: request.application,
            db: request.db
        )
        guard decision.allowed else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
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
        set { setStorageValue(TestOnlyLoginRoutePrefixesKey.self, to: newValue) }
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
