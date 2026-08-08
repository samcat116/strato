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
    case cannotIsolateSameNamedNetworks(agentName: String, version: Int, names: [String])
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
                "Agent '\(agentName)' registered with wire protocol version \(version), which predates "
                + "desired-state sync. The imperative message path was removed (issue #261); upgrade the agent."
        case .cannotIsolateSameNamedNetworks(let agentName, let version, let names):
            return
                "Agent '\(agentName)' registered with wire protocol version \(version), which keys OVN DHCP "
                + "rows on the network name — but networks it would realize share a name across projects "
                + "(\(names.sorted().joined(separator: ", "))). Those tenants' DHCP configuration would be "
                + "merged (issue #765). Upgrade the agent to protocol "
                + "v\(WireProtocol.projectNetworkIsolationMinimumVersion) or rename the networks."
        case .missingOrganizationScope(let agentName):
            return
                "Agent '\(agentName)' is new but its registration token carries no organization; "
                + "agents are dedicated capacity and must be minted a token scoped to an organization or folder."
        }
    }
}
