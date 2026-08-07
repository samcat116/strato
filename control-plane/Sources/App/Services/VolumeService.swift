import Foundation
import Vapor
import Fluent
import StratoShared

/// What is left of the volume agent path after ADR 0001 stages 5 and 8
/// (STR-148, STR-150).
///
/// Volume creation, deletion, attachment, detachment, resize and cloning are
/// desired state, and so are volume *snapshots*: the control plane writes the
/// intent, the assembler puts it on the agent's sync, and the agent's observed
/// report closes the loop. None of that goes through this type.
///
/// What remains is placement — choosing which agent hosts a new volume, a
/// decision that must be a committed fact before any sync can carry the volume.
///
/// Nothing else is left. The `volume_info` read left the protocol in stage 7
/// (STR-149) and this type never dispatched it; the two snapshot verbs became
/// desired artifacts in stage 8 (STR-150). So this is an `enum` of statics
/// now rather than an actor holding an `Application` — there is no request
/// state to own.
enum VolumeService {

    // MARK: - Placement

    /// The agent holding a volume's data. Local pools have a single replica, so
    /// "the volume's placement" is well-defined; rows without a replica
    /// (mid-provisioning races, pre-backfill data) fall back to the legacy
    /// `hypervisor_id` column, which is dual-written.
    ///
    /// Read once at snapshot admission and *recorded* on the artifact's row
    /// since STR-150, rather than re-derived per request: a desired entry has to
    /// appear in exactly one agent's sync, and a volume that moves must not
    /// silently orphan its snapshots into another host's tombstone set.
    static func agentHolding(_ volume: Volume, on db: any Database) async throws -> String? {
        guard let volumeID = volume.id else { return nil }
        if let replica = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .sort(\.$createdAt)
            .first()
        {
            return replica.agentId
        }
        return volume.hypervisorId
    }

    /// Pick the agent that should host a new volume's replica. Volume
    /// attachment goes through QEMU's block layer and requires the volume to
    /// live on an agent the VM can run on, so only online agents that can run
    /// QEMU are eligible — a volume placed on a Firecracker-only agent could
    /// never be attached. A pool with an explicit member list further
    /// restricts candidates to those members; an empty list (the default
    /// local pool) leaves all agents eligible.
    ///
    /// The wire-version filter is new with STR-148 and is the one placement
    /// gate in this file that refuses rather than degrades: with the imperative
    /// volume frames gone, an agent below v31 has no way to hear about a volume
    /// at all, so placing one there would produce a resource that could never
    /// converge and could only be deleted by force-clearing its finalizer.
    static func selectVolumeAgent(from agents: [Agent], memberAgentIds: [String] = []) -> Agent? {
        agents.first {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && WireProtocol.supportsVolumeSync($0.wireProtocolVersion ?? 0)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
        }
    }

}

// MARK: - Errors

enum VolumeServiceError: Error, LocalizedError {
    case noAgentsAvailable
    case agentNotFound(String)
    case agentOffline(String)
    case vmNotScheduled
    case volumeNotOnAgent
    case volumeNotAttached
    case firecrackerNotSupported
    case agentOperationFailed(String, String?)
    case operationUnsupportedByAgent(String, String)

    var errorDescription: String? {
        switch self {
        case .noAgentsAvailable:
            return "No agents available to handle volume operation"
        case .agentNotFound(let id):
            return "Agent '\(id)' not found"
        case .agentOffline(let id):
            return "Agent '\(id)' is offline"
        case .vmNotScheduled:
            return "VM is not scheduled on any hypervisor"
        case .volumeNotOnAgent:
            return "Volume is not stored on any agent"
        case .volumeNotAttached:
            return "Volume is not attached to any VM"
        case .firecrackerNotSupported:
            return "Volume operations are not supported for Firecracker VMs"
        case .agentOperationFailed(let error, let details):
            if let details {
                return "\(error) (\(details))"
            }
            return error
        case .operationUnsupportedByAgent(let operation, let agentId):
            return "Agent '\(agentId)' does not support '\(operation)'; upgrade the agent and retry"
        }
    }
}
