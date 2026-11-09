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
                "Agent '\(agentName)' offered protocol major \(version); this control plane "
                + "requires Protobuf protocol major \(AgentProtocolCompatibility.major)."

        case .missingOrganizationScope(let agentName):
            return
                "Agent '\(agentName)' is new but its registration token carries no organization; "
                + "agents are dedicated capacity and must be minted a token scoped to an organization or folder."
        }
    }
}
