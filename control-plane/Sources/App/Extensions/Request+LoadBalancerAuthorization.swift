import Vapor
import Fluent

extension Request {
    /// Fetch a load balancer and enforce an object-level Cedar action. Keeping
    /// this in the handler mirrors VM authorization and makes every nested
    /// listener/backend route defend itself instead of trusting only a path
    /// middleware mapping.
    func authorizedLoadBalancer(
        _ loadBalancerID: UUID, action: String
    ) async throws -> LoadBalancerSnapshot {
        guard let loadBalancer = try await LegacyLoadBalancerStore.find(id: loadBalancerID, on: db) else {
            throw Abort(.notFound, reason: "Load balancer not found")
        }
        try await authorize(action, on: IAMNode(type: .loadBalancer, id: loadBalancerID))
        return loadBalancer
    }
}
