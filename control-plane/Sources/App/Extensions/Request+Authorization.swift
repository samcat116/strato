import Fluent
import Vapor

extension Request {
    /// Whether the current user holds `permission` on the given SpiceDB resource.
    ///
    /// This is the single object-level authorization primitive: it centralizes the
    /// system-admin bypass (matching `SpiceDBAuthMiddleware`) and the SpiceDB check
    /// so handlers never open-code that pattern. System admins always return `true`.
    ///
    /// - Throws: `.unauthorized` if the request is unauthenticated.
    func can(_ permission: String, on resourceType: String, id: String) async throws -> Bool {
        guard let user = auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // System admins bypass all permission checks (matches SpiceDBAuthMiddleware).
        // Flagged so AuditMiddleware records the action as an admin audit event.
        if user.isSystemAdmin {
            adminBypassUsed = true
            return true
        }

        return try await spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: permission,
            resource: resourceType,
            resourceId: id
        )
    }

    /// Enforce `permission` on the given SpiceDB resource, throwing `.forbidden` when
    /// the current user lacks it. The per-handler complement to `SpiceDBAuthMiddleware`.
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
}
