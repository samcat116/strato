import Fluent
import Vapor

extension Request {
    /// Fetch a VM and enforce a SpiceDB permission on it in one call.
    ///
    /// This is the per-handler defense-in-depth complement to `SpiceDBAuthMiddleware`:
    /// individual VM handlers should not rely solely on the middleware's path-prefix
    /// guard for object-level authorization. Mirrors the middleware's system-admin
    /// bypass so admins are never blocked.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the VM does not
    ///   exist, `.forbidden` if the user lacks `permission` on this VM.
    func authorizedVM(_ vmID: UUID, permission: String) async throws -> VM {
        guard let user = auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let vm = try await VM.find(vmID, on: db) else {
            throw Abort(.notFound)
        }

        // System admins bypass all permission checks (matches SpiceDBAuthMiddleware).
        if user.isSystemAdmin {
            return vm
        }

        let hasPermission = try await spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: permission,
            resource: "virtual_machine",
            resourceId: vm.id?.uuidString ?? ""
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this VM")
        }

        return vm
    }
}
