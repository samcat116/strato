import Fluent
import Vapor
import StratoShared

/// Read API for asynchronous VM operations (issue #259). Mutation endpoints
/// return an operation with `202 Accepted`; clients poll here until it reaches
/// a terminal state. Per-VM history lives under `GET /api/vms/:vmID/operations`.
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

        guard let operation = try await VMOperation.find(operationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Operation visibility follows the VM's `read` permission. A delete
        // operation outlives its VM row, so once the VM is gone fall back to
        // initiator visibility (the client polling its own delete to completion).
        if try await VM.find(operation.vmID, on: req.db) != nil {
            _ = try await req.authorizedVM(operation.vmID, permission: "read")
        } else {
            guard user.isSystemAdmin || operation.userID == user.id else {
                throw Abort(.notFound)
            }
        }

        return OperationResponse(from: operation)
    }
}
