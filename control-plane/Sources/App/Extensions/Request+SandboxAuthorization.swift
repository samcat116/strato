import Fluent
import Vapor

extension Request {
    /// Fetch a sandbox and enforce a permission on it in one call, through
    /// the evaluator.
    ///
    /// The per-handler defense-in-depth complement to `AuthorizationMiddleware`,
    /// mirroring `authorizedVM(_:permission:)`: individual sandbox handlers
    /// should not rely solely on the middleware's path-prefix guard for
    /// object-level authorization.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the sandbox
    ///   does not exist, `.forbidden` if the user lacks `permission` on it.
    func authorizedSandbox(_ sandboxID: UUID, permission: String) async throws -> Sandbox {
        guard let sandbox = try await Sandbox.find(sandboxID, on: db) else {
            throw Abort(.notFound)
        }

        try await authorize(permission, on: "sandbox", id: sandbox.id?.uuidString ?? "")

        return sandbox
    }
}
