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
        guard let vm = try await VM.find(vmID, on: db) else {
            throw Abort(.notFound)
        }

        // Delegates to the generic `authorize` helper (system-admin bypass + SpiceDB
        // check live there); throws `.forbidden` if the user lacks `permission`.
        try await authorize(permission, on: "virtual_machine", id: vm.id?.uuidString ?? "")

        return vm
    }
}
