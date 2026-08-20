import Vapor
import Fluent

extension Request {
    /// Fetch a sandbox and enforce a canonical action on it in one call, through
    /// the evaluator.
    ///
    /// The per-handler defense-in-depth complement to `AuthorizationMiddleware`,
    /// mirroring `authorizedVM(_:action:)`: individual sandbox handlers
    /// should not rely solely on the middleware's path-prefix guard for
    /// object-level authorization.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the sandbox
    ///   does not exist, `.forbidden` if the user lacks `action` on it.
    func authorizedSandbox(_ sandboxID: UUID, action: String) async throws -> Sandbox {
        guard let sandbox = try await Sandbox.find(sandboxID, on: db) else {
            throw Abort(.notFound)
        }

        try await authorize(action, on: IAMNode(type: .sandbox, id: sandboxID))

        return sandbox
    }
}
