import Fluent
import Vapor
import StratoShared

/// Read API for asynchronous resource operations (issue #259).
///
/// Since ADR 0001 stage 4 (STR-147) this is a **compatibility façade**. VM and
/// sandbox lifecycle mutations answer `202 {resource, targetGeneration,
/// mutationId}` and are meant to be followed by polling the resource's
/// `conditions`; they write no operation row. This endpoint keeps answering for
/// them anyway, synthesizing the operation view from the `resource_events` row
/// the mutation did write plus the resource's current conditions
/// (`OperationFacade`), so a client written against the old contract keeps
/// working unchanged.
///
/// It is also the *supported* way to follow a **delete** to completion, for the
/// one thing conditions cannot express: a delete succeeds by its resource
/// ceasing to exist, and a client polling the resource sees a `404` that means
/// deleted, never-existed and not-authorized alike. Here the authorization is
/// done for the caller and the answer comes from the terminal event the reap
/// appended, so `succeeded` is a positive record rather than an inference.
///
/// The verbs still dispatched as imperative agent RPCs — VM reboot, the
/// snapshot verbs — keep real rows, and are served from them. Per-resource
/// history lives under `GET /api/vms/:vmID/operations`.
struct OperationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let operations = routes.grouped("api", "operations")
        operations.get(":operationID", use: show)
    }

    func show(req: Request) async throws -> OperationResponse {
        let user = try req.auth.require(User.self)

        guard let operationID = req.parameters.get("operationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid operation ID")
        }

        // An operation row first — the id space is disjoint, and rows are the
        // narrower, older case.
        if let operation = try await ResourceOperation.find(operationID, on: req.db) {
            try await authorize(
                resourceKind: operation.resourceKind, resourceID: operation.resourceID,
                initiatedBy: operation.userID == user.id, req: req)
            return OperationResponse(from: operation)
        }

        // Otherwise a recorded mutation. Only `.requested` rows are addressable:
        // a terminal row is the evidence a request's verdict is read from, not
        // an operation in its own right, and answering for its id would report
        // one mutation under two ids.
        guard let event = try await ResourceEvent.find(operationID, on: req.db),
            event.phase == .requested
        else {
            throw Abort(.notFound)
        }

        try await authorize(
            resourceKind: event.resourceKind, resourceID: event.resourceID,
            initiatedBy: event.actorType == .user && event.actorID == user.id,
            req: req)
        return try await OperationFacade.response(for: event, on: req.db)
    }

    /// Visibility follows the resource's `read` permission while it exists —
    /// each resource kind supplies its own check. A delete outlives the row it
    /// removes, so once the resource is gone this falls back to initiator
    /// visibility (the client polling its own delete to completion).
    private func authorize(
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        initiatedBy isInitiator: Bool,
        req: Request
    ) async throws {
        switch resourceKind {
        case .virtualMachine:
            if try await VM.find(resourceID, on: req.db) != nil {
                _ = try await req.authorizedVM(resourceID, permission: "read")
                return
            }
        case .sandbox:
            if try await Sandbox.find(resourceID, on: req.db) != nil {
                _ = try await req.authorizedSandbox(resourceID, permission: "read")
                return
            }
        case .volume:
            if try await Volume.find(resourceID, on: req.db) != nil {
                _ = try await req.authorizedVolume(resourceID, permission: "read")
                return
            }
        }

        // The resource is gone, so there is no node left to evaluate against.
        // Two things can still make the record visible, and neither is a check
        // skipped: the initiator sees their own mutation by row scoping, and
        // an admin sees it through the same scopeless-row gate the other
        // node-less surfaces use — which flags the read for the admin audit
        // trail rather than reading `isSystemAdmin` inline.
        req.markRowScopedAuthorization()
        guard isInitiator || req.allowsScopelessPlatformRow() else {
            throw Abort(.notFound)
        }
    }
}
