import Fluent
import Vapor

extension Request {
    /// Requires a canonical agent action, including the system-admin-only
    /// repair path for legacy agents that have no organization scope.
    func requireAgentAction(_ action: String, on agent: Agent) async throws {
        guard agent.organizationScope != nil else {
            _ = try await requireSystemAdmin("This agent has no owning organization")
            return
        }
        let allowed = try await can(action, on: IAMNode(type: .agent, id: try agent.requireID()))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this agent")
        }
    }
}
