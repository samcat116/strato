import Foundation
import StratoShared

enum AgentServiceError: Error, LocalizedError, Sendable {
    case schedulingFailed(String)
    case invalidResponse(String)
    case unsupportedProtocolVersion(agentName: String, version: Int)
    case missingOrganizationScope(agentName: String)

    var errorDescription: String? {
        switch self {
        case .schedulingFailed(let reason):
            return "Workload placement failed: \(reason)"
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
