import Foundation
import Fluent
import SQLKit
import StratoAPITypes
import StratoShared
import Vapor

actor WorkloadPlacementService {
    private let app: Application

    init(app: Application) {
        self.app = app
    }

    private struct PlacementInputsChanged: Error {}

    // MARK: - VM Operations

    /// Selects an agent, persists the VM placement, and triggers desired-state sync.
    func createVM(
        vm: VM,
        db: Database,
        strategy: SchedulingStrategy? = nil,
        image: Image? = nil
    ) async throws {
        try await placeVM(vm: vm, db: db, strategy: strategy, image: image, attemptsRemaining: 3)
    }

    private func placeVM(
        vm: VM, db: Database, strategy: SchedulingStrategy?, image: Image?, attemptsRemaining: Int
    ) async throws {
        let schedulableAgents = await schedulableAgentsFromDatabase()
        let vmId = try vm.requireID().uuidString
        let imageArchitecture = image?.architecture
        var reservedAgentId: String?

        // Plan and reserve without holding a database transaction. Revalidate
        // the captured inputs under the VM lock before persisting placement.
        let agentId: String
        do {
            let tx = db
            guard let plannedVM = try await VM.find(vm.id, on: db) else {
                throw Abort(.notFound, reason: "VM no longer exists")
            }
            if let placedAgent = plannedVM.hypervisorId {
                vm.hypervisorId = placedAgent
                return
            }
            if let snapshot = plannedVM.resourceClass {
                plannedVM.resourceClass = try await WorkloadResourceClassService.currentPolicy(snapshot, on: db)
            }
            let currentVM = plannedVM
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
                let instant = try await ClusterClock.read(on: tx)
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
                            agent: agent, pool: bootPool, replicaAgentIds: [], at: instant)
                            ? agent.id?.uuidString : nil
                    })
                storageEligibleAgents = schedulableAgents.filter { reachableIDs.contains($0.id) }
            case .replicated:
                throw Abort(.conflict, reason: "Replicated boot pools are not executable")
            }

            // Reserve from an unlocked snapshot; every requirement is checked
            // again under the row lock before this becomes desired state.
            let plannedRequirements = SchedulerService.placementRequirements(
                for: currentVM, architecture: imageArchitecture, siteID: requiredSiteID,
                diskBytes: bootPool.mode == .ceph ? 0 : nil)
            let selectedAgentId: String
            do {
                selectedAgentId = try await app.scheduler.selectAndReserveAgent(
                    requirements: plannedRequirements,
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
            reservedAgentId = selectedAgentId

            let plannedGeneration = plannedVM.generation
            let plannedVolumeGeneration = bootVolume.generation
            let plannedPoolMode = bootPool.mode
            let plannedPoolMembers = bootPool.memberAgentIds
            let plannedPoolSite = bootPool.$site.id
            agentId = try await db.transaction { [self] tx in
                guard try await vm.lockAndRefresh(on: tx),
                    let currentVM = try await VM.find(vm.id, on: tx),
                    let currentBootVolume = try await Volume.find(bootVolume.id, on: tx),
                    let currentBootPool = try await currentBootVolume.$pool.get(on: tx)
                else { throw Abort(.notFound, reason: "VM placement inputs no longer exist") }
                guard currentVM.desiredStatus != .absent else {
                    throw Abort(.conflict, reason: "VM was deleted during placement")
                }
                if currentVM.hypervisorId != nil { throw PlacementInputsChanged() }
                if let snapshot = currentVM.resourceClass {
                    currentVM.resourceClass = try await WorkloadResourceClassService.currentPolicy(snapshot, on: tx)
                }
                if currentBootPool.mode == .ceph {
                    guard let selectedUUID = UUID(uuidString: selectedAgentId) else { throw PlacementInputsChanged() }
                    guard let selectedAgent = try await Agent.find(selectedUUID, on: tx),
                        StoragePool.agentCanReach(
                            agent: selectedAgent, pool: currentBootPool, replicaAgentIds: [],
                            at: try await ClusterClock.read(on: tx))
                    else { throw PlacementInputsChanged() }
                }
                let currentRequirements = SchedulerService.placementRequirements(
                    for: currentVM, architecture: imageArchitecture, siteID: requiredSiteID,
                    diskBytes: currentBootPool.mode == .ceph ? 0 : nil)
                guard currentRequirements == plannedRequirements,
                    currentVM.$sourceImage.id == plannedVM.$sourceImage.id,
                    currentVM.generation == plannedGeneration,
                    currentBootVolume.generation == plannedVolumeGeneration,
                    currentBootVolume.$vm.id == currentVM.id,
                    currentBootVolume.$pool.id == bootVolume.$pool.id,
                    currentBootVolume.desiredStatus == .present,
                    currentBootVolume.volumeType == .boot,
                    currentBootPool.mode == plannedPoolMode,
                    currentBootPool.memberAgentIds == plannedPoolMembers,
                    currentBootPool.$site.id == plannedPoolSite,
                    try await pinnedSiteID(for: currentVM, on: tx) == requiredSiteID
                else {
                    throw PlacementInputsChanged()
                }
                let bootVolume = currentBootVolume
                try await self.requireNetworkAuthority(
                    forAgentId: selectedAgentId, workloadId: vmId,
                    consequence: "the VM's network would never be realized and it would never boot", on: tx)

                // Persist only from the current row. From here the VM is part
                // of the agent's desired state and every sync path carries it.
                try await WorkloadResourceClassService.requireHostReadiness(
                    currentVM.resourceClass,
                    backend: currentVM.hypervisorType == .qemu ? .qemuVM : nil, agentID: selectedAgentId, on: tx)
                guard let selectedAgent = storageEligibleAgents.first(where: { $0.id == selectedAgentId }) else {
                    throw Abort(.conflict, reason: "Selected agent is no longer an eligible class placement")
                }
                let requirements = SchedulerService.placementRequirements(
                    for: currentVM, architecture: imageArchitecture, siteID: requiredSiteID)
                if let admission = try await WorkloadResourceClassService.placement(
                    currentVM.resourceClass,
                    cpus: currentVM.cpu, memory: requirements.memoryReservation(on: selectedAgent), on: tx)
                {
                    currentVM.resourceClass = admission.snapshot
                    currentVM.admittedReservation = admission.reservation
                }
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
            if let reservedAgentId {
                await app.coordination.releaseReservation(agentId: reservedAgentId, vmId: vmId)
            }
            if error is PlacementInputsChanged, attemptsRemaining > 1 {
                // Retry only optimistic input validation, never a transaction
                // abort or an ambiguous commit; generic DB retries are separate.
                return try await placeVM(
                    vm: vm, db: db, strategy: strategy, image: image, attemptsRemaining: attemptsRemaining - 1)
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

        let placementCandidates = schedulableAgents
        let placementArchitecture = requiredArchitecture
        let reservedAgent = NIOLockedValueBox<String?>(nil)
        let agentId: String?
        do {
            agentId = try await db.transaction { tx -> String? in
                guard try await sandbox.lockAndRefresh(on: tx), sandbox.desiredStatus != .absent else { return nil }
                if let placedAgent = sandbox.hypervisorId { return placedAgent }
                let scheduledClass: WorkloadResourceClassSnapshot?
                if let snapshot = sandbox.resourceClass {
                    scheduledClass = try await WorkloadResourceClassService.currentPolicy(snapshot, on: tx)
                } else {
                    scheduledClass = nil
                }
                let selected = try await self.app.scheduler.selectAndReserveAgent(
                    requirements: VMPlacementRequirements(
                        cpu: sandbox.cpus, memory: sandbox.memory, disk: 0,
                        hypervisorType: .firecracker, architecture: placementArchitecture,
                        requiresInterVMNetworking: !nic.isEmpty, siteID: sandboxSiteID,
                        requiresSandboxRuntime: true, requiresSandboxNetworking: !nic.isEmpty,
                        resourceClass: scheduledClass),
                    vmId: sandboxId, from: placementCandidates, coordination: self.app.coordination,
                    vmName: sandbox.name)
                reservedAgent.withLockedValue { $0 = selected }
                try await self.requireNetworkAuthority(
                    forAgentId: selected, workloadId: sandboxId,
                    consequence: "the sandbox's network would never be realized and it would never start", on: tx)
                try await WorkloadResourceClassService.requireHostReadiness(
                    scheduledClass, backend: .jailedFirecrackerSandbox, agentID: selected, on: tx)
                if let admission = try await WorkloadResourceClassService.placement(
                    scheduledClass,
                    cpus: sandbox.cpus, memory: .sandbox(memoryBytes: sandbox.memory), on: tx)
                {
                    sandbox.resourceClass = admission.snapshot
                    sandbox.admittedReservation = admission.reservation
                }
                sandbox.hypervisorId = selected
                try await sandbox.save(on: tx)
                return selected
            }
        } catch {
            if let selected = reservedAgent.withLockedValue({ $0 }) {
                await app.coordination.releaseReservation(agentId: selected, vmId: sandboxId)
            }
            if let scheduling = error as? SchedulerError {
                throw AgentServiceError.schedulingFailed(scheduling.description)
            }
            throw error
        }
        guard let agentId else { return }
        app.logger.info(
            "Sandbox creation dispatched via desired-state doorbell",
            metadata: [
                "strato.sandbox.id": .string(sandboxId), "strato.agent.id": .string(agentId),
            ])
        await app.agentService.syncDesiredState(agentId: agentId)
    }

    /// Refuses overlay placement when the selected site's controller cannot author topology.
    private func requireNetworkAuthority(
        forAgentId agentId: String, workloadId: String, consequence: String, on db: Database
    ) async throws {
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        else { return }
        let instant = try await ClusterClock.read(on: db)
        guard agent.supportsInterVMNetworking(at: instant) else { return }
        let authority = try await SiteNetworkAuthority.resolve(
            forAgent: agent,
            offlineGrace: app.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: db)
        guard
            let reason = SiteNetworkAuthority.refusalReason(
                authority, host: agent, consequence: consequence)
        else { return }
        // The caller releases after the transaction has rolled back.
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
            async let clusterInstant = ClusterClock.read(on: app.db)
            let (agents, runningVMCounts, instant) = try await (
                onlineAgents, groupedCounts, clusterInstant
            )

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

            let durableRows = try await AgentResourceAdmission.query(on: app.db).all()
            let durable = Dictionary(
                uniqueKeysWithValues: durableRows.compactMap { row in
                    row.id.map { ($0, row.state) }
                })
            return present.compactMap { agent in
                guard let agentId = agent.id?.uuidString else { return nil }
                let state = agent.id.flatMap { durable[$0] } ?? ResourceAdmissionState()
                let capacity = ResourceAdmissionService.capacity(agent: agent, state: state)
                return SchedulableAgent(
                    id: agentId,
                    name: agent.name,
                    totalCPU: agent.totalCPU,
                    availableCPU: Int(capacity.cpuMicroUnits / 1_000_000),
                    totalMemory: agent.totalMemory,
                    availableMemory: capacity.memory,
                    totalDisk: agent.totalDisk,
                    availableDisk: capacity.disk,
                    physicalFreeDisk: agent.physicalFreeDisk,
                    qemuOverheadBytes: agent.memoryAccounting?.qemuOverheadBytes
                        ?? WorkloadMemoryReservation.defaultQEMUOverheadBytes,
                    memoryAccounting: agent.memoryAccounting,
                    status: agent.status,
                    runningVMCount: runningVMCounts[agentId] ?? 0,
                    supportedHypervisors: agent.supportedHypervisors(at: instant),
                    architecture: agent.cpuArchitecture,
                    supportsInterVMNetworking: agent.supportsInterVMNetworking(at: instant),
                    supportsMetadataService: agent.metadataServiceCapable,
                    siteID: agent.$site.id,
                    supportsSandboxWorkloads: agent.sandboxCapable,
                    supportsSandboxNetworking: agent.effectiveSandboxNetworkingCapable(at: instant),
                    supportsVTPM: agent.tpmCapable,
                    supportsVsock: agent.supportsVsock,
                    availableCPUMicroUnits: capacity.cpuMicroUnits
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
