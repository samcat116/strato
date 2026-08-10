import Foundation
import StratoShared

// Supporting value types for AgentService: the service's error enum. The
// in-memory AgentInfo snapshot that used to live here is gone (issue #261) —
// the Agent database row plus the Valkey presence key are the registry, so
// every replica shares one view. `AgentServiceResponse` — the success/error
// verdict of a correlated exchange — went with the exchanges themselves
// (STR-152).

// MARK: - Supporting Types

enum AgentServiceError: Error, LocalizedError, Sendable {
    case schedulingFailed(String)
    case agentNotFound(String)
    case invalidResponse(String)
    case unsupportedProtocolVersion(agentName: String, version: Int)
    case missingOrganizationScope(agentName: String)

    var errorDescription: String? {
        switch self {
        case .schedulingFailed(let reason):
            return "VM placement failed: \(reason)"
        case .agentNotFound(let agentId):
            return "Agent not found: \(agentId)"
        case .invalidResponse(let message):
            return "Invalid response from agent: \(message)"
        case .unsupportedProtocolVersion(let agentName, let version):
            return
                "Agent '\(agentName)' registered with wire protocol version \(version); this control plane "
                + "requires exactly v\(WireProtocol.currentVersion). Strato deploys the control plane and "
                + "agents together. Deploy matching builds; an agent rejected before self-update must be "
                + "updated manually."
        case .missingOrganizationScope(let agentName):
            return
                "Agent '\(agentName)' is new but its registration token carries no organization; "
                + "agents are dedicated capacity and must be minted a token scoped to an organization or folder."
        }
    }
}
