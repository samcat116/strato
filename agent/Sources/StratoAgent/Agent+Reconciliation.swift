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

// MARK: - Reconciliation (issue #260)

/// Runtime side effects for the reconcile loop. VM items do the manifest
/// bookkeeping and route through the driver registry; convergence outcomes
/// are reported via `ObservedStateReport` rather than per-request replies.
/// Sandbox items route to the sandbox runtime seam (issue #417; the driver
/// itself is issue #421) with the same manifest contract.
extension Agent: ReconcileActuator {
    /// Whether the presence snapshots below account for this host at all. False
    /// while the manifest is unreadable: the maps are empty because the agent
    /// has no memory of what it was running, not because the host is idle
    /// (STR-138).
    func presenceIsComplete() async -> Bool {
        manifestReadFailure == nil
    }

    func observedPresence() async -> [String: VMPresence] {
        var presence: [String: VMPresence] = [:]
        for (vmId, entry) in managedVMs {
            guard let service = hypervisorServices[entry.hypervisorType] else { continue }
            let status = (try? await service.getVMStatus(vmId: vmId)) ?? .unknown
            presence[vmId] = .managed(status)
        }
        for vmId in orphanedVMs.keys where presence[vmId] == nil {
            presence[vmId] = .orphaned
        }
        for (vmId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .vm && presence[vmId] == nil {
            presence[vmId] = .quarantined
        }
        return presence
    }

    /// The sizing each managed VM is running with, from the manifest entry —
    /// which is written from the spec the VM was created (or last resized)
    /// with, so it is exactly the figure a new spec must be diffed against.
    /// Orphans are omitted: an unadopted VM has no control session to resize
    /// over, and adoption is planned for it first anyway.
    func observedSizing() async -> [String: VMSizing] {
        managedVMs.mapValues {
            VMSizing(
                cpus: $0.spec.cpus, memoryBytes: $0.spec.memoryBytes,
                balloonTargetBytes: $0.spec.balloonTargetBytes)
        }
    }

    func observedNetworkSpecs() async -> [String: [NetworkSpec]] {
        managedVMs.mapValues { $0.spec.networks }
    }

    func observedFirecrackerMMDSInterfaces() async -> [String: [String]] {
        managedVMs.compactMapValues { entry in
            guard entry.hypervisorType == .firecracker else { return nil }
            if let interfaces = entry.firecrackerMMDSInterfaces { return interfaces }
            // STR-67 builds predating the exact allow-list field configured
            // every network-enabled Firecracker NIC, independent of the VM
            // kill switch. Preserve that realized policy so this upgrade can
            // reconcile a disabled VM instead of assuming it already has none.
            guard entry.firecrackerMMDSPolicyApplied == true else { return [] }
            return FirecrackerMMDSInterfacePlan.interfaceIDs(for: entry.spec.networks)
        }
    }

    /// What this host has already applied for each workload's edges (STR-151),
    /// read from the manifest entries — the same durable record that survives
    /// the restart the nonces exist to be safe across.
    ///
    /// Orphans are included alongside managed workloads. They are exactly the
    /// case the invariant is written for: an orphan carries a record from a
    /// previous incarnation of the agent, and omitting it would read as "no
    /// record" the moment the workload matters most.
    func observedEdgeNonces() async -> [String: AppliedEdgeNonces] {
        var nonces: [String: AppliedEdgeNonces] = [:]
        // Managed entries first, so an id somehow in both maps resolves to the
        // live one. Assigning a nil `appliedEdges` through the subscript stores
        // nothing, which is exactly the contract the planner reads: an entry
        // that has no record is *absent* from this map, never present-and-empty.
        for map in [managedVMs, managedSandboxes, orphanedVMs, orphanedSandboxes] {
            for (id, entry) in map where nonces[id] == nil {
                nonces[id] = entry.appliedEdges
            }
        }
        return nonces
    }

    /// Write the edge nonces the planner decided this item applied into its
    /// manifest entry.
    ///
    /// Cheap when nothing moved — this runs for every converged workload of
    /// every sync, and the manifest write is a whole-file atomic replace, so an
    /// unconditional `persistManifest()` here would rewrite it once per workload
    /// per sync forever. The equality check is also what bounds the one-time
    /// adoption sweep after an upgrade to a single write per workload.
    func recordAppliedEdges(_ item: ReconcileWorkItem, _ applied: AppliedEdgeNonces) async {
        var changed = false
        switch item.kind {
        case .vm:
            if var entry = managedVMs[item.id], entry.appliedEdges != applied {
                entry.appliedEdges = applied
                managedVMs[item.id] = entry
                changed = true
            }
        case .sandbox:
            if var entry = managedSandboxes[item.id], entry.appliedEdges != applied {
                entry.appliedEdges = applied
                managedSandboxes[item.id] = entry
                changed = true
            }
        case .volume, .volumeSnapshot, .vmCheckpoint, .sandboxSnapshot:
            // Bytes have no edges; the reconciler never calls this for them.
            return
        }
        guard changed else { return }
        persistManifest()
    }

    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus {
        guard let entry = orphanedVMs[item.id] else {
            // A replayed sync may race re-adoption; if the VM is already
            // managed, adoption is satisfied.
            if let managed = managedVMs[item.id],
                let service = hypervisorServices[managed.hypervisorType]
            {
                return try await service.getVMStatus(vmId: item.id)
            }
            throw HypervisorServiceError.vmNotFound(item.id)
        }
        guard let service = getHypervisorService(for: entry.hypervisorType) else {
            throw HypervisorServiceError.hypervisorNotInstalled(entry.hypervisorType.rawValue)
        }

        // The manifest spec is what the surviving process was actually built
        // from; prefer the sync's spec only as metadata for future operations.
        let spec = item.desired?.spec ?? entry.spec
        let status: VMStatus
        do {
            status = try await service.adoptVM(vmId: item.id, spec: entry.spec)
        } catch HypervisorServiceError.adoptionTargetGone(let reason) {
            // The orphan's hypervisor process is gone, so there is nothing to
            // re-attach — but its disks persist and materialization reuses an
            // existing disk, so a fresh create rebuilds the same VM in the
            // "exists, not running" state. The next sync plans any remaining
            // power-state steps from `.created`.
            logger.warning(
                "Orphaned VM has no live process; re-creating it from the manifest spec",
                metadata: ["strato.vm.id": .string(item.id), "reason": .string(reason)])
            try await reconcileCreate(item)
            return .created
        }

        // Builds before STR-67 persisted the network policy but never sent
        // Firecracker's pre-boot `/mmds/config`. A spec diff cannot identify
        // those VMMs, and the API cannot repair the allow-list after boot, so
        // replace the process once while its manifest is still orphaned. If
        // replacement fails, the next sync can adopt/recreate from that same
        // durable entry instead of mistaking a partial upgrade for convergence.
        if entry.hypervisorType == .firecracker,
            entry.firecrackerMMDSPolicyApplied != true
        {
            guard let desired = item.desired else {
                throw HypervisorServiceError.invalidConfiguration(
                    "Firecracker adoption for \(item.id) has no desired VM state")
            }
            let metadata = await metadataForHypervisorCreate(desired)
            let desiredInterfaces = FirecrackerMMDSInterfacePlan.interfaceIDs(
                for: desired.spec.networks,
                metadataServiceEnabled: metadata?.isServiceEnabled ?? false)
            if !desiredInterfaces.isEmpty {
                let realization = try await replaceFirecrackerMMDSPolicy(
                    item: item, desired: desired, entry: entry, service: service)
                managedVMs[item.id] = entry.with(spec: realization.spec)
                    .applyingFirecrackerMMDSPolicy(interfaces: realization.interfaces)
                orphanedVMs.removeValue(forKey: item.id)
                persistManifest()
                await sendVMLog(
                    vmId: item.id, level: .info, eventType: .operation,
                    message: "Firecracker VM recreated after upgrade to enable MMDS",
                    operation: "metadata-upgrade")
                // The replacement is configured but not started. Returning
                // `.created` makes adoptAndReplan restore desired power state.
                return .created
            }
        }

        // `with(spec:)`, not a fresh entry: re-adoption rewrites what the VM is
        // running, never the vsock CID it holds (STR-72) nor the record of what
        // has been applied to it (STR-151).
        var adoptedEntry = entry.recordingAdoption(of: spec)
        if entry.hypervisorType == .firecracker,
            entry.firecrackerMMDSPolicyApplied != true
        {
            // The only legacy path that reaches here had no configured MMDS
            // interfaces and still wants none. Record that realized empty
            // policy without projecting newer desired state onto the VMM.
            adoptedEntry = adoptedEntry.applyingFirecrackerMMDSPolicy(interfaces: [])
        }
        managedVMs[item.id] = adoptedEntry
        orphanedVMs.removeValue(forKey: item.id)
        persistManifest()

        // A surviving Firecracker process also kept its MMDS store, but an
        // older process may have no data and the agent's durable metadata copy
        // may be newer. Refresh immediately after adoption rather than waiting
        // for another desired-state sync; failure is retried by that next sync.
        if entry.hypervisorType == .firecracker {
            let interfaces =
                adoptedEntry.firecrackerMMDSInterfaces
                ?? FirecrackerMMDSInterfacePlan.interfaceIDs(for: adoptedEntry.spec.networks)
            await service.restoreMetadataInterfaceInventory(
                vmId: item.id, interfaces: interfaces)
            await refreshFirecrackerMetadata(vmId: item.id, using: service)
        }

        logger.info(
            "Orphaned VM re-adopted and managed again",
            metadata: [
                "strato.vm.id": .string(item.id),
                "status": .string(status.rawValue),
            ])
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "VM re-adopted after agent restart", operation: "adopt")
        return status
    }

    func observedSandboxPresence() async -> [String: SandboxPresence] {
        var presence: [String: SandboxPresence] = [:]
        for sandboxId in managedSandboxes.keys {
            guard let runtime = sandboxRuntime else {
                presence[sandboxId] = .managed(.unknown)
                continue
            }
            let status = (try? await runtime.getSandboxStatus(sandboxId: sandboxId)) ?? .unknown
            presence[sandboxId] = .managed(status)
        }
        for sandboxId in orphanedSandboxes.keys where presence[sandboxId] == nil {
            presence[sandboxId] = .orphaned
        }
        for (sandboxId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .sandbox && presence[sandboxId] == nil {
            presence[sandboxId] = .quarantined
        }
        return presence
    }

    func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus {
        guard let entry = orphanedSandboxes[item.id] else {
            // A replayed sync may race re-adoption; if the sandbox is already
            // managed, adoption is satisfied.
            if managedSandboxes[item.id] != nil {
                return try await requireSandboxRuntime().getSandboxStatus(sandboxId: item.id)
            }
            throw SandboxRuntimeError.sandboxNotFound(item.id)
        }
        let runtime = try requireSandboxRuntime()
        guard let spec = entry.sandboxSpec else {
            // A sandbox-kind entry without its spec cannot be reattached; only
            // deletion can release it.
            throw SandboxRuntimeError.sandboxNotFound(item.id)
        }

        let status: SandboxStatus
        do {
            status = try await runtime.adoptSandbox(sandboxId: item.id, spec: spec)
        } catch SandboxRuntimeError.adoptionTargetGone(let reason) {
            // The orphan's Firecracker process is gone, so there is nothing to
            // re-attach — but its artifacts persist and create is idempotent, so
            // a fresh create rebuilds the same sandbox in the "exists, not
            // running" state. The next sync plans any remaining power-state
            // steps from `.stopped`. Requires the desired entry (present for an
            // orphan the control plane still wants); without it, re-adoption
            // simply failed.
            guard item.desiredSandbox != nil else { throw SandboxRuntimeError.sandboxNotFound(item.id) }
            logger.warning(
                "Orphaned sandbox has no live process; re-creating it from the desired entry",
                metadata: ["strato.sandbox.id": .string(item.id), "reason": .string(reason)])
            try await sandboxReconcileCreate(item)
            return .stopped
        }
        managedSandboxes[item.id] = entry
        orphanedSandboxes.removeValue(forKey: item.id)
        persistManifest()

        logger.info(
            "Orphaned sandbox re-adopted and managed again",
            metadata: [
                "strato.sandbox.id": .string(item.id),
                "status": .string(status.rawValue),
            ])
        return status
    }

    /// Every volume whose data this host holds, with the attachment the agent
    /// durably records for it (STR-148).
    ///
    /// Presence comes from the storage backend's own durable inventory, so
    /// there is no hypervisor session to adopt and every entry is `.managed`.
    /// Attachment comes from the VM manifest entries, *not* from a live
    /// hypervisor query: a powered-off guest has no device list, and reading
    /// that silence as "detached" would plan an attach against a dead control
    /// channel on every sync.
    func observedVolumePresence() async -> [String: VolumePresence]? {
        // No storage backend is an *answer*: such a host holds no volumes, and
        // the control plane never places one on it.
        guard let storageBackends else { return [:] }
        let inventory: [String: DiskAttachment]
        do {
            inventory = try await storageBackends.inventory(
                desiredVolumes: Array(desiredVolumeStates.values))
        } catch {
            // Nil, not `[:]`. An empty inventory is authoritative to everything
            // downstream — the reconciler would plan a create for every volume
            // the control plane wants here, and the observed report's full-list
            // semantics would confirm deletions that never happened. "I cannot
            // answer" is the only honest thing to say, and it costs one sync.
            logger.error(
                "Cannot enumerate the volume store; reporting no volume inventory at all this sync",
                metadata: ["error": .string(error.localizedDescription)])
            return nil
        }

        let attachments = recordedVolumeAttachments()
        var presence: [String: VolumePresence] = [:]
        for (volumeId, disk) in inventory {
            let attachment = attachments[volumeId]
            let sizeBytes = await volumeVirtualSize(volumeId: volumeId, attachment: disk)
            presence[volumeId] = .managed(
                ObservedVolumeFacts(
                    attachment: disk,
                    sizeBytes: sizeBytes,
                    attachedVMId: attachment?.vmId,
                    deviceName: attachment?.deviceName))
        }
        // Sizes for volumes that no longer exist would leak across a long
        // uptime; the inventory is authoritative, so prune to it.
        volumeSizes = volumeSizes.filter { inventory[$0.key] != nil }
        return presence
    }

    func prepareManagedVolumeInventory(
        from desiredVMs: [DesiredVMState], desiredVolumes: [DesiredVolumeState]
    ) async {
        volumeAdoptionFailures = [:]
        desiredVolumeStates = Dictionary(
            desiredVolumes.map { ($0.volumeId.uuidString, $0) },
            uniquingKeysWith: { first, _ in first })
        guard let storageBackend, let storageBackends else { return }
        var formats: [UUID: DiskFormat] = [:]
        for volume in desiredVolumes {
            formats[volume.volumeId] = DiskFormat(rawValue: volume.format)
        }

        var recoveredManifest = false
        for desiredVM in desiredVMs {
            let vmId = desiredVM.vmId.uuidString
            guard let quarantined = quarantinedWorkloads[vmId],
                quarantined.effectiveKind == .vm,
                let recovered = quarantined.recoveringManagedVolumeIdentities(
                    from: desiredVM.spec)
            else { continue }
            quarantinedWorkloads.removeValue(forKey: vmId)
            orphanedVMs[vmId] = recovered
            recoveredManifest = true
            logger.warning(
                "Recovered historical path-only VM manifest with managed volume identities",
                metadata: ["strato.vm.id": .string(vmId)])
        }
        if recoveredManifest { persistManifest() }

        var inventory: [String: DiskAttachment]
        do {
            inventory = try await storageBackends.inventory(desiredVolumes: desiredVolumes)
        } catch {
            // `observedVolumePresence` will report the authoritative inventory
            // as unreadable and skip this half of convergence.
            return
        }

        for desiredVM in desiredVMs {
            for volume in desiredVM.spec.volumes where inventory[volume.volumeId.uuidString] == nil {
                guard case .file(let existingPath, _) = volume.attachment else { continue }
                let volumeId = volume.volumeId.uuidString
                guard desiredVolumeStates[volumeId]?.storage == .local else { continue }
                guard let format = formats[volume.volumeId] else {
                    volumeAdoptionFailures[volumeId] =
                        "managed volume \(volumeId) has no supported desired format"
                    continue
                }

                do {
                    let adopted = try await storageBackend.adoptVolume(
                        volumeId: volumeId, existingPath: existingPath, format: format)
                    inventory[volumeId] = adopted
                } catch {
                    volumeAdoptionFailures[volumeId] = error.localizedDescription
                    logger.error(
                        "Failed to adopt historical VM disk as a managed volume",
                        metadata: [
                            "strato.vm.id": .string(desiredVM.vmId.uuidString),
                            "volumeId": .string(volumeId),
                            "path": .string(existingPath),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
        }
    }

    /// Which VM each volume is plugged into, from the VM manifest entries'
    /// `spec.volumes` — the durable attachment record. Orphans are included:
    /// their disks are still presented to a process this agent has not
    /// re-adopted yet, so reporting them detached would plan a duplicate
    /// attach.
    func recordedVolumeAttachments() -> [String: (vmId: String, deviceName: String)] {
        var attachments: [String: (vmId: String, deviceName: String)] = [:]
        for (vmId, entry) in managedVMs.merging(orphanedVMs, uniquingKeysWith: { managed, _ in managed }) {
            for volume in entry.spec.volumes {
                attachments[volume.volumeId.uuidString] = (
                    vmId: vmId, deviceName: volume.deviceName.rawValue
                )
            }
        }
        return attachments
    }

    /// A volume's virtual size, cached in memory.
    ///
    /// Every write path records the size it produced, so the steady state runs
    /// no subprocess at all; the probe below only fires for a volume this
    /// process has not seen written — one created by a previous incarnation of
    /// the agent — and then once per volume, not once per sync.
    ///
    /// A probe that fails yields nil, and nil never grows anything: the planner
    /// and the resize actuator both read this, and both treat an unreadable
    /// size as a `blocked` convergence naming the image rather than a resize on
    /// a guess. What nil must *not* do is pass silently — an item that runs no
    /// steps records its generation as applied, which is how an unreadable
    /// volume used to report a grow it never attempted as converged (STR-199).
    func volumeVirtualSize(volumeId: String, attachment: DiskAttachment) async -> Int64? {
        if let cached = volumeSizes[volumeId] { return cached }
        guard let storageBackends else { return nil }
        do {
            let storage = desiredVolumeStates[volumeId]?.storage ?? .local
            let storageBackend = try await storageBackends.backend(for: storage)
            let info = try await storageBackend.volumeInfo(attachment: attachment)
            volumeSizes[volumeId] = info.virtualSize
            return info.virtualSize
        } catch {
            logger.debug(
                "Could not read volume size; leaving its size unconverged",
                metadata: ["volumeId": .string(volumeId), "error": .string(error.localizedDescription)])
            return nil
        }
    }

    /// Every snapshot artifact this host holds (STR-150), from the durable
    /// record store.
    ///
    /// The record is the inventory, not the filesystem — which is a real
    /// tradeoff and worth naming. Two of the three families cannot be
    /// enumerated cheaply (a qcow2 internal snapshot costs a `qemu-img info`
    /// subprocess per VM) and none of them can be *described* by their bytes at
    /// all: a Firecracker checkpoint's fork-layout version and CPU template are
    /// not recoverable from the files. So the agent remembers what it captured,
    /// exactly as `VMManifestStore` remembers what it runs, and inherits the
    /// same caveat — an artifact deleted out of band still reports present
    /// until something tries to use it. Deletion is idempotent on every
    /// backend, so converging over it costs nothing.
    func observedSnapshotPresence() async -> [String: SnapshotPresence]? {
        // Nil, not `[:]`. An empty inventory is authoritative downstream: the
        // control plane reads omission from a full list as confirmation that an
        // artifact's bytes are gone and reaps the row, so a host that could not
        // read its record file must say it does not know.
        guard !snapshotInventoryUnreadable else { return nil }

        var presence: [String: SnapshotPresence] = [:]
        for (snapshotId, record) in snapshotRecords {
            presence[snapshotId.uuidString] = .managed(
                ObservedSnapshotArtifact(
                    kind: record.kind, parentId: record.parentId,
                    facts: record.facts, exported: record.exported))
        }
        return presence
    }

    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        if item.kind.isSnapshotArtifact {
            try await performSnapshot(step, item: item)
            return
        }
        if item.kind == .volume {
            try await performVolume(step, item: item)
            return
        }
        if item.kind == .sandbox {
            try await performSandbox(step, item: item)
            return
        }
        do {
            switch step {
            case .adopt:
                // Adoption flows through adoptVM (the reconciler needs the
                // observed status back to plan the remaining steps).
                _ = try await adoptVM(item)
            case .create:
                try await reconcileCreate(item)
            case .boot:
                try await reconcileBoot(item)
            case .pause:
                try await reconcileService(for: item.id).pauseVM(vmId: item.id)
            case .resume:
                try await reconcileService(for: item.id).resumeVM(vmId: item.id)
            case .resize:
                try await reconcileResize(item)
            case .reconfigureNetworks:
                try await reconcileNetworks(item)
            case .shutdown:
                try await reconcileService(for: item.id).shutdownVM(vmId: item.id)
            case .delete:
                try await reconcileDelete(item)
            case .reboot:
                try await reconcileService(for: item.id).rebootVM(vmId: item.id)
                await sendVMLog(
                    vmId: item.id, level: .info, eventType: .operation,
                    message: "VM restarted by reconciliation", operation: "reboot")
            case .restore:
                try await reconcileRestore(item)
            case .attach, .detach, .export:
                // Volume- and snapshot-only steps; both kinds were handled above
                // and the planner never emits these for a VM or sandbox.
                throw HypervisorServiceError.invalidConfiguration(
                    "step \(step) is not applicable to a \(item.kind.rawValue) workload")
            }
        } catch {
            if let claim = bootCapacityClaims.removeValue(forKey: item.id) {
                capacityAdmissionLedger.release(claim)
            }
            throw error
        }
    }

    /// Starts a VM, first giving its backend the chance to widen whatever stored
    /// configuration the boot is about to read (STR-187).
    ///
    /// This is where "a VM's hot-plug slots and memory headroom are fixed at
    /// create time" stops being true of the libvirt driver. A boot is the one
    /// moment a stopped VM's configuration can be rewritten safely — nothing is
    /// holding a port, a memory region or a vCPU — and it is also the moment the
    /// remedy those ceilings name ("stop and start the VM") has to actually take
    /// effect for the advice to be worth giving.
    ///
    /// Two steps in the same item make the widening pointless, and both are
    /// skipped rather than spent. A `.create` built the configuration from the
    /// very spec below moments ago, so there is nothing to find. A `.restore`
    /// runs *after* the boot (`Reconciliation.edgeSteps` plans edges after the
    /// status steps) and converges through `virDomainRevertToSnapshot`, which
    /// replaces the definition with the one recorded in the checkpoint — so the
    /// widening would be defined, immediately overwritten, and paid for again on
    /// every boot forever. A VM being restored keeps the ceilings its checkpoint
    /// was captured with; "stop and start it to widen" holds for its *next*
    /// boot, the one with no restore outstanding.
    ///
    /// A widening that *fails* is logged rather than thrown — the backend
    /// contract says best effort, because a VM that comes up with the ceiling it
    /// already had is the status quo, while a VM that does not come up is a
    /// regression.
    func reconcileBoot(_ item: ReconcileWorkItem) async throws {
        let service = try reconcileService(for: item.id)
        guard let desired = item.desired,
            let current = managedVMs[item.id] ?? orphanedVMs[item.id]
        else {
            throw HypervisorServiceError.invalidConfiguration("boot work item without a managed VM spec")
        }

        // A VM start is downstream of its managed boot volume, not merely of a
        // path with that volume's id (STR-242). Image-backed creation produces
        // the source image's native virtual size first and grows it in a later
        // volume step. Re-check the storage inventory and durable attachment at
        // the last possible moment so a failed or slow grow cannot be followed
        // by a successful boot just because both items were in one sync.
        guard let volumePresence = await observedVolumePresence() else {
            throw DependencyPendingError(
                "managed boot-volume inventory is unreadable; VM \(item.id) will remain stopped until it can be verified"
            )
        }
        let observedVolumes = volumePresence.reduce(into: [String: ObservedVolumeFacts]()) {
            result, entry in
            if case .managed(let facts) = entry.value {
                result[entry.key] = facts
            }
        }
        if let reason = VMBootVolumeDependency.pendingReason(
            vmId: item.id,
            spec: desired.spec,
            desiredVolumes: desiredVolumeStates,
            observedVolumes: observedVolumes)
        {
            throw DependencyPendingError(reason)
        }

        if desired.hypervisorType == .qemu {
            try await prepareQEMUStorageAttachments(current.spec)
        }

        let raw = await rawHostCapacitySnapshot()
        let currentReservation = VMHostReservation.forManifestEntry(
            current, architecture: .current)
        let desiredReservation = VMHostReservation.forSpec(
            desired.spec, hypervisorType: desired.hypervisorType, architecture: .current)
        let growth = HostReservation.positiveDelta(from: currentReservation, to: desiredReservation)
        let claim: HostCapacityClaim?
        do {
            try capacityAdmissionLedger.validateExistingReservation(
                snapshot: raw, agentName: initialAgentID)
            claim = try capacityAdmissionLedger.claim(
                growth, snapshot: raw, agentName: initialAgentID)
        } catch let refusal as HostCapacityAdmissionError {
            throw DependencyPendingError(refusal.localizedDescription)
        }

        if !item.steps.contains(.create), !item.steps.contains(.restore), let spec = item.desired?.spec {
            do {
                try await service.redefineVM(vmId: item.id, spec: spec)
                if current.hypervisorType == .qemu,
                    desiredReservation.memoryBytes > currentReservation.memoryBytes,
                    let entry = managedVMs[item.id] ?? orphanedVMs[item.id]
                {
                    let widened = entry.reservingMemory(atLeast: desiredReservation.memoryBytes)
                    if managedVMs[item.id] != nil {
                        managedVMs[item.id] = widened
                    } else {
                        orphanedVMs[item.id] = widened
                    }
                    // The persistent domain may already be wider even if the
                    // boot below fails, so record the reservation immediately.
                    persistManifest()
                }
            } catch {
                logger.warning(
                    """
                    Could not widen this VM's stored configuration before booting it; it starts with the \
                    hot-plug slots and size ceilings it already had
                    """,
                    metadata: [
                        "strato.vm.id": .string(item.id), "error": .string(error.localizedDescription),
                    ])
            }
        }
        do {
            // Existing IMDS VMs may carry a seed and persistent definition
            // created before the NoCloudNet bootstrap repair. Re-realizing the
            // NICs is idempotent and gives the provisioner the current guest
            // network document. Treat this migration as required: a VM that
            // merely starts while cloud-init falls back is not converged.
            if !item.steps.contains(.create), desired.spec.metadataSource == .imds {
                let attachments = try await networkOrchestrator.prepareAttachments(
                    vmId: item.id, networks: desired.spec.networks,
                    metadataDenied: desired.metadata.map { !$0.isServiceEnabled } ?? false)
                try await service.convergeGuestBootstrap(
                    vmId: item.id, spec: desired.spec,
                    networkAttachments: attachments, metadata: desired.metadata)
            }
            try await service.ensureMemoryCeiling(vmId: item.id, spec: desired.spec)
            try await service.bootVM(vmId: item.id)
        } catch {
            capacityAdmissionLedger.release(claim)
            throw error
        }

        if let entry = managedVMs[item.id] ?? orphanedVMs[item.id] {
            var booted = entry.reservingPositiveSizingGrowth(toward: desired.spec)
            if entry.hypervisorType == .qemu {
                booted = booted.reservingMemory(
                    atLeast: max(currentReservation.memoryBytes, desiredReservation.memoryBytes))
            }
            if managedVMs[item.id] != nil {
                managedVMs[item.id] = booted
            } else {
                orphanedVMs[item.id] = booted
            }
            // The larger domain is running now. Make its reservation durable
            // before retiring the provisional claim; the separate drift
            // resize item may not arrive until the next desired-state sync.
            persistManifest()
        }

        if let claim, item.steps.contains(.resize) {
            bootCapacityClaims[item.id] = claim
        } else {
            capacityAdmissionLedger.release(claim)
        }
    }

    /// Load a checkpoint back into an existing VM (STR-151).
    ///
    /// Reached only while the VM's desired `restore` nonce outranks the one this
    /// host recorded, and only for a VM the agent is managing — so unlike the
    /// RPC it replaces, a replayed or re-driven sync cannot rewind the guest a
    /// second time. The checkpoint lives inside the VM's own disks, so there is
    /// nothing to stage and nothing that can expire in the entry.
    func reconcileRestore(_ item: ReconcileWorkItem) async throws {
        guard let restore = item.desired?.restore else {
            throw HypervisorServiceError.invalidConfiguration("restore work item without a restore nonce")
        }
        try await reconcileService(for: item.id).restoreVM(
            vmId: item.id, snapshotId: restore.snapshotId.uuidString)
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "VM restored from checkpoint \(restore.snapshotId.uuidString)",
            operation: "restore")
    }

    func convergenceDidChange() async {
        await sendObservedStateReport()
    }
}
