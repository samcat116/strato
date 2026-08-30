import Fluent
import Vapor

extension Request {
    /// Fetch a VM and enforce a canonical action on it in one call, through the
    /// evaluator.
    ///
    /// This is the per-handler defense-in-depth complement to
    /// `AuthorizationMiddleware`: individual VM handlers should not rely solely
    /// on the middleware's path-prefix guard for object-level authorization.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.notFound` if the VM does not
    ///   exist, `.forbidden` if the user lacks `action` on this VM.
    func authorizedVM(_ vmID: UUID, action: String) async throws -> VM {
        guard let vm = try await VM.find(vmID, on: db) else {
            throw Abort(.notFound)
        }

        try await authorize(action, on: IAMNode(type: .virtualMachine, id: vmID))

        return vm
    }

    /// Resolve a VM id supplied in another resource's request body. Returns
    /// `404` for both missing and unauthorized VMs so attach/detach endpoints
    /// cannot serve as a cross-project existence oracle (issue #881). Use
    /// `authorizedVM(_:action:)` when the VM is the route's subject instead.
    /// Evaluator denials remain distinguishable in the IAM decision log, and by
    /// timing because authorization runs only for an existing VM; random UUIDv4
    /// ids make that residual signal impractical to sweep.
    func reachableVM(_ vmID: UUID, action: String) async throws -> VM {
        guard let vm = try await VM.find(vmID, on: db),
            try await can(action, on: IAMNode(type: .virtualMachine, id: vmID))
        else {
            throw Abort(.notFound, reason: "VM \(vmID) not found")
        }
        return vm
    }
}
