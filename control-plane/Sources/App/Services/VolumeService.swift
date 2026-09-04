import Foundation
import Vapor
import Fluent
import SQLKit
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

    struct InsufficientHostDisk: LocalizedError, Sendable {
        let required: Int64
        let candidates: [(name: String, available: Int64)]

        var errorDescription: String? {
            let hosts =
                candidates
                .map { "`\($0.name)` (\($0.available.formattedByteSize) available)" }
                .joined(separator: ", ")
            return "No local-pool agent has enough committed disk capacity for "
                + "\(required.formattedByteSize). Checked: \(hosts.isEmpty ? "no eligible agents" : hosts)."
        }
    }

    struct AgentHoldingResolution: Sendable {
        let agentID: String?
        let previousAgentID: String?
        let recordedAgentID: String?

        var changed: Bool {
            previousAgentID != recordedAgentID
        }
    }

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
        let localVolumes: [Volume]
        if scope.allVolumeIDs.isEmpty {
            localVolumes = []
        } else {
            localVolumes = try await Volume.query(on: db)
                .filter(\.$id ~~ Array(scope.allVolumeIDs))
                .all()
                .filter(scope.includes)
        }
        let cephVolumes = try await Volume.query(on: db)
            .filter(\.$reconcilerAgentId == agentId)
            .with(\.$pool)
            .all()
            .filter { $0.pool?.mode == .ceph }
        let localIDs = Set(localVolumes.compactMap(\.id))
        return localVolumes
            + cephVolumes.filter { volume in
                volume.id.map { !localIDs.contains($0) } ?? false
            }
    }

    /// Agent IDs whose active replica authoritatively places this volume.
    static func agentIDs(holding volume: Volume, on db: any Database) async throws -> [String] {
        if try await pool(of: volume, on: db)?.mode == .ceph {
            return volume.reconcilerAgentId.map { [$0] } ?? []
        }
        return try await replicas(of: volume, on: db).map(\.agentId)
    }

    /// Every agent with a physical copy, regardless of replica health. This is
    /// the teardown/finalizer scope and must not be used for placement or attachments.
    static func agentIDsWithPhysicalReplicas(
        of volume: Volume, on db: any Database
    ) async throws -> [String] {
        guard let volumeID = volume.id else { return [] }
        return try await allReplicas(volumeIDs: [volumeID], on: db)[volumeID]?.map(\.agentId) ?? []
    }

    /// The preferred lifecycle executor for a volume. Local pools have one
    /// active replica and preserve the old read-only lookup exactly. A Ceph
    /// executor is not data placement: when the recorded client is no longer
    /// reachable, move the reconciler role to another fresh client in the
    /// pool's site so an agent outage does not pin resize/snapshot/clone/delete.
    ///
    /// Read once at snapshot admission and *recorded* on the artifact's row
    /// since STR-150, rather than re-derived per request: a desired entry has to
    /// appear in exactly one agent's sync, and a volume that moves must not
    /// silently orphan its snapshots into another host's tombstone set.
    static func resolveAgentHolding(
        _ volume: Volume, on db: any Database
    ) async throws -> AgentHoldingResolution {
        if let initialPool = try await pool(of: volume, on: db), initialPool.mode == .ceph {
            let volumeID = try volume.requireID()
            let resolution = try await db.transaction { tx -> AgentHoldingResolution in
                guard let committed = try await Volume.find(volumeID, on: tx),
                    try await committed.lockAndRefresh(on: tx),
                    let committedPool = try await pool(of: committed, on: tx),
                    committedPool.mode == .ceph
                else {
                    return AgentHoldingResolution(
                        agentID: nil, previousAgentID: nil, recordedAgentID: nil)
                }

                let previous = committed.reconcilerAgentId
                if let previous,
                    let reconcilerID = UUID(uuidString: previous),
                    let reconciler = try await Agent.find(reconcilerID, on: tx),
                    StoragePool.agentCanReach(
                        agent: reconciler, pool: committedPool, replicaAgentIds: [])
                {
                    return AgentHoldingResolution(
                        agentID: previous, previousAgentID: previous, recordedAgentID: previous)
                }

                // One desired entry owns both lifecycle work and VM
                // attachment. Moving it while the old host still owes an
                // attach/detach (or while it names a VM there) would make the
                // replacement try to operate on another host's domain and
                // remove the old host's only detach instruction. Shared RBD
                // permits failover only from a fully settled detached state.
                guard committed.$vm.id == nil, committed.isConverged else {
                    return AgentHoldingResolution(
                        agentID: nil, previousAgentID: previous, recordedAgentID: previous)
                }

                let agents = try await Agent.query(on: tx).all()
                guard
                    let replacement = selectCephReconciler(
                        from: agents, pool: committedPool)?.id?.uuidString
                else {
                    return AgentHoldingResolution(
                        agentID: nil, previousAgentID: previous, recordedAgentID: previous)
                }
                guard let sql = tx as? any SQLDatabase else {
                    throw ConvergenceWriteError.unsupportedDatabase
                }
                try await sql.raw(
                    """
                    UPDATE volumes
                    SET reconciler_agent_id = \(bind: replacement)
                    WHERE id = \(bind: volumeID)
                    """
                ).run()
                return AgentHoldingResolution(
                    agentID: replacement,
                    previousAgentID: previous,
                    recordedAgentID: replacement)
            }
            // The request model may predate an observed-state or mutation
            // writer. Update only the one scalar this resolver owns; the
            // later ResourceMutation row lock refreshes every other field.
            volume.reconcilerAgentId = resolution.recordedAgentID
            return resolution
        }
        return AgentHoldingResolution(
            agentID: try await replicas(of: volume, on: db).first?.agentId,
            previousAgentID: nil,
            recordedAgentID: nil)
    }

    /// Claim initial Ceph execution ownership without reviving a volume whose
    /// create raced with deletion. Only generation 1's still-present,
    /// unassigned row may be changed; all observed and desired columns remain
    /// untouched by the targeted update.
    static func assignInitialCephReconciler(
        volumeID: UUID, expectedGeneration: Int64, agentID: String,
        on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw ConvergenceWriteError.unsupportedDatabase
        }
        return try await sql.raw(
            """
            UPDATE volumes
            SET reconciler_agent_id = \(bind: agentID)
            WHERE id = \(bind: volumeID)
              AND desired_status = \(bind: DesiredVolumeStatus.present.rawValue)
              AND generation = \(bind: expectedGeneration)
              AND reconciler_agent_id IS NULL
            RETURNING id
            """
        ).first() != nil
    }

    /// Resolve the agent-owned attachment for a volume. Prefer the receiving agent's
    /// own copy, then another healthy/provisioning copy. The latter is relevant
    /// only to a future shared pool; today's local-pool reachability guard makes
    /// the first branch mandatory before an attachment is accepted.
    static func diskAttachment(
        for volume: Volume, accessibleFrom agentId: String? = nil, on db: any Database
    ) async throws -> DiskAttachment? {
        if try await pool(of: volume, on: db)?.mode == .ceph {
            return volume.diskAttachment
        }
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
        let poolIDs = Array(Set(volumes.compactMap { $0.$pool.id }))
        let pools =
            poolIDs.isEmpty
            ? []
            : try await StoragePool.query(on: db)
                .filter(\.$id ~~ poolIDs).all()
        let poolsByID = Dictionary(
            uniqueKeysWithValues: pools.compactMap { pool in
                pool.id.map { ($0, pool) }
            })
        var result: [UUID: DiskAttachment] = [:]
        for volume in volumes {
            guard let volumeID = volume.id else { continue }
            if volume.$pool.id.flatMap({ poolsByID[$0] })?.mode == .ceph {
                if let attachment = volume.diskAttachment { result[volumeID] = attachment }
                continue
            }
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
    static func selectVolumeAgent(
        from agents: [Agent],
        memberAgentIds: [String] = [],
        sizeBytes: Int64 = 0
    ) -> Agent? {
        agents.first {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
                && $0.availableDisk >= sizeBytes
        }
    }

    /// Select and atomically reserve one host's committed disk pool. The
    /// current allocation ratio is intentionally 1:1; a future site-scoped
    /// ratio can widen `availableDisk` before it reaches this seam without
    /// changing the race-closing reservation protocol.
    static func selectAndReserveVolumeAgent(
        sizeBytes: Int64,
        volumeId: UUID,
        agents: [Agent],
        memberAgentIds: [String],
        coordination: CoordinationService
    ) async throws -> Agent {
        let eligible = eligibleLocalVolumeAgents(from: agents, memberAgentIds: memberAgentIds)
        let ids = eligible.compactMap { $0.id?.uuidString }
        let reservationId = volumeReservationID(volumeId)

        for _ in 1...max(1, eligible.count + 2) {
            let active = await coordination.activeReservations(agentIds: ids)
            guard
                let selected = eligible.first(where: { agent in
                    guard let id = agent.id?.uuidString else { return false }
                    let reserved = max(Int64(0), active[id]?.disk ?? 0)
                    let effective = reserved >= agent.availableDisk ? 0 : agent.availableDisk - reserved
                    return effective >= sizeBytes
                }), let agentId = selected.id?.uuidString
            else {
                throw InsufficientHostDisk(
                    required: sizeBytes,
                    candidates: eligible.map { agent in
                        let id = agent.id?.uuidString ?? ""
                        let reserved = max(Int64(0), active[id]?.disk ?? 0)
                        return (
                            agent.name,
                            reserved >= agent.availableDisk ? 0 : agent.availableDisk - reserved
                        )
                    })
            }

            if await coordination.reserveCapacity(
                agentId: agentId,
                vmId: reservationId,
                amounts: ReservationAmounts(cpu: 0, memory: 0, disk: sizeBytes),
                capacity: ReservationAmounts(
                    cpu: selected.availableCPU,
                    memory: selected.availableMemory,
                    disk: selected.availableDisk))
            {
                return selected
            }
        }

        throw InsufficientHostDisk(
            required: sizeBytes,
            candidates: eligible.map { ($0.name, $0.availableDisk) })
    }

    static func volumeReservationID(_ volumeId: UUID) -> String {
        "volume:\(volumeId.uuidString)"
    }

    private static func eligibleLocalVolumeAgents(
        from agents: [Agent], memberAgentIds: [String]
    ) -> [Agent] {
        agents.filter {
            $0.status == .online && $0.supportedHypervisors.contains(.qemu)
                && (memberAgentIds.isEmpty || memberAgentIds.contains($0.id?.uuidString ?? ""))
        }
    }

    /// Pick one lifecycle executor for a shared RBD volume. Site membership
    /// plus a fresh functional Ceph-client observation is the complete client
    /// configuration gate; the selected id is not data placement.
    static func selectCephReconciler(from agents: [Agent], pool: StoragePool) -> Agent? {
        guard pool.mode == .ceph else { return nil }
        return
            agents
            .filter { StoragePool.agentCanReach(agent: $0, pool: pool, replicaAgentIds: []) }
            .sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
            .first
    }

    static func pool(of volume: Volume, on db: any Database) async throws -> StoragePool? {
        guard let poolID = volume.$pool.id else { return nil }
        return try await StoragePool.find(poolID, on: db)
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
