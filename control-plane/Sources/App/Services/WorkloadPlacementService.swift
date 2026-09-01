import Foundation
import Fluent
import NIOConcurrencyHelpers
import SQLKit
import StratoShared
import Vapor

actor WorkloadPlacementService {
    private let app: Application

    init(app: Application) {
        self.app = app
    }

    // MARK: - VM Operations

    /// Selects an agent, persists the VM placement, and triggers desired-state sync.
    func createVM(
        vm: VM,
        db: Database,
        strategy: SchedulingStrategy? = nil,
        image: Image? = nil
    ) async throws {
        let schedulableAgents = await schedulableAgentsFromDatabase()
        let vmId = try vm.requireID().uuidString
        let imageArchitecture = image?.architecture
        let reservedAgentId = NIOLockedValueBox<String?>(nil)

        // Placement and API updates both take this row lock before deciding
        // from or saving the VM. The create request's `vm` is only the snapshot
        // captured before background dispatch: an immediate update may have
        // switched metadata off while this task was waiting to run. Reloading
        // under the lock makes that committed intent the scheduler input and
        // prevents the placement save from writing the captured value back.
        let agentId: String
        do {
            agentId = try await db.transaction { [self] tx in
                guard try await vm.lockAndRefresh(on: tx),
                    let currentVM = try await VM.find(vm.id, on: tx)
                else {
                    throw Abort(.notFound, reason: "VM no longer exists")
                }

                let currentVMID = try currentVM.requireID()
                let bootVolumes = try await Volume.query(on: tx)
                    .filter(\.$vm.$id == currentVMID)
                    .filter(\.$volumeType == .boot)
                    .filter(\.$desiredStatus == .present)
                    .with(\.$pool)
                    .all()
                guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
                    throw Abort(
                        .internalServerError,
                        reason: "VM \(vmId) must have exactly one managed boot volume before placement")
                }
                guard let bootPool = bootVolume.pool else {
                    throw Abort(.internalServerError, reason: "VM \(vmId)'s boot volume has no storage pool")
                }

                // A network pinned to a site exists only in that site's OVN
                // deployment, so it pins the VM's placement (issue #343).
                let requiredSiteID = try await pinnedSiteID(for: currentVM, on: tx)
                if bootPool.mode == .ceph, let requiredSiteID,
                    requiredSiteID != bootPool.$site.id
                {
                    throw Abort(
                        .conflict,
                        reason:
                            "VM \(vmId)'s network and Ceph boot pool belong to different sites")
                }

                let storageEligibleAgents: [SchedulableAgent]
                switch bootPool.mode {
                case .local:
                    // Historical local behavior: an empty membership list
                    // means every otherwise-schedulable agent.
                    let poolMembers = bootPool.memberAgentIds
                    storageEligibleAgents = schedulableAgents.filter { agent in
                        poolMembers.isEmpty || poolMembers.contains(agent.id)
                    }
                case .ceph:
                    let schedulableIDs = schedulableAgents.compactMap { UUID(uuidString: $0.id) }
                    let clientRows =
                        schedulableIDs.isEmpty
                        ? []
                        : try await Agent.query(on: tx)
                            .filter(\.$id ~~ schedulableIDs)
                            .all()
                    let reachableIDs = Set(
                        clientRows.compactMap { agent -> String? in
                            StoragePool.agentCanReach(
                                agent: agent, pool: bootPool, replicaAgentIds: [])
                                ? agent.id?.uuidString : nil
                        })
                    storageEligibleAgents = schedulableAgents.filter { reachableIDs.contains($0.id) }
                case .replicated:
                    throw Abort(.conflict, reason: "Replicated boot pools are not executable")
                }

                // Use the freshly locked row for every placement requirement,
                // including the v39 metadata opt-out gate. The reservation is
                // still atomic in the coordination store (issue #258).
                let selectedAgentId: String
                do {
                    selectedAgentId = try await app.scheduler.selectAndReserveAgent(
                        requirements: SchedulerService.placementRequirements(
                            for: currentVM, architecture: imageArchitecture, siteID: requiredSiteID,
                            // RBD bytes do not consume agent-local disk. CPU and
                            // memory remain reserved, while Ceph placement is
                            // completely described by pool reachability.
                            diskBytes: bootPool.mode == .ceph ? 0 : nil),
                        vmId: vmId,
                        from: storageEligibleAgents,
                        coordination: app.coordination,
                        strategy: strategy,
                        vmName: currentVM.name
                    )
                } catch let error as SchedulerError {
                    app.logger.error("Scheduler failed to find suitable agent: \(error)")
                    // Preserve the scheduler's reason (unsupported hypervisor,
                    // arch mismatch, insufficient resources, ...) instead of
                    // collapsing every placement failure into a generic one.
                    throw AgentServiceError.schedulingFailed(error.description)
                }
                reservedAgentId.withLockedValue { $0 = selectedAgentId }

                try await self.requireNetworkAuthority(
                    forAgentId: selectedAgentId, workloadId: vmId,
                    consequence: "the VM's network would never be realized and it would never boot", on: tx)

                // Persist only from the current row. From here the VM is part
                // of the agent's desired state and every sync path carries it.
                currentVM.hypervisorId = selectedAgentId
                try await currentVM.save(on: tx)

                let bootVolumeID = try bootVolume.requireID()
                let existingReplicas = try await VolumeReplica.query(on: tx)
                    .filter(\.$volume.$id == bootVolumeID)
                    .all()
                guard existingReplicas.isEmpty else {
                    throw Abort(
                        .conflict,
                        reason: "Boot volume \(bootVolumeID) was already placed before VM \(vmId)")
                }
                bootVolume.attachedAgentId = selectedAgentId
                switch bootPool.mode {
                case .local:
                    try await bootVolume.save(on: tx)
                    try await VolumeReplica(
                        volumeID: bootVolumeID,
                        agentId: selectedAgentId,
                        state: .provisioning,
                        generation: bootVolume.generation
                    ).save(on: tx)
                case .ceph:
                    bootVolume.reconcilerAgentId = selectedAgentId
                    try await bootVolume.save(on: tx)
                case .replicated:
                    throw Abort(.conflict, reason: "Replicated boot pools are not executable")
                }
                return selectedAgentId
            }
        } catch {
            // The placement never became desired state, so nothing will ever
            // account for the reservation — release it rather than pinning
            // capacity until the TTL.
            if let reservedAgentId = reservedAgentId.withLockedValue({ $0 }) {
                await app.coordination.releaseReservation(agentId: reservedAgentId, vmId: vmId)
            }
            throw error
        }

        // Keep the caller's instance coherent for call sites that inspect it
        // after this method; persistence above deliberately used the reload.
        vm.hypervisorId = agentId

        app.logger.info(
            "VM creation dispatched via desired-state doorbell",
            metadata: [
                "strato.vm.id": .string(vmId),
                "strato.agent.id": .string(agentId),
            ])

        await app.agentService.syncDesiredState(agentId: agentId)
    }

    /// Places a sandbox on a compatible Firecracker agent. Networked sandboxes
    /// additionally require overlay support, sandbox networking, and the NIC's site.
    func createSandbox(sandbox: Sandbox, db: Database) async throws {
        var schedulableAgents = await schedulableAgentsFromDatabase()
        let sandboxId = sandbox.id?.uuidString ?? ""

        // The NIC rows are written in the create transaction, before placement
        // runs, so they are authoritative here — the same guarantee the VM
        // path's `pinnedSiteID` relies on.
        let nic = try await sandbox.$networkInterfaces.get(on: db)
        let sandboxSiteID = try await pinnedSiteID(forNetworkIDs: nic.map(\.logicalNetworkID), on: db)

        var requiredArchitecture: CPUArchitecture?
        if let snapshotID = sandbox.restoredFromSnapshotId {
            guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: db),
                snapshot.isReady
            else {
                throw AgentServiceError.schedulingFailed(
                    "the restore snapshot is unavailable or not ready")
            }
            guard
                snapshot.guestControlProtocolVersion
                    == SandboxGuestControlProtocol.currentVersion
            else {
                throw AgentServiceError.schedulingFailed(
                    "snapshot uses unsupported guest control protocol "
                        + "\(snapshot.guestControlProtocolVersion.map(String.init) ?? "missing"); "
                        + "version \(SandboxGuestControlProtocol.currentVersion) is required, so delete "
                        + "and recapture it after upgrading the sandbox guest image"
                )
            }

            // Candidates (issue #428): the snapshot's own agent restores from
            // local artifacts; once exported, any agent that satisfies the
            // recorded architecture, Firecracker, and CPU compatibility
            // constraints can stage the archive from object storage instead.
            //
            // A *networked* fork adds one more, and it applies to the pinned
            // agent too (STR-104): remapping the checkpointed network device
            // needs Firecracker 1.12+, which the capture path does not, so a
            // snapshot's own host can be unable to fork it. Filtering here is
            // what turns that into a scheduling failure naming the version
            // rather than a placement onto a host that refuses permanently.
            let forkNeedsNetworkRemap = !nic.isEmpty
            var candidates: [SchedulableAgent] = []
            var networkRemapBlocker: String?
            if let pinnedAgentID = snapshot.agentId,
                let pinned = schedulableAgents.first(where: { $0.id == pinnedAgentID })
            {
                var pinnedBlocker: String?
                if forkNeedsNetworkRemap, let pinnedUUID = UUID(uuidString: pinnedAgentID),
                    let pinnedRow = try await Agent.find(pinnedUUID, on: db)
                {
                    pinnedBlocker = SandboxSnapshotCompatibility.networkedForkBlocker(target: pinnedRow)
                }
                if let pinnedBlocker {
                    networkRemapBlocker = pinnedBlocker
                } else {
                    candidates.append(pinned)
                }
            }
            if snapshot.isExported {
                let otherIDs =
                    schedulableAgents
                    .filter { $0.id != snapshot.agentId }
                    .compactMap { UUID(uuidString: $0.id) }
                if !otherIDs.isEmpty {
                    // The compatibility inputs (probed Firecracker version,
                    // host CPU model) live on the agent rows, not in
                    // SchedulableAgent — fetch them for the survivors only.
                    let rows = try await Agent.query(on: db).filter(\.$id ~~ otherIDs).all()
                    let compatibleIDs = Set(
                        rows.filter {
                            SandboxSnapshotCompatibility.restoreBlocker(snapshot: snapshot, target: $0) == nil
                                && (!forkNeedsNetworkRemap
                                    || SandboxSnapshotCompatibility.networkedForkBlocker(target: $0) == nil)
                        }.compactMap { $0.id?.uuidString })
                    candidates += schedulableAgents.filter { compatibleIDs.contains($0.id) }
                }
            }
            guard !candidates.isEmpty else {
                if let networkRemapBlocker, !snapshot.isExported {
                    throw AgentServiceError.schedulingFailed(networkRemapBlocker)
                }
                if snapshot.isExported {
                    throw AgentServiceError.schedulingFailed(
                        "no schedulable agent is compatible with the restore snapshot (need Firecracker \(SandboxSnapshotCompatibility.normalizedFirecrackerVersion(snapshot.firecrackerVersion) ?? "unknown") on \(snapshot.architecture ?? "unknown")\(forkNeedsNetworkRemap ? " — at least \(FirecrackerSnapshotFeatures.networkOverridesMinimumVersion) to remap the NIC" : ""), and a matching CPU template or identical CPU)"
                    )
                }
                throw AgentServiceError.schedulingFailed(
                    "snapshot artifacts are pinned to agent \(snapshot.agentId ?? "unknown"), which is not schedulable; export the snapshot to allow cross-agent placement"
                )
            }
            schedulableAgents = candidates
            if let rawArchitecture = snapshot.architecture {
                guard let architecture = CPUArchitecture(rawValue: rawArchitecture) else {
                    throw AgentServiceError.schedulingFailed(
                        "restore snapshot records unsupported architecture '\(rawArchitecture)'")
                }
                requiredArchitecture = architecture
            }
        }

        let agentId: String
        do {
            agentId = try await app.scheduler.selectAndReserveAgent(
                requirements: VMPlacementRequirements(
                    cpu: sandbox.cpus,
                    memory: sandbox.memory,
                    disk: 0,
                    hypervisorType: .firecracker,
                    architecture: requiredArchitecture,
                    // Unlike a VM's plain NIC, which user-mode/SLIRP satisfies
                    // with outbound NAT, a sandbox NIC has no user-mode form at
                    // all — so unlike the VM path, presence really does imply
                    // the overlay requirement.
                    requiresInterVMNetworking: !nic.isEmpty,
                    siteID: sandboxSiteID,
                    requiresSandboxRuntime: true,
                    requiresSandboxNetworking: !nic.isEmpty
                ),
                vmId: sandboxId,
                from: schedulableAgents,
                coordination: app.coordination,
                vmName: sandbox.name
            )
        } catch let error as SchedulerError {
            app.logger.error("Scheduler failed to find suitable agent for sandbox: \(error)")
            throw AgentServiceError.schedulingFailed(error.description)
        }

        do {
            let placed = try await db.transaction { tx -> Bool in
                guard try await sandbox.lockAndRefresh(on: tx) else { return false }
                // A delete may commit while the create scheduler is choosing a
                // host. Absence is the one intent placement must never revive.
                guard sandbox.desiredStatus != .absent else { return false }
                try await self.requireNetworkAuthority(
                    forAgentId: agentId, workloadId: sandboxId,
                    consequence:
                        "the sandbox's network would never be realized and it would never start",
                    on: tx)

                // Persist only after refreshing under the row lock, so this
                // background placement cannot save its pre-scheduling snapshot
                // over a concurrent lifecycle mutation.
                sandbox.hypervisorId = agentId
                try await sandbox.save(on: tx)
                return true
            }
            guard placed else {
                await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxId)
                return
            }

            app.logger.info(
                "Sandbox creation dispatched via desired-state doorbell",
                metadata: [
                    "strato.sandbox.id": .string(sandboxId),
                    "strato.agent.id": .string(agentId),
                ])

            await app.agentService.syncDesiredState(agentId: agentId)
        } catch {
            // The placement never became desired state, so nothing will ever
            // account for the reservation — release it rather than pinning
            // capacity until the TTL.
            await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxId)
            throw error
        }
    }

    /// Refuses overlay placement when the selected site's controller cannot author topology.
    private func requireNetworkAuthority(
        forAgentId agentId: String, workloadId: String, consequence: String, on db: Database
    ) async throws {
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db),
            agent.supportsInterVMNetworking
        else { return }
        let authority = try await SiteNetworkAuthority.resolve(
            forAgent: agent,
            offlineGrace: app.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: db)
        guard
            let reason = SiteNetworkAuthority.refusalReason(
                authority, host: agent, consequence: consequence)
        else { return }
        await app.coordination.releaseReservation(agentId: agentId, vmId: workloadId)
        throw AgentServiceError.schedulingFailed(reason)
    }

    /// Returns the site required by the VM's attached networks.
    private func pinnedSiteID(for vm: VM, on db: Database) async throws -> UUID? {
        guard let vmID = vm.id else { return nil }
        let nics = try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all()
        return try await pinnedSiteID(forNetworkIDs: nics.map(\.logicalNetworkID), on: db)
    }

    /// Rejects workloads whose networks belong to different sites.
    private func pinnedSiteID(forNetworkIDs ids: [UUID], on db: Database) async throws -> UUID? {
        let networkIDs = Set(ids)
        guard !networkIDs.isEmpty else { return nil }

        let networks = try await LogicalNetwork.query(on: db)
            .filter(\.$id ~~ Array(networkIDs))
            .all()
        let siteIDs = Set(networks.compactMap { $0.$site.id })
        guard siteIDs.count <= 1 else {
            throw AgentServiceError.schedulingFailed(
                "workload attaches networks pinned to different sites; no host can satisfy both")
        }
        return siteIDs.first
    }

    // MARK: - Agent Selection

    /// The scheduler's view of the fleet, assembled from the shared registry:
    /// agent rows (resources refreshed by heartbeats through any replica) and
    /// per-agent VM counts, filtered to agents whose presence key is live.
    func schedulableAgentsFromDatabase() async -> [SchedulableAgent] {
        do {
            async let onlineAgents = Agent.query(on: app.db)
                .filter(\.$status == .online)
                .all()
            async let groupedCounts = runningVMCountsFromDatabase()
            let (agents, runningVMCounts) = try await (onlineAgents, groupedCounts)

            // Fail open on nil (store unavailable): the rows said online, and
            // refusing all placement would couple VM creation to Valkey harder
            // than issue #258's degradation policy allows.
            let presence = await app.coordination.agentPresence(
                agentKeys: agents.map(\.identity.key))
            let present =
                presence.map { states in
                    zip(agents, states).compactMap { agent, isPresent in
                        isPresent ? agent : nil
                    }
                } ?? agents

            return present.compactMap { agent in
                guard let agentId = agent.id?.uuidString else { return nil }
                return SchedulableAgent(
                    id: agentId,
                    name: agent.name,
                    totalCPU: agent.totalCPU,
                    availableCPU: agent.availableCPU,
                    totalMemory: agent.totalMemory,
                    availableMemory: agent.availableMemory,
                    totalDisk: agent.totalDisk,
                    availableDisk: agent.availableDisk,
                    status: agent.status,
                    runningVMCount: runningVMCounts[agentId] ?? 0,
                    supportedHypervisors: agent.supportedHypervisors,
                    architecture: agent.cpuArchitecture,
                    supportsInterVMNetworking: agent.supportsInterVMNetworking,
                    supportsMetadataService: agent.metadataServiceCapable,
                    siteID: agent.$site.id,
                    supportsSandboxWorkloads: agent.sandboxCapable,
                    supportsSandboxNetworking: agent.effectiveSandboxNetworkingCapable,
                    supportsVTPM: agent.tpmCapable,
                    supportsVsock: agent.supportsVsock
                )
            }
        } catch {
            app.logger.error("Failed to load schedulable agents from database: \(error)")
            return []
        }
    }

    /// Count placed VMs per agent without hydrating every VM in the cluster.
    private func runningVMCountsFromDatabase() async throws -> [String: Int] {
        guard let sql = app.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Scheduler placement requires an SQL database")
        }

        struct Row: Decodable {
            let hypervisor_id: String
            let count: Int
        }

        let rows = try await sql.raw(
            """
            SELECT hypervisor_id, COUNT(*) AS count
            FROM vms
            WHERE hypervisor_id IS NOT NULL
            GROUP BY hypervisor_id
            """
        ).all(decoding: Row.self)

        return Dictionary(uniqueKeysWithValues: rows.map { ($0.hypervisor_id, $0.count) })
    }

}
