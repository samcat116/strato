import Foundation
import StratoShared

// Supporting value types for AgentService: the in-memory agent snapshot and the
// service's response/error enums. Relocated from AgentService.swift to keep the
// actor file focused on behavior.

// MARK: - Supporting Types

struct AgentInfo: Sendable {
    let id: String      // Database UUID
    let name: String    // Human-readable name
    let hostname: String
    let version: String
    let capabilities: [String]
    /// Host CPU architecture; nil for agents that predate architecture reporting
    let architecture: CPUArchitecture?
    /// Hypervisors on the host with probed availability, capabilities, and
    /// unavailability reasons. For agents that predate the structured report
    /// this is derived from their legacy capability strings
    /// (`AgentRegisterMessage.effectiveHypervisors`).
    let hypervisors: [HypervisorSupport]
    /// Host networking capability; nil when the agent reported none (older
    /// agent, or an OVN backend that failed to connect at startup).
    let networkCapability: NetworkCapability?
    var resources: AgentResources
    var lastHeartbeat: Date
    var status: AgentStatus

    /// Hypervisor backends this agent can actually run. Agents probe each
    /// backend before reporting it, so an empty list means the agent cannot
    /// run VMs at all — it stays registered but is never eligible for
    /// placement. No QEMU fallback here: assuming QEMU for an empty list
    /// would defeat the agent-side probe in exactly the case it exists for.
    var supportedHypervisors: [HypervisorType] {
        hypervisors.filter(\.available).map(\.type)
    }

    /// Only OVN-backed agents can provide VM-to-VM networking; user-mode
    /// (SLIRP) agents cannot. Agents that predate structured network
    /// capability reporting are judged by their legacy capability strings.
    var supportsInterVMNetworking: Bool {
        if let networkCapability {
            return networkCapability == .overlay
        }
        return capabilities.contains("ovn_networking")
    }
}

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
        }
    }
}
