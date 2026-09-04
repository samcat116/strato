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

/// Owns sandbox actuation and observed-state report projection.
extension Agent {
    // MARK: Sandbox actuation (issue #417)

    func requireSandboxRuntime() throws -> any SandboxRuntimeService {
        guard let sandboxRuntime else {
            throw SandboxRuntimeError.runtimeUnavailable
        }
        return sandboxRuntime
    }

    func performSandbox(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .adopt:
            // Adoption flows through adoptSandbox (the reconciler needs the
            // observed status back to plan the remaining steps).
            _ = try await adoptSandbox(item)
        case .create:
            try await sandboxReconcileCreate(item)
        case .boot:
            try await sandboxReconcileBoot(item)
        case .shutdown:
            try await requireSandboxRuntime().shutdownSandbox(sandboxId: item.id)
        case .delete:
            try await sandboxReconcileDelete(item)
        case .restore:
            try await sandboxReconcileRestore(item)
        case .pause, .resume, .resize, .reboot, .attach, .detach, .throttle, .export,
            .reconfigureNetworks:
            // Not in the sandbox step vocabulary (v1); the planner never
            // emits these for sandbox items. `.reboot` in particular is a VM
            // edge only: `POST /api/sandboxes/:id/restart` is expressed as a
            // fresh desired-running generation rather than a nonce, so a
            // sandbox entry carries no `rebootGeneration` to plan from.
            // `.export` acts on a sandbox's *snapshot*, not on the sandbox, and
            // arrives as a snapshot item.
            throw SandboxRuntimeError.unsupportedStep(String(describing: step))
        }
    }

    /// Load a checkpoint back over an existing sandbox (STR-151): tear down the
    /// current microVM, load the checkpointed memory + rootfs, resume. Same
    /// sandbox, same identity, same addresses.
    ///
    /// `artifacts` is present when the sandbox no longer lives on the agent that
    /// captured the snapshot; the runtime stages the exported archive from
    /// object storage before loading it (issue #428). The descriptors are
    /// resolved fresh at sync assembly, so an entry that sat in the desired
    /// state for a while still carries usable locators.
    func sandboxReconcileRestore(_ item: ReconcileWorkItem) async throws {
        guard let restore = item.desiredSandbox?.restore else {
            throw SandboxRuntimeError.unsupportedStep("restore work item without a restore nonce")
        }
        // A restore loads the checkpoint resumed, and a resumed guest starts
        // transmitting immediately — so the whole host-side attachment (netns,
        // veth, TAP, `tc` filters, OVS port) has to be in place before the
        // load, not after (STR-104). Re-realizing is idempotent and cheap, and
        // it is what covers a namespace a crash sweep removed under the
        // sandbox, or an attachment this agent life never learned because the
        // sandbox was adopted rather than created here.
        let networks = item.desiredSandbox?.spec.network.map { [$0] } ?? []
        let jailUID = (managedSandboxes[item.id] ?? orphanedSandboxes[item.id])?.jailUID
        let placement =
            networks.isEmpty
            ? NICPlacement.hostNamespace
            : try sandboxNICPlacement(
                sandboxId: item.id, jailUID: jailUID, existingJail: true)
        let attachments = try await networkOrchestrator.prepareAttachments(
            vmId: item.id, networks: networks, placement: placement)
        try await requireSandboxRuntime().restoreSandbox(
            sandboxId: item.id, snapshotId: restore.snapshotId.uuidString,
            artifacts: restore.artifacts, networkAttachments: attachments)
    }

    /// Where this host realizes a sandbox's NIC (issue STR-100).
    ///
    /// A sandbox NIC lives inside the jail's network namespace, which only
    /// exists when the jailer barrier is on. An unjailed sandbox has no
    /// namespace to attach into and no privilege boundary the attachment is
    /// protecting, so a networked spec is refused rather than quietly realized
    /// in the host namespace — the isolation is the point.
    ///
    /// `forTeardown` derives the placement even on an agent that no longer jails
    /// new sandboxes: the jail layout is built unconditionally precisely so a
    /// previous life's jailed leftovers can still be cleaned up.
    func sandboxNICPlacement(
        sandboxId: String, jailUID: UInt32?, existingJail: Bool = false
    ) throws -> NICPlacement {
        // A simulated agent jails nothing and realizes nothing, but it does
        // advertise sandbox networking so the scheduler treats it as a full
        // host (STR-103). The host namespace is the honest answer for it: the
        // orchestrator is a no-op either way, and refusing here would make the
        // advertised capability a lie the very first time it was used.
        if isSimulationMode { return .hostNamespace }
        guard existingJail || (sandboxJailNewSandboxes && sandboxJailerConfig != nil) else {
            throw SandboxRuntimeError.networkingUnsupported(
                "a sandbox NIC lives in the jail's network namespace, and this agent creates sandboxes "
                    + "unjailed; set sandbox_jailer_mode = \"required\" and satisfy its prerequisites")
        }
        guard let jailUID, jailUID != 0, jailUID != UInt32.max else {
            throw SandboxRuntimeError.jailIdentityUnavailable(
                "sandbox \(sandboxId) has no exclusive manifest-backed uid/gid assignment")
        }
        return .sandboxNetns(
            netnsName: SandboxJailPlan.netnsName(sandboxId: sandboxId),
            owner: JailOwner(uid: jailUID, gid: jailUID))
    }

    /// The placement teardown should use. Never throws, and never degrades to
    /// the host-namespace path: a sandbox NIC that was created jailed must be
    /// removed as one, or `sbx-<id>` stays in OVN NB and the veth stays on
    /// `br-int` while the VM teardown deletes `vm-<id>` and a TAP that never
    /// existed — silently, because teardown swallows errors by design.
    ///
    /// Nothing here needs the jailer config: the namespace name and all three
    /// device names come from the sandbox id, and ownership is create-only. So
    /// cleanup keeps working on an agent whose sandbox runtime was deconfigured
    /// since the sandbox was created, which is exactly the case that used to
    /// leak.
    func sandboxTeardownPlacement(sandboxId: String) -> NICPlacement {
        .sandboxNetns(netnsName: SandboxJailPlan.netnsName(sandboxId: sandboxId), owner: nil)
    }

    func sandboxReconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSandbox else {
            throw HypervisorServiceError.invalidConfiguration("create work item without a desired entry")
        }
        let runtime = try requireSandboxRuntime()

        if let blockedReason = sandboxJailCreationBlockedReason {
            throw SandboxRuntimeError.jailerRequiredUnavailable(blockedReason)
        }

        let currentReservation =
            (managedSandboxes[item.id] ?? orphanedSandboxes[item.id])?.sandboxSpec
            .map(SandboxHostReservation.forSpec) ?? HostReservation()
        let desiredReservation = SandboxHostReservation.forSpec(desired.spec)
        let raw = await rawHostCapacitySnapshot()
        let claim = try capacityAdmissionLedger.claim(
            .positiveDelta(from: currentReservation, to: desiredReservation),
            desiredWorkloadReservation: desiredReservation,
            snapshot: raw, agentName: initialAgentID)
        defer { capacityAdmissionLedger.release(claim) }

        // A jailed Firecracker runtime returns a lease. Direct Firecracker and
        // simulation own no host jail-identity namespace, so both return nil.
        let jailUIDLease = try await runtime.leaseJailUID(for: item.id)

        // Persist the allocation before NIC ownership, chroot staging, or VMM
        // spawn. Without this strict pre-side-effect commit, a crash can leave
        // a live jail whose identity is free for reuse after restart.
        let previousManaged = managedSandboxes[item.id]
        let previousOrphan = orphanedSandboxes[item.id]
        let provisionalEntry = VMManifestEntry(
            sandboxSpec: desired.spec,
            jailUID: jailUIDLease?.uid,
            jailerUsed: runtime.requiresJailUID,
            appliedEdges: (previousManaged ?? previousOrphan)?.appliedEdges)
        managedSandboxes[item.id] = provisionalEntry
        orphanedSandboxes.removeValue(forKey: item.id)
        guard persistManifest() else {
            if let previousManaged {
                managedSandboxes[item.id] = previousManaged
            } else {
                managedSandboxes.removeValue(forKey: item.id)
            }
            if let previousOrphan {
                orphanedSandboxes[item.id] = previousOrphan
            } else {
                orphanedSandboxes.removeValue(forKey: item.id)
            }
            if let jailUIDLease {
                await runtime.rollBackJailUID(jailUIDLease)
            }
            throw SandboxRuntimeError.jailSetupFailed(
                "could not persist uid/gid assignment before creating sandbox \(item.id)")
        }
        if let jailUIDLease {
            await runtime.commitJailUID(jailUIDLease)
        }

        // Resolve the placement after admission but before doing network or
        // runtime work. This is still a pure validation step: a host that
        // cannot realize a sandbox NIC surfaces the permanent reason without
        // leaving any network resources behind, and the deferred claim release
        // covers the refusal.
        let networks = desired.spec.network.map { [$0] } ?? []
        // A network-free sandbox never reaches the placement, so don't refuse an
        // unjailed one over a NIC it doesn't have.
        let placement: NICPlacement
        do {
            placement =
                networks.isEmpty
                ? NICPlacement.hostNamespace
                : try sandboxNICPlacement(sandboxId: item.id, jailUID: jailUIDLease?.uid)
        } catch {
            _ = await rollBackSandboxCreateManifest(
                sandboxId: item.id, provisionalEntry: provisionalEntry,
                previousManaged: previousManaged, previousOrphan: previousOrphan,
                lease: jailUIDLease, runtime: runtime, hostUIDArtifactsMayExist: false)
            throw error
        }

        // Same contract as the VM path: the orchestrator realizes the
        // sandbox's NIC on this host before the runtime runs, and rolls it
        // back if the runtime never created the sandbox.
        let attachments: [ResolvedNetworkAttachment]
        do {
            attachments = try await networkOrchestrator.prepareAttachments(
                vmId: item.id, networks: networks, placement: placement)
        } catch {
            let released = await rollBackSandboxCreateManifest(
                sandboxId: item.id, provisionalEntry: provisionalEntry,
                previousManaged: previousManaged, previousOrphan: previousOrphan,
                lease: jailUIDLease, runtime: runtime, hostUIDArtifactsMayExist: true)
            if released {
                await networkOrchestrator.teardownAttachments(
                    vmId: item.id, networks: networks, placement: placement)
            }
            throw error
        }
        do {
            try await runtime.createSandbox(
                sandboxId: item.id, spec: desired.spec,
                registryCredential: desired.registryCredential, networkAttachments: attachments)
        } catch {
            let released = await rollBackSandboxCreateManifest(
                sandboxId: item.id, provisionalEntry: provisionalEntry,
                previousManaged: previousManaged, previousOrphan: previousOrphan,
                lease: jailUIDLease, runtime: runtime, hostUIDArtifactsMayExist: true)
            if released {
                await networkOrchestrator.teardownAttachments(
                    vmId: item.id, networks: networks, placement: placement)
            }
            throw error
        }
    }

    /// Undo the provisional manifest transition after a create-side effect
    /// fails. A successful cleanup write proves the new uid is no longer
    /// durable and permits lease rollback. If the write itself fails, retain
    /// the provisional entry as an orphan and retain the allocation: a retry
    /// may reclaim it, but no new sandbox can share it after a restart.
    func rollBackSandboxCreateManifest(
        sandboxId: String,
        provisionalEntry: VMManifestEntry,
        previousManaged: VMManifestEntry?,
        previousOrphan: VMManifestEntry?,
        lease: SandboxJailUIDLease?,
        runtime: any SandboxRuntimeService,
        hostUIDArtifactsMayExist: Bool
    ) async -> Bool {
        if hostUIDArtifactsMayExist {
            do {
                try await runtime.prepareJailUIDRelease(
                    for: sandboxId, jailUID: lease?.uid ?? provisionalEntry.jailUID)
            } catch {
                managedSandboxes.removeValue(forKey: sandboxId)
                orphanedSandboxes[sandboxId] = provisionalEntry
                logger.error(
                    "Retaining failed sandbox create and its jail UID because cleanup could not be proven",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
                return false
            }
        }

        if let previousManaged {
            managedSandboxes[sandboxId] = previousManaged
        } else {
            managedSandboxes.removeValue(forKey: sandboxId)
        }
        if let previousOrphan {
            orphanedSandboxes[sandboxId] = previousOrphan
        } else {
            orphanedSandboxes.removeValue(forKey: sandboxId)
        }

        if persistManifest() {
            if let lease {
                await runtime.rollBackJailUID(lease)
            }
            return true
        } else {
            managedSandboxes.removeValue(forKey: sandboxId)
            orphanedSandboxes[sandboxId] = provisionalEntry
            logger.error(
                "Retaining failed sandbox create as an orphan because its provisional jail UID could not be removed from the manifest",
                metadata: ["strato.sandbox.id": .string(sandboxId)])
            return false
        }
    }

    func sandboxReconcileBoot(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSandbox,
            let currentSpec = (managedSandboxes[item.id] ?? orphanedSandboxes[item.id])?.sandboxSpec
        else {
            throw HypervisorServiceError.invalidConfiguration(
                "boot work item without a managed sandbox spec")
        }
        let runtime = try requireSandboxRuntime()

        let raw = await rawHostCapacitySnapshot()
        let growth = HostReservation.positiveDelta(
            from: SandboxHostReservation.forSpec(currentSpec),
            to: SandboxHostReservation.forSpec(desired.spec))
        try capacityAdmissionLedger.validateExistingReservation(
            SandboxHostReservation.forSpec(currentSpec),
            snapshot: raw, agentName: initialAgentID)
        let claim = try capacityAdmissionLedger.claim(
            growth, desiredWorkloadReservation: SandboxHostReservation.forSpec(desired.spec),
            snapshot: raw, agentName: initialAgentID)
        defer { capacityAdmissionLedger.release(claim) }

        try await runtime.bootSandbox(sandboxId: item.id)
    }

    func sandboxReconcileDelete(_ item: ReconcileWorkItem) async throws {
        let runtime = try requireSandboxRuntime()
        guard let entry = managedSandboxes[item.id] ?? orphanedSandboxes[item.id] else {
            // With no durable entry there is no claim this operation is
            // authorized to release. In particular, leave salvaged claims
            // from quarantined future-schema entries untouched.
            return
        }
        let jailUID = entry.jailUID
        if runtime.requiresJailUID, entry.jailerUsed != false, jailUID == nil {
            throw SandboxRuntimeError.jailIdentityUnavailable(
                "sandbox \(item.id) has no persisted jail uid/gid")
        }
        if let jailUID {
            switch await runtime.reserveJailUID(jailUID, for: item.id) {
            case .reserved, .unchanged:
                break
            case .conflict(let holder):
                // Existing legacy collisions must remain poison for allocation,
                // but either claimant still needs an explicit teardown path.
                logger.warning(
                    "Deleting a legacy sandbox whose jail uid/gid is duplicated",
                    metadata: [
                        "strato.sandbox.id": .string(item.id),
                        "uid": .stringConvertible(jailUID),
                        "otherSandboxId": .string(holder),
                    ])
            case .notAssignable:
                throw SandboxRuntimeError.jailIdentityUnavailable(
                    "manifest uid/gid \(jailUID) is not a usable jail identity")
            }
        }

        // This call returns only after the process inventory is empty and all
        // UID-owned artifacts have been removed. Until then the manifest and
        // allocator claims stay intact.
        try await runtime.deleteSandbox(sandboxId: item.id, jailUID: jailUID)

        await networkOrchestrator.teardownAttachments(
            vmId: item.id, networks: entry.sandboxSpec?.network.map { [$0] } ?? [],
            placement: sandboxTeardownPlacement(sandboxId: item.id))

        // Release in memory before removing the durable record. A crash in
        // this narrow interval leaves the old manifest to over-reserve on the
        // next start; the inverse order could make a retained allocator claim
        // disappear across restart.
        try await runtime.releaseJailUID(for: item.id)
        managedSandboxes.removeValue(forKey: item.id)
        orphanedSandboxes.removeValue(forKey: item.id)
        guard persistManifest() else {
            // Restore both halves when the durable removal failed. No other
            // Agent operation can allocate between the awaited release and
            // this synchronous write/re-reservation sequence.
            orphanedSandboxes[item.id] = entry
            if let jailUID {
                _ = await runtime.reserveJailUID(jailUID, for: item.id)
            }
            throw SandboxRuntimeError.jailSetupFailed(
                "sandbox was torn down, but its jail UID claim could not be removed from the manifest")
        }
    }

    /// Assemble and send the full observed state of this host: every managed
    /// VM with its live status, still-orphaned VMs, and VMs mid-convergence
    /// that don't exist on a hypervisor yet. Full-list semantics — a VM absent
    /// from the report does not exist here, which is how the control plane
    /// confirms deletions.
    func sendObservedStateReport() async {
        guard assignedAgentID != nil, let reconciler else { return }

        observedReportEpoch += 1
        let epoch = observedReportEpoch

        var observed: [ObservedVMState] = []
        var reported = Set<String>()

        for (vmId, entry) in managedVMs {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let status: VMStatus
            if let service = hypervisorServices[entry.hypervisorType] {
                status = (try? await service.getVMStatus(vmId: vmId)) ?? .unknown
            } else {
                status = .unknown
            }
            let facts = await reconciler.facts(for: vmId)
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: status,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification,
                    // Last-known guest-agent view (issue #563) and balloon
                    // memory stats (issue #567); nil until the slow poll first
                    // sees a responsive qga / reporting balloon on this VM.
                    guestInfo: guestInfoCache[vmId],
                    memoryStats: memoryStatsCache[vmId],
                    appliedNetworkInterfaceIds: AppliedNetworkInterfaceInventory.ids(
                        in: entry.spec.networks)
                ))
            reported.insert(vmId)
        }

        // Orphans carry no synthesized error: fabricating a `lastError` in the
        // post-registration baseline report (sent while re-adoption is still
        // queued) would fail pending operations on the control plane seconds
        // before the registration sync's adopt converges them. Real adoption
        // failures surface through the reconciler's failure tracking.
        for (vmId, entry) in orphanedVMs where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let facts = await reconciler.facts(for: vmId)
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification,
                    appliedNetworkInterfaceIds: AppliedNetworkInterfaceInventory.ids(
                        in: entry.spec.networks)
                ))
            reported.insert(vmId)
        }

        // Workloads whose manifest entry this build cannot route (STR-138).
        // They must appear here: a VM missing from this list is read as gone,
        // which would either confirm a deletion that never happened or drive
        // a live guest to `.error`. Status is `.unknown` with no synthesized
        // error, exactly like an orphan — the reason the agent can't act on
        // them travels on `manifestStatus` below, once, rather than as a
        // per-VM failure that would fail their pending operations.
        for (vmId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .vm && !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let facts = await reconciler.facts(for: vmId)
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification
                ))
            reported.insert(vmId)
        }

        // VMs still converging toward first existence (mid-create): include
        // them so the control plane sees progress and never mistakes an
        // in-flight create for an absence.
        for (vmId, _) in await reconciler.inFlightWorkloads(kind: .vm) where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let facts = await reconciler.facts(for: vmId)
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase ?? "converging",
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification
                ))
            reported.insert(vmId)
        }

        // VMs whose convergence failed and that have no hypervisor presence
        // (e.g. a create that never produced a process): reported with the
        // error so the control plane can fail the pending operation with the
        // real reason instead of waiting out its budget.
        for (vmId, failure) in await reconciler.failedConvergences(kind: .vm) where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let facts = await reconciler.facts(for: vmId)
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation,
                    failureClassification: failure.classification
                ))
        }

        let report = ObservedStateReport(
            agentId: effectiveAgentID,
            vms: observed,
            sandboxes: await observedSandboxStates(reconciler: reconciler),
            resources: await getAgentResources(),
            agentUpdateStatus: autoUpdateStatus,
            // Workloads this host holds that no sync accounted for (STR-98).
            // They also appear above — the agent is genuinely running them —
            // and stay there until the control plane decides what they are.
            unrecognized: await reconciler.unrecognizedWorkloads(),
            teardownRefusal: await reconciler.lastTeardownRefusal(),
            // What the agent's own memory of this host was able to tell it
            // (STR-138). When the manifest is unreadable this also declares
            // the lists above to be no inventory at all, so the control plane
            // reads no absence from them.
            manifestStatus: manifestStatus(),
            // A list when this agent can account for its volume store — an
            // empty one is the honest "I hold no volumes" the control plane
            // needs to confirm deletions — and nil when it cannot enumerate the
            // store at all, which the control plane reads as "no opinion"
            // rather than as an inventory (STR-148).
            volumes: await observedVolumeStates(reconciler: reconciler),
            // Same list-or-nil contract as `volumes`, one step more expensive
            // to get wrong: an empty list the control plane believed would reap
            // every checkpoint row it holds for this agent, and a checkpoint is
            // a point in time nothing can recreate (STR-150).
            snapshots: await observedSnapshotStates(reconciler: reconciler),
            loadBalancers: await networkService?.observedLoadBalancers(),
            storageDevices: await storageDeviceInventory.snapshot()
        )
        // A newer report started while this one was assembling — which is
        // exactly what happens when this one overran its budget and was
        // abandoned. Sending now would apply stale observations on top of
        // fresher ones and could flip VM status backward.
        guard epoch == observedReportEpoch else {
            logger.debug(
                "Discarding superseded observed-state report",
                metadata: [
                    "epoch": .stringConvertible(epoch),
                    "current": .stringConvertible(observedReportEpoch),
                ])
            return
        }

        do {
            try await websocketClient?.sendMessage(report)
        } catch let error as WebSocketClientError where error.isNotConnected {
            // Not an error: the socket dropped, the reconnect loop owns that,
            // and registration re-sends a baseline report. Logging it at
            // `error` turned a control-plane outage into per-report noise on
            // every agent — worst on the paths a guest can drive.
            logger.debug("Skipped observed-state report: control-plane socket is down")
        } catch {
            logger.error("Failed to send observed-state report: \(error)")
        }
    }

    /// What this agent's durable manifest was able to tell it, for the report
    /// (STR-138). Nil in the steady state — the manifest read cleanly and
    /// every entry in it is routable.
    ///
    /// This is the operator's signal. The failure it describes used to be one
    /// `logger.error` line on a node that had already started accepting new
    /// placements; on the row it becomes something the agents UI shows.
    func manifestStatus() -> ObservedManifestStatus? {
        if let failure = manifestReadFailure {
            var reason = "Workload manifest at \(failure.path) \(failure.reason)."
            reason +=
                " This host's workloads are unknown: it is advertising no capacity and converging nothing"
                + " until the manifest is repaired, or the agent is restarted after removing it."
            if let preserved = failure.preservedCopyPath {
                reason += " A copy of the unreadable file was preserved at \(preserved)."
            }
            return ObservedManifestStatus(
                inventoryComplete: false,
                quarantinedEntries: quarantinedWorkloads.count,
                reason: reason
            )
        }

        guard !quarantinedWorkloads.isEmpty else { return nil }
        let reasons = Set(quarantinedWorkloads.values.map(\.reason)).sorted()
        return ObservedManifestStatus(
            inventoryComplete: true,
            quarantinedEntries: quarantinedWorkloads.count,
            reason:
                "\(quarantinedWorkloads.count) workload(s) in this host's manifest cannot be routed by this agent build "
                + "(\(reasons.joined(separator: "; "))). They keep running and keep reserving capacity, but nothing "
                + "here can start, stop, or delete them — run an agent build that understands them."
        )
    }

    /// Assemble the sandbox half of the observed-state report, mirroring the
    /// VM assembly section by section: managed sandboxes with their live
    /// status, still-orphaned ones, unroutable manifest entries, in-flight
    /// creates, and failed convergences with no runtime presence. Same
    /// full-list semantics — a sandbox absent from the report does not exist
    /// here.
    func observedSandboxStates(reconciler: Reconciler) async -> [ObservedSandboxState] {
        var observed: [ObservedSandboxState] = []
        var reported = Set<String>()

        for sandboxId in managedSandboxes.keys {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            var status: SandboxStatus = .unknown
            var exitCode: Int?
            if let runtime = sandboxRuntime {
                status = (try? await runtime.getSandboxStatus(sandboxId: sandboxId)) ?? .unknown
                if status == .exited {
                    exitCode = await runtime.exitCode(sandboxId: sandboxId)
                }
            }
            let facts = await reconciler.facts(for: sandboxId, kind: .sandbox)
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: status,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification,
                    exitCode: exitCode
                ))
            reported.insert(sandboxId)
        }

        // Orphans carry no synthesized error, for the same reason as VM
        // orphans: real adoption failures surface through the reconciler's
        // failure tracking.
        for sandboxId in orphanedSandboxes.keys where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            let facts = await reconciler.facts(for: sandboxId, kind: .sandbox)
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes whose manifest entry this build cannot route (STR-138),
        // reported for the same reason as their VM counterparts: absence here
        // confirms a deletion, and nothing was deleted.
        for (sandboxId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .sandbox && !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            let facts = await reconciler.facts(for: sandboxId, kind: .sandbox)
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase,
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes still converging toward first existence (mid-create).
        for (sandboxId, _) in await reconciler.inFlightWorkloads(kind: .sandbox)
        where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            let facts = await reconciler.facts(for: sandboxId, kind: .sandbox)
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: facts.phase ?? "converging",
                    lastError: facts.lastError,
                    failedGeneration: facts.failedGeneration,
                    failureClassification: facts.failureClassification
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes whose convergence failed with no runtime presence (e.g. a
        // create that never produced anything), so the control plane can fail
        // the pending operation with the real reason.
        for (sandboxId, failure) in await reconciler.failedConvergences(kind: .sandbox)
        where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            let facts = await reconciler.facts(for: sandboxId, kind: .sandbox)
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: facts.observedGeneration,
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation,
                    failureClassification: failure.classification
                ))
        }

        return observed
    }

    /// Every snapshot artifact this host holds, plus the ones still being
    /// captured or failed with nothing written (STR-150).
    ///
    /// Full-list, like `vms` and `volumes`: the control plane confirms a
    /// deletion by this list *omitting* the artifact, so the in-flight and
    /// failed entries below matter — they are what keeps a slow capture from
    /// reading as "already gone" and reaping a row whose bytes are about to
    /// appear.
    func observedSnapshotStates(reconciler: Reconciler) async -> [ObservedSnapshotState]? {
        guard let present = await observedSnapshotPresence() else { return nil }

        var observed: [ObservedSnapshotState] = []
        var reported = Set<String>()

        for (snapshotId, presence) in present {
            guard let uuid = UUID(uuidString: snapshotId), case .managed(let artifact) = presence
            else { continue }
            let kind = artifact.kind.workloadKind
            let convergence = await reconciler.facts(for: snapshotId, kind: kind)
            observed.append(
                ObservedSnapshotState(
                    snapshotId: uuid,
                    kind: artifact.kind,
                    parentId: artifact.parentId,
                    present: true,
                    exported: artifact.exported,
                    // Re-measured here rather than in `observedSnapshotPresence()`,
                    // which builds the `Equatable` value the planner diffs: a
                    // number that changes every report has no business reaching
                    // a convergence decision (STR-181).
                    facts: SnapshotFootprint.reported(artifact.facts, kind: artifact.kind),
                    observedGeneration: convergence.observedGeneration,
                    convergencePhase: convergence.phase,
                    lastError: convergence.lastError,
                    failedGeneration: convergence.failedGeneration,
                    failureClassification: convergence.failureClassification
                ))
            reported.insert(snapshotId)
        }

        // In-flight and failed captures have no record yet — a capture writes
        // one only once it succeeds — so the artifact's identity has to come
        // from the reconciler's own bookkeeping, which is keyed by kind. That
        // is exactly what the three `WorkloadKind` cases buy: the family is
        // known without a record to read it from. The parent is not, and is
        // deliberately left as the artifact's own id rather than guessed: the
        // control plane only reads `parentId` from an entry it can act on, and
        // an entry with `present: false` is progress, not an inventory.
        for family in SnapshotArtifactKind.allCases {
            let kind = family.workloadKind
            for (snapshotId, _) in await reconciler.inFlightWorkloads(kind: kind)
            where !reported.contains(snapshotId) {
                guard let uuid = UUID(uuidString: snapshotId) else { continue }
                let convergence = await reconciler.facts(for: snapshotId, kind: kind)
                observed.append(
                    ObservedSnapshotState(
                        snapshotId: uuid,
                        kind: family,
                        parentId: uuid,
                        present: false,
                        observedGeneration: convergence.observedGeneration,
                        convergencePhase: convergence.phase ?? "converging",
                        lastError: convergence.lastError,
                        failedGeneration: convergence.failedGeneration,
                        failureClassification: convergence.failureClassification
                    ))
                reported.insert(snapshotId)
            }

            for (snapshotId, failure) in await reconciler.failedConvergences(kind: kind)
            where !reported.contains(snapshotId) {
                guard let uuid = UUID(uuidString: snapshotId) else { continue }
                let convergence = await reconciler.facts(for: snapshotId, kind: kind)
                observed.append(
                    ObservedSnapshotState(
                        snapshotId: uuid,
                        kind: family,
                        parentId: uuid,
                        present: false,
                        observedGeneration: convergence.observedGeneration,
                        convergencePhase: nil,
                        lastError: failure.error,
                        failedGeneration: failure.generation,
                        failureClassification: failure.classification
                    ))
                reported.insert(snapshotId)
            }
        }

        return observed
    }

    /// Every volume this host holds, plus the ones still converging toward
    /// first existence or failed with no bytes at all (STR-148).
    ///
    /// Full-list, like `vms`: the control plane confirms a deletion by this
    /// list *omitting* the volume, so the in-flight and failed entries below
    /// matter — they are what keeps a slow create from reading as "already
    /// gone" and reaping a row whose data is about to appear.
    func observedVolumeStates(reconciler: Reconciler) async -> [ObservedVolumeState]? {
        // Nil propagates all the way to the wire, where the control plane
        // already reads it as "this agent has no opinion about volumes" and
        // skips its whole volume half. That is the same treatment a pre-v31
        // agent gets, and for the same reason: the alternative is an empty list
        // the control plane would believe, reaping terminating volume rows
        // whose bytes are still on disk and erroring every live one.
        guard let present = await observedVolumePresence() else { return nil }

        var observed: [ObservedVolumeState] = []
        var reported = Set<String>()

        for (volumeId, presence) in present {
            guard let uuid = UUID(uuidString: volumeId), case .managed(let facts) = presence else { continue }
            let convergence = await reconciler.facts(for: volumeId, kind: .volume)
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: true,
                    attachment: facts.attachment,
                    // The same number the planner just compared against the
                    // desired size (STR-199), so what the API reports and what
                    // this agent is converging on cannot disagree. Nil when the
                    // probe could not read the image — reported as "no answer",
                    // never as zero.
                    sizeBytes: facts.sizeBytes,
                    attachedVMId: facts.attachedVMId.flatMap { UUID(uuidString: $0) },
                    observedGeneration: convergence.observedGeneration,
                    convergencePhase: convergence.phase,
                    lastError: convergence.lastError,
                    failedGeneration: convergence.failedGeneration,
                    failureClassification: convergence.failureClassification,
                    ioLimits: facts.ioLimits,
                    ioObservedRate: facts.ioObservedRate
                ))
            reported.insert(volumeId)
        }

        for (volumeId, _) in await reconciler.inFlightWorkloads(kind: .volume) where !reported.contains(volumeId) {
            guard let uuid = UUID(uuidString: volumeId) else { continue }
            let convergence = await reconciler.facts(for: volumeId, kind: .volume)
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: false,
                    observedGeneration: convergence.observedGeneration,
                    convergencePhase: convergence.phase ?? "converging",
                    lastError: convergence.lastError,
                    failedGeneration: convergence.failedGeneration,
                    failureClassification: convergence.failureClassification
                ))
            reported.insert(volumeId)
        }

        for (volumeId, failure) in await reconciler.failedConvergences(kind: .volume)
        where !reported.contains(volumeId) {
            guard let uuid = UUID(uuidString: volumeId) else { continue }
            let convergence = await reconciler.facts(for: volumeId, kind: .volume)
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: false,
                    observedGeneration: convergence.observedGeneration,
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation,
                    failureClassification: failure.classification
                ))
        }

        return observed
    }
}
