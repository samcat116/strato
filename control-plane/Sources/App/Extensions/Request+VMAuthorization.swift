import Fluent
import Vapor

extension Request {
    /// Fetch a VM and enforce a permission on it in one call, through the
    /// evaluator.
    ///
    /// This is the per-handler defense-in-depth complement to
    /// `AuthorizationMiddleware`: individual VM handlers should not rely solely
    /// on the middleware's path-prefix guard for object-level authorization.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the VM does not
    ///   exist, `.forbidden` if the user lacks `permission` on this VM.
    func authorizedVM(_ vmID: UUID, permission: String) async throws -> VM {
        guard let vm = try await VM.find(vmID, on: db) else {
            throw Abort(.notFound)
        }

        try await authorize(permission, on: "virtual_machine", id: vm.id?.uuidString ?? "")

        return vm
    }
}
