import Foundation
import StratoShared

// Supporting value types for AgentService: the service's response/error enums.
// The in-memory AgentInfo snapshot that used to live here is gone (issue
// #261) — the Agent database row plus the Valkey presence/route keys are the
// registry, so every replica shares one view.

// MARK: - Supporting Types

enum AgentServiceResponse: Sendable {
    case success(AnyCodableValue?)
    case error(String, String?)
}

enum AgentServiceError: Error, LocalizedError, Sendable {
    case noAvailableAgent
    case schedulingFailed(String)
    case agentNotFound(String)
    case vmNotMapped(String)
    case requestTimeout
    case connectionLost
    case invalidResponse(String)
    case unsupportedProtocolVersion(agentName: String, version: Int)
    case missingOrganizationScope(agentName: String)

    var errorDescription: String? {
        switch self {
        case .noAvailableAgent:
            return "No available agent found for VM deployment"
        case .schedulingFailed(let reason):
            return "VM placement failed: \(reason)"
        case .agentNotFound(let agentId):
            return "Agent not found: \(agentId)"
        case .vmNotMapped(let vmId):
            return "VM not mapped to any agent: \(vmId)"
        case .requestTimeout:
            return "Request to agent timed out"
        case .connectionLost:
            return "Connection to agent was lost before a response was received"
        case .invalidResponse(let message):
            return "Invalid response from agent: \(message)"
        case .unsupportedProtocolVersion(let agentName, let version):
            return
                "Agent '\(agentName)' registered with wire protocol version \(version), which predates "
                + "desired-state sync. The imperative message path was removed (issue #261); upgrade the agent."
        case .missingOrganizationScope(let agentName):
            return
                "Agent '\(agentName)' is new but its registration token carries no organization; "
                + "agents are dedicated capacity and must be minted a token scoped to an organization or OU."
        }
    }
}
