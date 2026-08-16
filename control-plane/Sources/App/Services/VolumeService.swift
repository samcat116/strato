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

    struct AgentReplicaScope {
        let allVolumeIDs: Set<UUID>
        let authoritativeVolumeIDs: Set<UUID>

        func includes(_ volume: Volume) -> Bool {
            guard let volumeID = volume.id else { return false }
            return volume.desiredStatus == .absent
                ? allVolumeIDs.contains(volumeID)
                : authoritativeVolumeIDs.contains(volumeID)
        }
    }

    /// Replica states that may participate in placement and attachment resolution.
    /// A faulted/degraded copy must never keep a volume pinned to an agent or
    /// leak a stale attachment into a VM specification.
    static let authoritativeReplicaStates: [VolumeReplicaState] = [.healthy, .provisioning]

    // MARK: - Placement

    /// The replicas that authoritatively place a volume. Healthy copies sort
    /// before provisioning copies so reads prefer confirmed bytes, while a
    /// freshly accepted create is still routable before its first observation.
    static func replicas(of volume: Volume, on db: any Database) async throws -> [VolumeReplica] {
        guard let volumeID = volume.id else { return [] }
        return try await replicas(volumeIDs: [volumeID], on: db)[volumeID] ?? []
    }

    /// Batched counterpart used by assemblers and API lists.
    static func replicas(volumeIDs: [UUID], on db: any Database) async throws
        -> [UUID: [VolumeReplica]]
    {
        guard !volumeIDs.isEmpty else { return [:] }
        let rows = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id ~~ volumeIDs)
            .filter(\.$state ~~ authoritativeReplicaStates)
            .all()
        return Dictionary(grouping: rows, by: \.$volume.id)
            .mapValues { $0.sorted(by: replicaPrecedes) }
    }

    /// All physical copies for API/inventory views, including copies that are
    /// degraded, resyncing, or faulted and therefore cannot drive placement.
    static func allReplicas(volumeIDs: [UUID], on db: any Database) async throws
        -> [UUID: [VolumeReplica]]
    {
        guard !volumeIDs.isEmpty else { return [:] }
        let rows = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id ~~ volumeIDs)
            .all()
        return Dictionary(grouping: rows, by: \.$volume.id)
            .mapValues { $0.sorted(by: replicaPrecedes) }
    }

    /// Replica membership for one agent's desired/observed reconciliation.
    /// Live volumes use only placement-authoritative copies, while terminating
    /// volumes include every physical copy so degraded, resyncing, and faulted
    /// data must also be torn down before the logical row can be reaped.
    static func replicaScope(onAgent agentId: String, on db: any Database) async throws
        -> AgentReplicaScope
    {
        let replicas = try await VolumeReplica.query(on: db)
            .filter(\.$agentId == agentId)
            .all()
        return AgentReplicaScope(
            allVolumeIDs: Set(replicas.map(\.$volume.id)),
            authoritativeVolumeIDs: Set(
                replicas.lazy
                    .filter { authoritativeReplicaStates.contains($0.state) }
                    .map(\.$volume.id)))
    }

    /// Every logical volume this agent must reconcile. Inactive copies are
    /// excluded from live placement, but remain visible while terminating.
    static func volumes(onAgent agentId: String, on db: any Database) async throws -> [Volume] {
        let scope = try await replicaScope(onAgent: agentId, on: db)
        guard !scope.allVolumeIDs.isEmpty else { return [] }
        return try await Volume.query(on: db)
            .filter(\.$id ~~ Array(scope.allVolumeIDs))
            .all()
            .filter(scope.includes)
    }

    /// Agent IDs whose active replica authoritatively places this volume.
    static func agentIDs(holding volume: Volume, on db: any Database) async throws -> [String] {
        try await replicas(of: volume, on: db).map(\.agentId)
    }

    /// Every agent with a physical copy, regardless of replica health. This is
    /// the teardown/finalizer scope and must not be used for placement or attachments.
    static func agentIDsWithPhysicalReplicas(
        of volume: Volume, on db: any Database
    ) async throws -> [String] {
        guard let volumeID = volume.id else { return [] }
        return try await allReplicas(volumeIDs: [volumeID], on: db)[volumeID]?.map(\.agentId) ?? []
    }

    /// The preferred agent holding a volume's data. Local pools have one active
    /// replica. The deterministic first copy also supplies the current
    /// single-agent snapshot/clone API until distributed storage defines a
    /// multi-copy capture policy.
    ///
    /// Read once at snapshot admission and *recorded* on the artifact's row
    /// since STR-150, rather than re-derived per request: a desired entry has to
    /// appear in exactly one agent's sync, and a volume that moves must not
    /// silently orphan its snapshots into another host's tombstone set.
    static func agentHolding(_ volume: Volume, on db: any Database) async throws -> String? {
        try await replicas(of: volume, on: db).first?.agentId
    }

    /// Resolve the agent-owned attachment for a volume. Prefer the receiving agent's
    /// own copy, then another healthy/provisioning copy. The latter is relevant
    /// only to a future shared pool; today's local-pool reachability guard makes
    /// the first branch mandatory before an attachment is accepted.
    static func diskAttachment(
        for volume: Volume, accessibleFrom agentId: String? = nil, on db: any Database
    ) async throws -> DiskAttachment? {
        let replicas = try await replicas(of: volume, on: db)
        if let agentId,
            let local = replicas.first(where: { $0.agentId == agentId && $0.diskAttachment != nil })
        {
            return local.diskAttachment
        }
        return replicas.first(where: { $0.diskAttachment != nil })?.diskAttachment
    }

    /// Batch attachment projection for VM desired-state assembly.
    static func diskAttachments(
        for volumes: [Volume], accessibleFrom agentId: String, on db: any Database
    ) async throws -> [UUID: DiskAttachment] {
        let ids = volumes.compactMap(\.id)
        let grouped = try await replicas(volumeIDs: ids, on: db)
        var result: [UUID: DiskAttachment] = [:]
        for volumeID in ids {
            guard let replicas = grouped[volumeID] else { continue }
            let resolved =
                replicas.first(where: { $0.agentId == agentId && $0.diskAttachment != nil })?
                .diskAttachment
                ?? replicas.first(where: { $0.diskAttachment != nil })?.diskAttachment
            if let resolved { result[volumeID] = resolved }
        }
        return result
    }

    static func response(for volume: Volume, on db: any Database) async throws -> VolumeResponse {
        let grouped = try await allReplicas(volumeIDs: volume.id.map { [$0] } ?? [], on: db)
        return VolumeResponse(from: volume, replicas: volume.id.flatMap { grouped[$0] } ?? [])
    }

    static func responses(for volumes: [Volume], on db: any Database) async throws -> [VolumeResponse] {
        let grouped = try await allReplicas(volumeIDs: volumes.compactMap(\.id), on: db)
        return volumes.map { volume in
            VolumeResponse(from: volume, replicas: volume.id.flatMap { grouped[$0] } ?? [])
        }
    }

    /// Pick the agent that should host a new volume's replica. Volume
    /// attachment goes through QEMU's block layer and requires the volume to
    /// live on an agent the VM can run on, so only online agents that can run
    /// QEMU are eligible — a volume placed on a Firecracker-only agent could
    /// never be attached. A pool with an explicit member list further
    /// restricts candidates to those members; an empty list (the default
    /// local pool) leaves all agents eligible.
    ///
    static func selectVolumeAgent(from agents: [Agent], memberAgentIds: [String] = []) -> Agent? {
        agents.first {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
        }
    }

    private static func replicaPrecedes(_ lhs: VolumeReplica, _ rhs: VolumeReplica) -> Bool {
        func rank(_ state: VolumeReplicaState) -> Int {
            switch state {
            case .healthy: 0
            case .provisioning: 1
            case .degraded: 2
            case .resyncing: 3
            case .faulted: 4
            }
        }
        let left = (rank(lhs.state), lhs.createdAt ?? .distantPast, lhs.id?.uuidString ?? "")
        let right = (rank(rhs.state), rhs.createdAt ?? .distantPast, rhs.id?.uuidString ?? "")
        return left < right
    }

}
