import Vapor
import Fluent

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

    /// Resolve a VM named in a *request body* — the attach/detach endpoints'
    /// second resource — answering `404` for both "no such VM" and "you may not
    /// perform `action` on this VM", so the two are indistinguishable (issue #881).
    ///
    /// Use this, not `authorizedVM(_:action:)`, whenever the id came from
    /// the body of a request addressed to some *other* resource (a volume, a
    /// security group, a floating IP). The distinction matters because of who
    /// is asking: a caller who reaches `/api/vms/{id}` has been handed that id
    /// as the subject of the request and a `403` tells them nothing they could
    /// not infer from the route, whereas a caller who may pass any id in a body
    /// can sweep ids and read `404` vs `403` as an existence oracle for VMs in
    /// projects they cannot see. The lookup necessarily precedes the check, so
    /// the only way to close that is to answer the same thing either way.
    ///
    /// The cost is deliberate and was weighed once for the whole API rather
    /// than per handler: an authenticated caller who can *see* a VM but lacks
    /// `action` on it now gets `404` from these endpoints instead of `403`,
    /// which is less informative than it could be for them. `404` is the choice
    /// because it is the answer already given to a resource outside the
    /// caller's reach elsewhere — `LogicalNetworkService.resolveForWorkloadCreate`
    /// for networks, VM create's `securityGroupIds` for groups.
    ///
    /// Refusals that *follow* this call may still be more specific: having
    /// cleared the check, the caller can already see the VM, so a containment
    /// or state refusal discloses nothing (the ordering rule `ProjectContainment`
    /// documents).
    ///
    /// **Do not reintroduce a distinguishing message to make support easier.**
    /// The cost of one answer is that a caller holding `read` but not `update`
    /// can no longer self-diagnose their own `404`. They do not have to: the
    /// deny is an ordinary evaluator decision, so it lands in the IAM decision
    /// log with its principal, action, and node, and an operator can tell
    /// "absent" from "forbidden" there. That log is the channel for the
    /// distinction; the response body is not.
    ///
    /// "Indistinguishable" means *in the response*. The absent path costs one
    /// query and the forbidden path a query plus an evaluation, so the two
    /// remain separable by timing. Closing that would mean evaluating against a
    /// VM that does not exist, and the severity does not justify it — ids are
    /// random UUIDv4, so latency alone is nothing cheap to sweep.
    func reachableVM(_ vmID: UUID, action: String) async throws -> VM {
        guard let vm = try await VM.find(vmID, on: db),
            try await can(action, on: IAMNode(type: .virtualMachine, id: vmID))
        else {
            throw Abort(.notFound, reason: "VM \(vmID) not found")
        }
        return vm
    }
}
