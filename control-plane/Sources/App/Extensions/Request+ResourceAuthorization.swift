import Fluent
import Vapor

extension Request {
    /// Fetch a UUID-keyed resource and enforce a canonical action on it.
    func authorizedResource<M: Model & Sendable>(
        _ id: UUID,
        as model: M.Type,
        nodeType: IAMNodeType,
        action: String,
        notFoundReason: String? = nil
    ) async throws -> M where M.IDValue == UUID {
        guard let resource = try await model.find(id, on: db) else {
            throw Abort(.notFound, reason: notFoundReason)
        }

        try await authorize(action, on: IAMNode(type: nodeType, id: id))

        return resource
    }
}
