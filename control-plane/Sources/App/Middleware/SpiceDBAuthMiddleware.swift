import Fluent
import Vapor

struct DevUserKey: StorageKey {
    typealias Value = User
}

struct SpiceDBAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Dev mode bypass - skip all auth
        if request.application.environment == .development,
            Environment.get("DEV_AUTH_BYPASS") == "true"
        {
            // Reload the dev user from the database to ensure proper context
            // This is necessary because the stored user object may not be properly
            // bound to this request's database context
            if let devUser = try await User.query(on: request.db)
                .filter(\.$username == "dev")
                .first()
            {
                request.auth.login(devUser)
            }
            return try await next.respond(to: request)
        }

        // Skip auth for health checks, public API routes, and auth endpoints.
        // Split into small sub-expressions: a single long `||` chain trips the
        // Swift type-checker ("unable to type-check in reasonable time").
        let path = request.url.path
        let exactPublic: Set<String> = [
            "/api/docs", "/openapi.json",
        ]
        // `/ssf/events` is the RFC 8935 push-delivery endpoint: transmitters
        // authenticate with a per-stream bearer token checked in-handler.
        // `/api/public/` serves the login page (SSO provider discovery), so it
        // must be reachable without a session.
        let publicPrefixes = [
            "/health", "/auth", "/api/users/register", "/agent/ws", "/ssf/events/", "/api/public/",
        ]
        // Signed image-download URLs: agents fetch base images with an HMAC
        // signature, not a session; the controller verifies the signature.
        let isSignedDownload = path.hasPrefix("/api/projects/") && path.hasSuffix("/download")
        if exactPublic.contains(path) || publicPrefixes.contains(where: { path.hasPrefix($0) }) || isSignedDownload {
            return try await next.respond(to: request)
        }

        // Extract user from session
        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized, reason: "User not authenticated")
        }

        // System admins bypass all permission checks. Flag the request so
        // AuditMiddleware records the bypassed action as an admin audit event
        // (issue #39) — this bypass is otherwise invisible to authorization.
        if user.isSystemAdmin {
            request.logger.info("System admin access - bypassing permission checks")
            request.adminBypassUsed = true
            return try await next.respond(to: request)
        }

        // Resource APIs guarded by route prefix: each maps to its SpiceDB
        // resource type plus the POST action verbs that are permissions of
        // their own (everything else shares the method → permission mapping).
        if let resource = Self.guardedResources.first(where: { request.url.path.hasPrefix($0.prefix) }) {
            try await checkResourcePermissions(request: request, user: user, resource: resource)
        }

        return try await next.respond(to: request)
    }

    /// A route-prefix-guarded resource API: `/api/vms` → `virtual_machine`,
    /// `/api/sandboxes` → `sandbox`. `actionVerbs` are the POST subpaths that
    /// map to a same-named SpiceDB permission (sandboxes have no
    /// pause/resume, for example).
    private struct GuardedResource {
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
        }

        // Handle collection-level operations that require organization permissions
        if (permission == "read" && resourceId == "*")
            || (permission == "create" && resourceId == "*")
        {
            // For collection read and creation, check organization membership
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.forbidden, reason: "No current organization set")
            }

            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                throw Abort(.forbidden, reason: "Invalid user session")
            }

            request.logger.info(
                "Checking permission for user: \(userId) on organization: \(currentOrgId.uuidString)"
            )

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
            // Check permission with SpiceDB for object-level operations
            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                throw Abort(.forbidden, reason: "Invalid user session")
            }

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
