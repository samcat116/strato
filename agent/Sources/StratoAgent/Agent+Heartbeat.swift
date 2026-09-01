import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import StratoShared
import StratoAgentCore
import StratoAgentSPIFFE

#if os(Linux)
// One shared Firecracker client backs both VMs and sandboxes (issue #421).
import SwiftFirecracker
// geteuid(): the jailer needs root, so the start-time jailer resolution
// (issue #425) checks the effective uid.
import Glibc
#endif

/// Owns control-plane reconnection, heartbeat assembly, and resource observation.
extension Agent {
    // MARK: - Reconnection

    func handleConnectionLost() async {
        guard !shutdownRequested else { return }

        interactiveSessionFence.quiesce()
        if let continuation = takeRegistrationContinuation() {
            continuation.resume(
                throwing: AgentError.registrationFailed(
                    "control-plane connection closed during registration"))
        }

        guard isRunning else {
            reconnectState.recordStartupConnectionLoss()
            return
        }

        let disposition = reconnectState.recordConnectionLoss()
        switch disposition {
        case .startLoop:
            logger.warning("Lost connection to control plane; beginning reconnection with backoff")
        case .loopAlreadyActive:
            logger.warning(
                "Control-plane connection dropped during reconnect recovery; the active loop will retry")
        }

        await quiesceConnectionScopedState()
        guard disposition == .startLoop else { return }
        guard isRunning else {
            reconnectState.finishLoop()
            return
        }
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func quiesceConnectionScopedState() async {
        interactiveSessionFence.quiesce()
        await consoleSocketManager?.disconnectAll()
        await sandboxRuntime?.controlPlaneDisconnected()
        await vmExecSessionManager.closeInteractive(reason: "control plane disconnected")
        guestExecSessions = guestExecSessions.filter { $0.value.sessionKind == .recorded }
    }

    func restoreConnectionScopedState(
        generation: ControlPlaneWebSocketState.Generation,
        attempt: ControlPlaneReconnectState.Attempt?
    ) async -> Bool {
        guard await connectionRecoveryIsCurrent(generation: generation, attempt: attempt) else {
            await quiesceConnectionScopedState()
            return false
        }
        await sandboxRuntime?.controlPlaneConnected()
        guard await connectionRecoveryIsCurrent(generation: generation, attempt: attempt) else {
            await quiesceConnectionScopedState()
            return false
        }
        await vmExecSessionManager.resumeInteractive()
        guard await connectionRecoveryIsCurrent(generation: generation, attempt: attempt) else {
            await quiesceConnectionScopedState()
            return false
        }
        interactiveSessionFence.activate(generation: generation)
        return true
    }

    func connectionRecoveryIsCurrent(
        generation: ControlPlaneWebSocketState.Generation,
        attempt: ControlPlaneReconnectState.Attempt?
    ) async -> Bool {
        guard !shutdownRequested,
            await websocketClient?.isCurrentConnection(generation) == true
        else { return false }
        if let attempt {
            return isRunning && reconnectState.canFinish(attempt)
        }
        return !reconnectState.connectionWasLostDuringStartup
    }

    func runReconnectLoop() async {
        defer {
            reconnectState.finishLoop()
            reconnectTask = nil
        }

        var delaySeconds = 1.0
        let maxDelaySeconds = 30.0
        while isRunning {
            let jitter = Double.random(in: 0...(delaySeconds * 0.3))
            do {
                try await Task.sleep(for: .seconds(delaySeconds + jitter))
            } catch {
                return
            }
            guard isRunning else { return }

            let attempt = reconnectState.beginAttempt()
            do {
                guard let websocketClient else {
                    throw WebSocketClientError.notConnected
                }
                let generation = try await websocketClient.connect()
                try await registerWithControlPlane()
                guard
                    await restoreConnectionScopedState(
                        generation: generation, attempt: attempt)
                else {
                    logger.warning(
                        "Control-plane connection dropped before reconnect recovery completed; retrying")
                    continue
                }
                logger.info("Successfully reconnected and re-registered with control plane")
                return
            } catch AgentError.registrationRejected(let reason) {
                logger.error("Registration rejected by control plane: \(reason)")
                logger.error(
                    "Verify the SPIRE registration entry for this agent's SPIFFE ID, and that the control plane trusts the same trust domain."
                )
                await websocketClient?.disconnect()
                terminalError = AgentError.registrationRejected(reason)
                signalShutdown()
                return
            } catch {
                logger.error("Reconnection attempt failed, will retry: \(error)")
                await websocketClient?.disconnect()
                delaySeconds = min(delaySeconds * 2, maxDelaySeconds)
            }
        }
    }

    func sendHeartbeat() async {
        do {
            try await _sendHeartbeat()
        } catch {
            logger.error("Failed to send heartbeat: \(error)")
        }
    }

    func _sendHeartbeat() async throws {
        // Only send heartbeat if we have an assigned ID from registration
        guard assignedAgentID != nil else {
            logger.debug("Skipping heartbeat - not yet registered")
            return
        }

        // Retry a manifest that could not be *read*, so a host quarantined by a
        // transient cause recovers on its own (STR-138).
        await retryManifestLoadIfQuarantined()

        // Retry a failed manifest write so a transient disk error can't leave the
        // on-disk manifest permanently behind the in-memory VM records.
        if manifestPersistFailed {
            persistManifest()
            if !manifestPersistFailed {
                logger.info("VM manifest write recovered on heartbeat retry")
            }
        }

        let resources = await getAgentResources()
        let dependencyObservations = await dependencyManager?.observations() ?? []

        let message = AgentHeartbeatMessage(
            agentId: effectiveAgentID,
            resources: resources,
            dependencyObservations: dependencyObservations
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        await sendNextRecordedExecTerminalState()
        // The beat is already on the wire before this bounded host probe runs,
        // so a slow lsblk cannot make the control plane mark the agent offline.
        _ = await storageDeviceInventory.refreshForHeartbeat()

        // Refresh the guest-agent view on the slow-poll cadence before the
        // report reads it (issue #563). Throttled and bounded, so most
        // heartbeats skip it and a slow probe can never stall the beat.
        if assignedAgentID != nil {
            await refreshGuestInfoCacheIfDue()
        }

        // On the same cadence, re-assert full observed state. The heartbeat
        // keeps liveness/presence; the report is the periodic correctness
        // backstop for VM state (issue #260). Skipped before the first
        // registration completes — there is no agent id to report under.
        if assignedAgentID != nil {
            // Bounded as a whole: the report walks every VM, and it runs on the
            // heartbeat's own task, so an overlong report delays the *next*
            // beat. Skipping one is harmless — it is a periodic backstop and
            // the next round re-drives it (issue #516).
            //
            // `.abandon` despite the report having an effect (it transmits):
            // `sendObservedStateReport` stamps an epoch and re-checks it
            // immediately before sending, so an abandoned report finds itself
            // superseded and drops instead of applying a stale full-list view
            // over a newer one. Remove that guard and this must become
            // `.cancelAndWait`.
            do {
                try await StageBudget.run(
                    seconds: 15, stage: "observed-state-report", onTimeout: .abandon
                ) { [self] in
                    await sendObservedStateReport()
                }
            } catch {
                logger.warning("Observed-state report exceeded its budget; skipping this round")
            }
        }
    }

    /// Refreshes the guest-info and balloon memory-stats caches for running
    /// VMs, but only once the slow-poll interval has elapsed. Probes run
    /// concurrently (each bounded inside its driver), and the whole pass is
    /// bounded here so a fleet of unresponsive guests can't stall the
    /// heartbeat. The caches are replaced wholesale, so VMs that stopped
    /// running or were deleted drop out.
    ///
    /// Routed through the driver registry rather than a downcast to a concrete
    /// service: the guest-agent channel belongs to the guest, not to whoever
    /// launched it, so which backend a VM runs under is not this loop's
    /// business — only whether it has a guest channel at all, which
    /// `observesGuests` answers without a round trip.
    func refreshGuestInfoCacheIfDue() async {
        let now = ContinuousClock.now
        if let last = lastGuestInfoRefresh, now - last < Self.guestInfoRefreshInterval {
            return
        }
        lastGuestInfoRefresh = now

        var byService: [HypervisorType: [String]] = [:]
        for (vmId, entry) in managedVMs
        where hypervisorServices[entry.hypervisorType]?.observesGuests == true {
            byService[entry.hypervisorType, default: []].append(vmId)
        }
        guard !byService.isEmpty else {
            guestInfoCache = [:]
            memoryStatsCache = [:]
            return
        }
        let work = byService.compactMap { type, vmIds in
            hypervisorServices[type].map { (service: $0, vmIds: vmIds) }
        }

        do {
            let observations = try await StageBudget.run(
                seconds: 15, stage: "guest-info-refresh", onTimeout: .abandon
            ) {
                var guestInfo: [String: GuestInfo] = [:]
                var memoryStats: [String: VMMemoryStats] = [:]
                for (service, vmIds) in work {
                    let observed = await Self.probeGuestObservations(vmIds: vmIds, using: service)
                    guestInfo.merge(observed.guestInfo) { _, new in new }
                    memoryStats.merge(observed.memoryStats) { _, new in new }
                }
                return (guestInfo: guestInfo, memoryStats: memoryStats)
            }
            guestInfoCache = observations.guestInfo
            memoryStatsCache = observations.memoryStats
        } catch {
            // A whole-pass timeout leaves the previous caches in place; the
            // next slow poll retries. Individual probes already degrade to nil.
            logger.debug("Guest-info refresh exceeded its budget; keeping the previous cache")
        }
    }

    /// Concurrently probes each VM's guest agent and balloon device (each
    /// probe bounded inside its driver), returning only the VMs that
    /// answered. A VM must be observed running before we probe — a guest agent
    /// on a stopped VM just times out, and a stopped VM has no balloon.
    static func probeGuestObservations(
        vmIds: [String], using service: any HypervisorService
    ) async -> (guestInfo: [String: GuestInfo], memoryStats: [String: VMMemoryStats]) {
        await withTaskGroup(of: (String, GuestInfo?, VMMemoryStats?).self) { group in
            for vmId in vmIds {
                group.addTask {
                    let status = (try? await service.getVMStatus(vmId: vmId)) ?? .unknown
                    guard status == .running else { return (vmId, nil, nil) }
                    return (vmId, await service.guestInfo(vmId: vmId), await service.memoryStats(vmId: vmId))
                }
            }
            var guestInfo: [String: GuestInfo] = [:]
            var memoryStats: [String: VMMemoryStats] = [:]
            for await (vmId, info, stats) in group {
                if let info { guestInfo[vmId] = info }
                if let stats { memoryStats[vmId] = stats }
            }
            return (guestInfo, memoryStats)
        }
    }

    /// Raw CPU/memory accounting, before availability is clamped. Admission
    /// needs to distinguish exact fit from a host that is already overcommitted.
    func rawHostCapacitySnapshot() async -> HostCapacitySnapshot {
        while true {
            let ledgerRevision = capacityAdmissionLedger.revision
            let manifestRevision = capacityManifestRevision
            let snapshot = await assembleRawHostCapacitySnapshot()
            guard ledgerRevision == capacityAdmissionLedger.revision,
                manifestRevision == capacityManifestRevision
            else {
                // Agent actors are reentrant at the backend awaits below. A
                // create can commit its manifest and retire its claim while a
                // different backend is still being queried; retry so the
                // finished workload appears in either durable inventory or an
                // active provisional claim, never in neither.
                continue
            }
            return snapshot
        }
    }

    func assembleRawHostCapacitySnapshot() async -> HostCapacitySnapshot {
        // Host capacity. In simulation mode this is the configured fake capacity
        // — many dummies share one physical machine, so a spawner varies these
        // to give the scheduler a realistic spread of host sizes. Otherwise it
        // is probed live from the machine the agent runs on.
        let totalCPU: Int
        let totalMemory: Int64
        if let simulation, simulation.enabled {
            totalCPU = simulation.resolvedCPUCores
            totalMemory = simulation.resolvedMemoryBytes
        } else {
            totalCPU = HostResources.logicalCoreCount
            totalMemory = HostResources.physicalMemoryBytes
        }

        // Resources committed to VMs currently managed on this host. We report
        // available = total - reserved (1:1, no overcommit) so the scheduler treats
        // CPU/memory as hard constraints; overcommit ratios can be layered on later.
        var reserved = HostReservation()
        var backendsWithInventory: Set<HypervisorType> = []

        for (type, service) in hypervisorServices {
            // Falls back to the manifest, never to nothing: under-reporting
            // reservations advertises capacity this host does not have and
            // invites the scheduler to over-place. Since STR-196 that covers
            // the case this was always written for — a backend that *answers*
            // without knowing, not merely one that runs out of time. A driver
            // returning a synthesized zero was indistinguishable from an idle
            // host, which is how STR-190 stayed invisible in the field.
            let observed = await observe(type, "reservation-inventory") {
                await service.reservationInventory()
            }
            var durableReservations = orphanedVMs.reduce(into: [String: HostReservation]()) {
                reservations, orphan in
                guard orphan.value.hypervisorType == type else { return }
                reservations[orphan.key] = VMHostReservation.forManifestEntry(
                    orphan.value, architecture: .current)
            }
            if let observed {
                // A daemon inventory with membership can also prove that a
                // managed manifest entry disappeared out of band. Retain that
                // entry's reservation for the same reason as a missing orphan:
                // re-create diffs from its old spec and claims growth only.
                if observed.workloadIDs != nil {
                    for (vmId, entry) in managedVMs where entry.hypervisorType == type {
                        durableReservations[vmId] = VMHostReservation.forManifestEntry(
                            entry, architecture: .current)
                    }
                }
                reserved = reserved.addingSaturating(
                    observed.includingMissingWorkloads(durableReservations))
            } else {
                let managed = manifestReservations(for: type)
                reserved = reserved.addingSaturating(
                    HostReservation(cpus: managed.vcpus, memoryBytes: managed.memoryBytes))
                for orphan in durableReservations.values {
                    reserved = reserved.addingSaturating(orphan)
                }
            }
            backendsWithInventory.insert(type)
        }

        // Preserve orphan reservations even when this build has no service for
        // their backend. They are durable evidence of host consumption, and an
        // unavailable driver is not evidence that the workload disappeared.
        for entry in orphanedVMs.values {
            guard !backendsWithInventory.contains(entry.hypervisorType) else { continue }
            reserved = reserved.addingSaturating(
                VMHostReservation.forManifestEntry(entry, architecture: .current))
        }

        // Sandbox reservations always come from the manifest (managed and
        // orphaned alike): the sandbox runtime seam has no reservation query,
        // and the manifest entry is authoritative for the workload's sizing.
        for entry in managedSandboxes.values {
            reserved = reserved.addingSaturating(
                HostReservation(cpus: entry.spec.cpus, memoryBytes: entry.spec.memoryBytes))
        }
        for entry in orphanedSandboxes.values {
            reserved = reserved.addingSaturating(
                HostReservation(cpus: entry.spec.cpus, memoryBytes: entry.spec.memoryBytes))
        }

        // Workloads whose manifest entry this build cannot route (STR-138) are
        // still running; only the routing was lost, not the sizing. They
        // reserve exactly like an orphan — an entry we can't act on is the
        // last thing whose capacity should be handed to a new placement.
        for entry in quarantinedWorkloads.values {
            reserved = reserved.addingSaturating(
                HostReservation(cpus: entry.cpus, memoryBytes: entry.memoryBytes))
        }

        // An unreadable manifest means this host's contents are unknown, and
        // unknown has to advertise as full rather than empty (STR-138). The
        // alternative is what this replaced: a node running 40 VMs whose
        // manifest failed to decode reported its whole machine as free, and
        // `least_loaded` preferentially filled it — over-committing memory on a
        // host whose guests are all live.
        return HostCapacitySnapshot(
            total: HostReservation(cpus: totalCPU, memoryBytes: totalMemory),
            reserved: reserved, inventoryKnown: manifestReadFailure == nil)
    }

    func getAgentResources() async -> AgentResources {
        let raw = await rawHostCapacitySnapshot()
        // Provisional claims are not durable reservations yet, but advertising
        // them as free would invite placement into an in-flight create/resize.
        let accounted = HostCapacitySnapshot(
            total: raw.total,
            reserved: raw.reserved.addingSaturating(capacityAdmissionLedger.provisionalReservation),
            inventoryKnown: raw.inventoryKnown)
        let available = accounted.available
        let inventoryUnknown = !raw.inventoryKnown

        // Disk. In simulation mode the total is the configured fake capacity
        // (the real filesystem is shared by every dummy and has nothing to do
        // with the sizes we're modeling), and committed disk is subtracted from
        // it manifest-side, mirroring the CPU/memory accounting above: the
        // manifest carries each VM's `diskBytes` from both the vmCreate and
        // reconciliation paths, and orphans keep reserving across restarts
        // (issue #473). Sandboxes reserve no disk, matching the scheduler.
        // Otherwise query the managed-volume filesystem live. Every VM boot
        // disk is a managed volume now, and the scheduler compares this value
        // with `vm.disk`; measuring `vmStoragePath` would make placement wrong
        // whenever the two directories are on different filesystems. A live
        // filesystem probe naturally accounts for existing volumes without
        // tracking reservations.
        let totalDisk: Int64
        let availableDisk: Int64
        if let simulation, simulation.enabled {
            totalDisk = simulation.resolvedDiskBytes
            let reservedDisk =
                managedVMs.values.totalReservedDiskBytes + orphanedVMs.values.totalReservedDiskBytes
                + quarantinedWorkloads.values.reduce(0) { $0 + $1.diskBytes }
            availableDisk = inventoryUnknown ? 0 : max(0, totalDisk - reservedDisk)
        } else {
            let disk = HostResources.diskCapacity(forPath: volumeStoragePath)
            if disk == nil {
                logger.warning(
                    "Unable to determine disk capacity for managed volume storage path",
                    metadata: [
                        "path": .string(volumeStoragePath)
                    ])
            }
            totalDisk = disk?.total ?? 0
            availableDisk = inventoryUnknown ? 0 : (disk?.free ?? 0)
        }

        return AgentResources(
            totalCPU: raw.total.cpus,
            availableCPU: available.cpus,
            totalMemory: raw.total.memoryBytes,
            availableMemory: available.memoryBytes,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }

    /// Reservations for `type` from the durable manifest, which carries every
    /// managed VM's sizing — authoritative, not a guess.
    func manifestReservations(for type: HypervisorType) -> (vcpus: Int, memoryBytes: Int64) {
        let reserved = managedVMs.values.lazy.filter { $0.hypervisorType == type }.reduce(
            HostReservation()
        ) { partial, entry in
            partial.addingSaturating(
                VMHostReservation.forManifestEntry(entry, architecture: .current))
        }
        return (reserved.cpus, reserved.memoryBytes)
    }

    /// Query a hypervisor for reporting purposes under a short budget,
    /// returning nil if it does not answer in time — or answers that it cannot
    /// say.
    ///
    /// These calls exist only to describe the host, but they run on the
    /// hypervisor's actor alongside real work. Before issue #516 the heartbeat
    /// awaited them unbounded, so one stuck hypervisor call stopped every
    /// subsequent heartbeat and the control plane marked a live agent offline.
    /// A stale-but-recent answer is far better than no heartbeat at all.
    ///
    /// Two nils are flattened into one deliberately (STR-196): the budget
    /// overran, or the backend could not find out. The agent's response to both
    /// is the same manifest substitution, and each is already logged by whoever
    /// produced it — so nothing is lost by conflating them, and the caller's
    /// fallback covers a backend that answers *wrongly* rather than only one
    /// that answers *slowly*.
    func observe<T: Sendable>(
        _ type: HypervisorType,
        _ stage: String,
        _ query: @escaping @Sendable () async -> T?
    ) async -> T? {
        do {
            return try await StageBudget.run(
                seconds: StageBudget.observationSeconds, stage: stage, onTimeout: .abandon
            ) {
                await query()
            }
        } catch {
            logger.warning(
                "Hypervisor did not answer an observation query in time; reporting last known state",
                metadata: [
                    "hypervisor": .string(type.rawValue),
                    "stage": .string(stage),
                ])
            return nil
        }
    }
}
