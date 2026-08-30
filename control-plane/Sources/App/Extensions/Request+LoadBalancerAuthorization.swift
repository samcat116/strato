import Fluent
import Vapor

extension Request {
    /// Fetch a load balancer and enforce an object-level Cedar action. Keeping
    /// this in the handler mirrors VM authorization and makes every nested
    /// listener/backend route defend itself instead of trusting only a path
    /// middleware mapping.
    func authorizedLoadBalancer(_ loadBalancerID: UUID, action: String) async throws -> LoadBalancer {
        try await authorizedResource(
            loadBalancerID,
            as: LoadBalancer.self,
            nodeType: .loadBalancer,
            action: action,
            notFoundReason: "Load balancer not found"
        )
    }
}
