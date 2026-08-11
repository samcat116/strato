import Fluent
import Vapor

extension Request {
    /// Fetch a load balancer and enforce an object-level Cedar action. Keeping
    /// this in the handler mirrors VM authorization and makes every nested
    /// listener/backend route defend itself instead of trusting only a path
    /// middleware mapping.
    func authorizedLoadBalancer(_ loadBalancerID: UUID, action: String) async throws -> LoadBalancer {
        guard let loadBalancer = try await LoadBalancer.find(loadBalancerID, on: db) else {
            throw Abort(.notFound, reason: "Load balancer not found")
        }
        try await authorize(action, on: IAMNode(type: .loadBalancer, id: loadBalancerID))
        return loadBalancer
    }
}
