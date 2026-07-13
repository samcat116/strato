import Fluent
import Vapor
import StratoShared

/// Read API for asynchronous resource operations (issue #259). Mutation
/// endpoints return an operation with `202 Accepted`; clients poll here until
/// it reaches a terminal state. Per-VM history lives under
/// `GET /api/vms/:vmID/operations`.
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

        guard let operation = try await ResourceOperation.find(operationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Operation visibility follows the resource's `read` permission while
        // it exists — each resource kind supplies its own check. A delete
        // operation outlives the row it removes, so once the resource is gone
        // fall back to initiator visibility (the client polling its own
        // delete to completion).
        switch operation.resourceKind {
        case .virtualMachine:
            if try await VM.find(operation.resourceID, on: req.db) != nil {
                _ = try await req.authorizedVM(operation.resourceID, permission: "read")
                return OperationResponse(from: operation)
            }
        case .sandbox:
            if try await Sandbox.find(operation.resourceID, on: req.db) != nil {
                _ = try await req.authorizedSandbox(operation.resourceID, permission: "read")
                return OperationResponse(from: operation)
            }
        }

        guard user.isSystemAdmin || operation.userID == user.id else {
            throw Abort(.notFound)
        }

        return OperationResponse(from: operation)
    }
}
