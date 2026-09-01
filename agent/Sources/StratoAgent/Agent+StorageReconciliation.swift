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

/// Owns volume and snapshot-artifact convergence for the reconciler.
extension Agent {
    // MARK: - Volume convergence

    func performVolume(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .create:
            try await volumeReconcileCreate(item)
        case .resize:
            try await volumeReconcileResize(item)
        case .delete:
            try await volumeReconcileDelete(item)
        case .attach:
            try await volumeReconcileAttach(item)
        case .detach:
            try await volumeReconcileDetach(item)
        case .adopt, .boot, .pause, .resume, .shutdown, .export, .reboot, .restore,
            .reconfigureNetworks:
            // A volume has no run state, nowhere to be exported to, and no
            // edges to apply; the planner never emits these.
            throw VolumeConvergenceError.unsupported("step \(step) is not applicable to a volume")
        }
    }

    // MARK: - Snapshot artifact convergence (ADR 0001 stage 8, STR-150)

    func performSnapshot(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .create:
            try await snapshotReconcileCapture(item)
        case .delete:
            try await snapshotReconcileDelete(item)
        case .export:
            try await snapshotReconcileExport(item)
        case .adopt, .boot, .pause, .resume, .shutdown, .resize, .attach, .detach, .reboot, .restore,
            .reconfigureNetworks:
            // An artifact is frozen bytes: it has no run state, no size that
            // can change, nothing to plug in, and no edges of its own — a
            // restore acts on the artifact's *parent*. The planner never emits
            // any of these.
            throw SnapshotConvergenceError.unsupported(
                "step \(step) is not applicable to a snapshot artifact")
        }
    }

    /// Capture one artifact. Runs **only** when the artifact is absent from
    /// this host — `planCore` plans `.create` for nothing else — which is what
    /// makes the whole conversion safe: a replayed sync can never re-checkpoint
    /// a live guest over the point in time the user is holding.
    ///
    /// Everything the control plane will ever learn about the capture is
    /// recorded here, because this is the only moment the agent can measure it.
    func snapshotReconcileCapture(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSnapshot else {
            throw SnapshotConvergenceError.unsupported("snapshot capture requires a desired entry")
        }
        try requireWritableSnapshotInventory()
        let snapshotId = desired.snapshotId.uuidString
        let parentId = desired.parentId.uuidString

        let facts: ObservedSnapshotFacts
        switch desired.kind {
        case .volumeSnapshot:
            // The backend's snapshot is a qcow2 overlay backed by the volume,
            // and nothing switches a running QEMU's active layer onto it — so a
            // snapshot taken while a guest is writing the base is not
            // point-in-time however well the guest was quiesced (issue #747).
            // The control plane refuses this at admission; the agent refuses it
            // again because a level-triggered entry outlives the request that
            // made it, and the volume may have been attached since.
            if let holder = desired.capture?.attachedVMId {
                let holderID = holder.uuidString
                guard let service = getHypervisorServiceForVM(vmId: holderID),
                    let status = try? await service.getVMStatus(vmId: holderID),
                    status == .shutdown || status == .created
                else {
                    throw SnapshotConvergenceError.sourceNotReady(
                        "volume \(parentId) is attached to VM \(holderID), which is not confirmed shut down")
                }
            }
            let backend = try await requireStorageBackend(
                volumeId: parentId, volumeStorage: desired.volumeStorage)
            guard let disk = try await backend.inspectVolume(volumeId: parentId) else {
                // The volume may be mid-create in this very sync; a dependency
                // wait burns no attempt and retries on the next one.
                throw SnapshotConvergenceError.sourceNotReady(
                    "volume \(parentId) is not present on this host yet")
            }
            let path = try await backend.createSnapshot(
                volumeId: parentId, snapshotId: snapshotId, attachment: disk)
            facts = ObservedSnapshotFacts(
                sizeBytes: Self.fileSizeBytes(at: path),
                storagePath: path,
                architecture: CPUArchitecture.current)

        case .vmCheckpoint:
            guard let service = getHypervisorServiceForVM(vmId: parentId) else {
                throw SnapshotConvergenceError.sourceNotReady(
                    "VM \(parentId) is not present on this host yet")
            }
            let report = try await service.checkpointVM(vmId: parentId, snapshotId: snapshotId)
            facts = ObservedSnapshotFacts(
                // The machine state alone: the disks it lives inside are
                // already charged as volume storage, and an internal snapshot
                // does not copy them. Nil is "the build reported no size",
                // never "empty" — the control plane keeps its estimate.
                sizeBytes: report.vmStateSizeBytes,
                architecture: CPUArchitecture.current,
                qemuVersion: report.hypervisorVersion)

        case .sandboxSnapshot:
            guard let runtime = sandboxRuntime else {
                throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
            }
            let result = try await runtime.snapshotSandbox(
                sandboxId: parentId, snapshotId: snapshotId,
                mode: desired.capture?.sandboxMode ?? .resume)
            facts = ObservedSnapshotFacts(
                sizeBytes: result.totalSizeBytes,
                storagePath: result.storagePath,
                architecture: CPUArchitecture.current,
                firecrackerVersion: result.firecrackerVersion,
                guestControlProtocolVersion: result.guestControlProtocolVersion,
                forkLayoutVersion: result.forkLayoutVersion,
                cpuTemplate: result.cpuTemplate)
        }

        snapshotRecords[desired.snapshotId] = SnapshotRecord(
            snapshotId: desired.snapshotId, kind: desired.kind, parentId: desired.parentId,
            volumeStorage: desired.kind == .volumeSnapshot ? desired.volumeStorage : nil,
            facts: facts)
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact captured",
            metadata: [
                "kind": .string(desired.kind.rawValue),
                "snapshotId": .string(snapshotId),
                "parentId": .string(parentId),
            ])
    }

    /// Remove an artifact's bytes from this host, then forget it.
    ///
    /// The record goes **after** the backend confirms, and only then: the
    /// record's absence is what the observed report turns into "this artifact
    /// is gone", which is what authorizes the control plane to reap the row.
    /// Forgetting first would confirm a deletion that had not happened and
    /// leak the bytes with nothing left pointing at them.
    ///
    /// A tombstoned artifact carries no desired entry, so its kind and parent
    /// come from the record — the same derivation the capture used, which is
    /// exactly why no path ever travels on the wire.
    func snapshotReconcileDelete(_ item: ReconcileWorkItem) async throws {
        try requireWritableSnapshotInventory()
        guard let snapshotId = UUID(uuidString: item.id) else {
            throw SnapshotConvergenceError.unsupported("snapshot id '\(item.id)' is not a UUID")
        }
        let kind: SnapshotArtifactKind
        let parentId: UUID
        if let desired = item.desiredSnapshot {
            kind = desired.kind
            parentId = desired.parentId
        } else if let record = snapshotRecords[snapshotId] {
            kind = record.kind
            parentId = record.parentId
        } else {
            // Nothing here and nothing recorded: already converged.
            return
        }

        // Every backend's deletion is idempotent, so a re-driven delete over
        // bytes that are already gone confirms cleanly rather than failing.
        switch kind {
        case .volumeSnapshot:
            let backend = try await requireStorageBackend(
                volumeId: parentId.uuidString,
                volumeStorage: VolumeSnapshotStorageRouting.resolve(
                    desiredStorage: item.desiredSnapshot?.volumeStorage,
                    recordedStorage: snapshotRecords[snapshotId]?.volumeStorage,
                    currentParentStorage: desiredVolumeStates[parentId.uuidString]?.storage))
            try await backend.deleteSnapshot(
                volumeId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        case .vmCheckpoint:
            guard let service = getHypervisorServiceForVM(vmId: parentId.uuidString) else {
                // The checkpoint lives inside the VM's own disks. No VM here
                // means no disks here means no checkpoint here — the deletion
                // is satisfied, and refusing would strand the row forever on
                // the one host that can never confirm it.
                snapshotRecords.removeValue(forKey: snapshotId)
                persistSnapshotRecords()
                return
            }
            try await service.deleteVMCheckpoint(
                vmId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        case .sandboxSnapshot:
            guard let runtime = sandboxRuntime else {
                throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
            }
            try await runtime.deleteSandboxSnapshot(
                sandboxId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        }

        snapshotRecords.removeValue(forKey: snapshotId)
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact deleted",
            metadata: [
                "kind": .string(kind.rawValue),
                "snapshotId": .string(snapshotId.uuidString),
                "parentId": .string(parentId.uuidString),
            ])
    }

    /// Converge the placement fact "this artifact also exists in the control
    /// plane's object store" by streaming it there (issue #428, STR-150).
    ///
    /// The transfer itself stays a transport concern — one sequential mTLS PUT
    /// per artifact, hashed and sized control-plane-side as it lands — and only
    /// its *outcome* is state. Uploads are idempotent (each PUT replaces the
    /// object at its deterministic key), so a re-driven export after a lost
    /// report converges on the same bytes instead of duplicating them.
    func snapshotReconcileExport(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSnapshot, let export = desired.export else {
            throw SnapshotConvergenceError.unsupported("snapshot export requires an export target")
        }
        try requireWritableSnapshotInventory()
        guard desired.kind == .sandboxSnapshot else {
            // A VM checkpoint lives inside disks it does not own, and a volume
            // snapshot's overlay is meaningless without its backing chain;
            // neither has an off-node representation to upload. Permanent, so
            // the control plane degrades the artifact with the reason instead
            // of retrying an impossibility.
            throw SnapshotConvergenceError.unsupported(
                "\(desired.kind.rawValue) artifacts cannot be exported off this host")
        }
        guard let runtime = sandboxRuntime else {
            throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
        }
        try await runtime.exportSandboxSnapshot(
            sandboxId: desired.parentId.uuidString, snapshotId: desired.snapshotId.uuidString,
            uploads: export.uploads)

        snapshotRecords[desired.snapshotId]?.exported = true
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact exported",
            metadata: [
                "snapshotId": .string(desired.snapshotId.uuidString),
                "parentId": .string(desired.parentId.uuidString),
                "artifacts": .stringConvertible(export.uploads.count),
            ])
    }

    /// Refuse to converge snapshot work while the record file is unreadable.
    ///
    /// The first write after a failed read is what turns a recoverable file
    /// into a permanent loss (`VMManifestStore.save`'s rule), and every step
    /// here writes one. The reconciler already skips the snapshot half of a
    /// sync in this state — this is the belt to those braces, for work already
    /// queued when the read failed.
    func requireWritableSnapshotInventory() throws {
        guard snapshotInventoryUnreadable else { return }
        throw SnapshotConvergenceError.unsupported(
            "this host cannot read its snapshot record file, so it will not write over it")
    }

    func persistSnapshotRecords() {
        guard !snapshotInventoryUnreadable else { return }
        snapshotRecordStore.save(snapshotRecords)
    }

    func applySnapshotInventory(_ inventory: SnapshotInventory) {
        switch inventory {
        case .fresh:
            snapshotRecords = [:]
            snapshotInventoryUnreadable = false
        case .loaded(let records):
            snapshotRecords = records
            snapshotInventoryUnreadable = false
            if !records.isEmpty {
                logger.info(
                    "Recovered snapshot artifacts recorded by a previous incarnation of this agent",
                    metadata: ["count": .stringConvertible(records.count)])
            }
        case .unreadable:
            // The store has already logged this loudly.
            snapshotInventoryUnreadable = true
        }
    }

    /// The apparent size of a file (`st_size`), or nil when it cannot be read.
    /// Nil is "unknown", never "empty" — a footprint the agent could not measure
    /// must not silently become a free one in the control plane's quota
    /// accounting.
    ///
    /// Apparent, not allocated: for the archives this measures — a sandbox
    /// snapshot's files, an overlay at the instant it was created — the two are
    /// the same. `SnapshotFootprint.allocatedBytes` is what to reach for when the
    /// question is how much of the filesystem an artifact is occupying *now*.
    static func fileSizeBytes(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    func requireStorageBackend(
        volumeId: String? = nil, desired: DesiredVolumeState? = nil,
        volumeStorage: DesiredVolumeStorage? = nil
    ) async throws -> any StorageBackend {
        guard let storageBackends else {
            // A host with no storage backend can never grow one by retrying,
            // and the control plane only places volumes on QEMU-capable agents,
            // so this is a misconfiguration to surface rather than retry.
            throw VolumeConvergenceError.unsupported("storage backend not available on this agent")
        }
        let storage =
            volumeStorage
            ?? desired?.storage
            ?? volumeId.flatMap { desiredVolumeStates[$0]?.storage }
            ?? .local
        return try await storageBackends.backend(for: storage)
    }

    func volumeReconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume else {
            throw VolumeConvergenceError.unsupported("volume create requires a desired entry")
        }
        guard let format = DiskFormat(rawValue: desired.format) else {
            throw VolumeConvergenceError.unsupported("unsupported volume format '\(desired.format)'")
        }
        if let adoptionFailure = volumeAdoptionFailures[item.id] {
            throw VolumeConvergenceError.blocked(
                "managed volume \(item.id) has historical bytes that could not be adopted: \(adoptionFailure)")
        }
        let backend = try await requireStorageBackend(volumeId: item.id, desired: desired)

        // The create strategy is read only here, when the volume does not yet
        // exist. A present volume never re-runs it, which is what makes a
        // replayed sync unable to clone over live data.
        let attachment: DiskAttachment
        switch desired.source?.kind {
        case DesiredVolumeSource.clone:
            guard let sourceId = desired.source?.sourceVolumeId?.uuidString else {
                throw VolumeConvergenceError.unsupported("clone source volume id missing")
            }
            // The control plane guarantees the source is on this agent, so the
            // path comes from our own inventory rather than the wire.
            guard let sourceDesired = desiredVolumeStates[sourceId] else {
                throw VolumeConvergenceError.sourceNotReady(
                    "source volume \(sourceId) has no desired storage configuration")
            }
            guard sourceDesired.storage == desired.storage else {
                throw VolumeConvergenceError.unsupported(
                    "cross-backend volume clones are not supported")
            }
            guard let source = try await backend.inspectVolume(volumeId: sourceId) else {
                // Genuinely a dependency, not a failure: the source may still
                // be converging earlier in this same sync.
                throw VolumeConvergenceError.sourceNotReady(
                    "source volume \(sourceId) is not present on this agent yet")
            }
            if let holder = recordedVolumeAttachments()[sourceId] {
                guard desired.source?.sourceVMId?.uuidString == holder.vmId else {
                    throw VolumeConvergenceError.sourceNotReady(
                        "source volume \(sourceId) is attached to VM \(holder.vmId), but its declared source VM lane has not converged"
                    )
                }
                guard let service = getHypervisorServiceForVM(vmId: holder.vmId),
                    let status = try? await service.getVMStatus(vmId: holder.vmId),
                    status == .shutdown || status == .created
                else {
                    throw VolumeConvergenceError.blocked(
                        "source volume \(sourceId) is attached to VM \(holder.vmId), which is not confirmed shut down")
                }
            }
            attachment = try await backend.cloneVolume(
                sourceVolumeId: sourceId, sourceAttachment: source, targetVolumeId: item.id)
        case DesiredVolumeSource.image:
            guard let imageInfo = desired.source?.imageInfo,
                let artifactKind = desired.source?.artifactKind
            else {
                throw VolumeConvergenceError.unsupported(
                    "image create strategy requires image info and an artifact kind")
            }
            attachment = try await backend.createVolumeFromImage(
                volumeId: item.id, imageInfo: imageInfo, format: format, artifactKind: artifactKind)
        default:
            attachment = try await backend.createVolume(
                volumeId: item.id, sizeBytes: desired.sizeBytes, format: format)
        }

        // A cloned or image-backed volume inherits the source's size, which may
        // be smaller than what was asked for; the next sync plans the grow.
        volumeSizes[item.id] = try? await backend.volumeInfo(attachment: attachment).virtualSize
        logger.info(
            "Volume converged into existence",
            metadata: [
                "volumeId": .string(item.id),
                "attachment": .string(String(describing: attachment)),
                "strategy": .string(desired.source?.kind ?? DesiredVolumeSource.blank),
            ])
    }

    func volumeReconcileResize(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume else {
            throw VolumeConvergenceError.unsupported("volume resize requires a desired entry")
        }
        let backend = try await requireStorageBackend(volumeId: item.id, desired: desired)
        guard let disk = try await backend.inspectVolume(volumeId: item.id) else {
            throw VolumeConvergenceError.sourceNotReady("volume \(item.id) is not present on this agent")
        }
        // The planner's cached size, not a fresh `qemu-img info` (STR-199).
        //
        // Two reasons, and the second is the load-bearing one. It is the same
        // number the planner compared to decide this step was needed, so the
        // actuator can no longer disagree with the plan it was handed. And a
        // blocked grow is re-driven on *every* sync for as long as the guest
        // runs, so a subprocess here would be a subprocess per volume per sync,
        // indefinitely — the very cost this work argued was too high to pay for
        // reporting the size in the first place. The cache is authoritative
        // because every write path records the size it produced; the probe
        // behind it fires once per volume, not once per attempt.
        guard let current = await volumeVirtualSize(volumeId: item.id, attachment: disk) else {
            // Blocked rather than transient: an image whose size cannot be read
            // is not one to grow on a guess, and this is how the refusal
            // reaches an operator instead of the item running no steps and
            // recording the generation as converged.
            throw VolumeConvergenceError.blocked(
                "cannot read the current size of volume \(item.id), so its size cannot be converged; "
                    + "check the backing image with its storage client")
        }
        guard desired.sizeBytes >= current else {
            // Shrinking a disk image truncates the guest's filesystem. There is
            // no retry that makes this safe, so it is permanent: the control
            // plane surfaces it as a degraded volume instead of a convergence
            // that quietly never finishes.
            throw VolumeConvergenceError.unsupported(
                "refusing to shrink volume \(item.id) from \(current) to \(desired.sizeBytes) bytes")
        }
        if desired.sizeBytes > current {
            // Refuse to grow a volume some guest may still have open (STR-19).
            //
            // The only path here is `qemu-img resize`, and the only thing
            // between it and a live hypervisor is the image lock — which
            // `locking=auto` gives up on *quietly* wherever OFD locks do not
            // work, NFS being the case to worry about. There the resize would
            // not fail; it would rewrite qcow2 metadata underneath a running
            // guest. So the agent checks rather than trusting a property of
            // the filesystem, which is also what makes "the agent decides
            // online vs offline" true rather than aspirational: until there is
            // an online grow path, the agent's decision is *no*.
            //
            // Deliberately not `hasLiveSession`: that answers "does this
            // service track the VM", and it keeps tracking one that is shut
            // down — so it would refuse the offline grow of a stopped VM's
            // disk, which is precisely the case that is safe. Only a definite
            // `.shutdown` proceeds. A status this agent cannot read (no
            // service for the VM, an unreachable monitor, a re-adopted VM
            // whose process it has not claimed) refuses, because an
            // unanswerable question about a live guest is not a no.
            if let attachment = recordedVolumeAttachments()[item.id] {
                var isDefinitelyStopped = false
                if let service = getHypervisorServiceForVM(vmId: attachment.vmId),
                    let status = try? await service.getVMStatus(vmId: attachment.vmId)
                {
                    isDefinitelyStopped = status == .shutdown
                }
                // Blocked, not permanent (STR-199). The reason names a remedy —
                // stop the guest, or detach — and the whole point of naming one
                // is that applying it works: the block clears without anyone
                // re-asking for the size, so the refusal must not enter either
                // permanent suppression or transient backoff. Classified
                // permanent, this guard reported what to do
                // and then ignored an operator who did it, leaving a volume
                // permanently short of a size nothing had withdrawn.
                //
                // Still not transient: an operator has to see the reason, and a
                // transient failure would delay the next retry even after the
                // operator applied the remedy.
                guard isDefinitelyStopped else {
                    throw VolumeConvergenceError.blocked(
                        "refusing to grow volume \(item.id): it is attached to VM "
                            + "\(attachment.vmId), which is not confirmed shut down, and this agent "
                            + "has no online grow path")
                }
            }
            try await backend.resizeVolume(attachment: disk, newSizeBytes: desired.sizeBytes)
        }
        volumeSizes[item.id] = desired.sizeBytes
    }

    func volumeReconcileDelete(_ item: ReconcileWorkItem) async throws {
        let backend = try await requireStorageBackend(
            volumeId: item.id, desired: item.desiredVolume)
        // Unplug before removing the bytes, or a running guest keeps an open
        // handle on a file that no longer exists. Best effort: a VM that is
        // already gone leaves nothing to unplug.
        if let attachment = recordedVolumeAttachments()[item.id] {
            try? await detachVolumeFromVM(
                volumeId: item.id, vmId: attachment.vmId, deviceName: attachment.deviceName)
        }
        try await backend.deleteVolume(volumeId: item.id)
        volumeSizes.removeValue(forKey: item.id)
        logger.info("Volume removed from this host", metadata: ["volumeId": .string(item.id)])
    }

    func volumeReconcileAttach(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume, let attachment = desired.attachment else {
            throw VolumeConvergenceError.unsupported("volume attach requires a desired attachment")
        }
        let backend = try await requireStorageBackend(volumeId: item.id, desired: desired)
        guard let disk = try await backend.inspectVolume(volumeId: item.id) else {
            throw VolumeConvergenceError.sourceNotReady("volume \(item.id) is not present on this agent")
        }
        let vmId = attachment.vmId.uuidString
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else {
            // The VM has not been created on this host yet — only ever a race
            // against its own convergence, since the control plane never sends
            // an attachment for a VM placed elsewhere. Classified as a
            // dependency so it burns no attempt and produces no error the
            // control plane would show an operator.
            throw VolumeConvergenceError.sourceNotReady(
                "VM \(vmId) is not present on this agent yet")
        }
        if entry.hypervisorType == .qemu {
            try await backend.prepareAttachmentForQEMU(disk)
        }

        // Record first, then hot-plug. A crash in between leaves a recorded
        // attachment whose hot-plug the next sync re-drives (idempotently);
        // the other order would leave a plugged device nothing remembers, and
        // the guest would lose it at its next power cycle.
        let spec = VolumeSpec(
            volumeId: desired.volumeId,
            deviceName: attachment.deviceName,
            attachment: disk,
            readonly: attachment.readonly,
            bootOrder: attachment.bootOrder)
        let orderedBootVolumeIds = await recordVolumeAttachment(spec, onVM: vmId, entry: entry)

        // A VM with no hypervisor-side record yet (not created on this host,
        // or an orphan not yet re-adopted) needs no device call at all: the
        // record *is* the realization, because createVM builds the domain's
        // disk set from the manifest. (A defined-but-stopped libvirt domain
        // does not take this path — hasLiveSession resolves the domain and
        // attachDisk lands in its persistent definition.)
        guard let service = getHypervisorServiceForVM(vmId: vmId), await service.hasLiveSession(vmId: vmId) else {
            logger.info(
                "Recorded volume attachment for a VM with no live session; it lands at its next boot",
                metadata: ["volumeId": .string(item.id), "strato.vm.id": .string(vmId)])
            return
        }
        try await service.attachDisk(
            vmId: vmId, volumeId: item.id, attachment: disk,
            deviceName: attachment.deviceName.rawValue, readonly: attachment.readonly,
            orderedBootVolumeIds: orderedBootVolumeIds)
    }

    func volumeReconcileDetach(_ item: ReconcileWorkItem) async throws {
        guard let attachment = recordedVolumeAttachments()[item.id] else { return }
        try await detachVolumeFromVM(
            volumeId: item.id, vmId: attachment.vmId, deviceName: attachment.deviceName)
    }

    func detachVolumeFromVM(volumeId: String, vmId: String, deviceName: String) async throws {
        // Unplug first, then drop the record: the inverse order of attach, and
        // for the inverse reason. A crash between the two leaves a record for a
        // device that is already gone, which the next sync's detach clears
        // idempotently; dropping the record first would strand a plugged device
        // nothing describes.
        if let service = getHypervisorServiceForVM(vmId: vmId), await service.hasLiveSession(vmId: vmId) {
            try await service.detachDisk(vmId: vmId, volumeId: volumeId, deviceName: deviceName)
        }
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else { return }
        let remaining = entry.spec.volumes.filter { $0.volumeId.uuidString != volumeId }
        let updated = entry.with(spec: entry.spec.withVolumes(remaining))
        if managedVMs[vmId] != nil {
            managedVMs[vmId] = updated
        } else {
            orphanedVMs[vmId] = updated
        }
        persistManifest()
    }

    /// Writes an attachment into the VM's manifest entry, so it survives an
    /// agent restart (which reloads the manifest), and returns the complete
    /// sorted set of explicitly ordered volume ids. The libvirt driver uses
    /// that sequence to rewrite dense persistent boot orders after the device's
    /// `affectLiveAndConfig` attach has landed.
    func recordVolumeAttachment(
        _ spec: VolumeSpec, onVM vmId: String, entry: VMManifestEntry
    ) async -> [String] {
        var volumes = entry.spec.volumes.filter { $0.volumeId != spec.volumeId }
        volumes.append(spec)
        volumes.sort { lhs, rhs in
            let left = (lhs.bootOrder ?? Int.max, lhs.deviceName.rawValue, lhs.volumeId.uuidString)
            let right = (rhs.bootOrder ?? Int.max, rhs.deviceName.rawValue, rhs.volumeId.uuidString)
            return left < right
        }
        let updated = entry.with(spec: entry.spec.withVolumes(volumes))
        if managedVMs[vmId] != nil {
            managedVMs[vmId] = updated
        } else {
            orphanedVMs[vmId] = updated
        }
        persistManifest()
        return volumes.compactMap { volume in
            volume.bootOrder == nil ? nil : volume.volumeId.uuidString
        }
    }

    func reconcileService(for vmId: String) throws -> any HypervisorService {
        guard let service = getHypervisorServiceForVM(vmId: vmId) else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        return service
    }

    /// Resolve every managed volume identity against this agent's own storage
    /// inventory before a hypervisor sees the VM spec. A sync may arrive before
    /// image materialization finishes, so absence is a retryable dependency;
    /// retaining a nil or control-plane-stale attachment would recreate the legacy
    /// path-only boot behavior this contract replaces.
    func specWithRealizedVolumeAttachments(
        _ spec: VMSpec, vmId: String, hypervisorType: HypervisorType
    ) async throws -> VMSpec {
        var volumes: [VolumeSpec] = []
        for volume in spec.volumes {
            let volumeId = volume.volumeId.uuidString
            guard let desired = desiredVolumeStates[volumeId] else {
                throw VolumeConvergenceError.sourceNotReady(
                    "managed volume \(volumeId) for VM \(vmId) has no desired storage configuration")
            }
            let backend = try await requireStorageBackend(volumeId: volumeId, desired: desired)
            guard let disk = try await backend.inspectVolume(volumeId: volumeId) else {
                throw VolumeConvergenceError.sourceNotReady(
                    "managed volume \(volumeId) for VM \(vmId) is not present on this agent yet")
            }
            if hypervisorType == .qemu {
                try await backend.prepareAttachmentForQEMU(disk)
            }
            volumes.append(
                VolumeSpec(
                    volumeId: volume.volumeId,
                    deviceName: volume.deviceName,
                    attachment: disk,
                    readonly: volume.readonly,
                    bootOrder: volume.bootOrder,
                    ioLimits: volume.ioLimits))
        }
        return spec.withVolumes(volumes)
    }

    func prepareQEMUStorageAttachments(_ spec: VMSpec) async throws {
        for volume in spec.volumes {
            guard let attachment = volume.attachment else { continue }
            let volumeId = volume.volumeId.uuidString
            let backend = try await requireStorageBackend(
                volumeId: volumeId, desired: desiredVolumeStates[volumeId])
            try await backend.prepareAttachmentForQEMU(attachment)
        }
    }

    func reconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired else {
            throw HypervisorServiceError.invalidConfiguration("create work item without a desired entry")
        }
        guard let service = getHypervisorService(for: desired.hypervisorType) else {
            throw HypervisorServiceError.hypervisorNotInstalled(desired.hypervisorType.rawValue)
        }
        let realizedSpec = try await specWithRealizedVolumeAttachments(
            desired.spec, vmId: item.id, hypervisorType: desired.hypervisorType)
        let creationMetadata = await metadataForHypervisorCreate(desired)

        let currentEntry = managedVMs[item.id] ?? orphanedVMs[item.id]
        let currentReservation =
            currentEntry.map {
                VMHostReservation.forManifestEntry($0, architecture: .current)
            } ?? HostReservation()
        let desiredReservation = VMHostReservation.forSpec(
            realizedSpec, hypervisorType: desired.hypervisorType, architecture: .current)
        let raw = await rawHostCapacitySnapshot()
        let claim = try capacityAdmissionLedger.claim(
            .positiveDelta(from: currentReservation, to: desiredReservation),
            desiredWorkloadReservation: desiredReservation,
            snapshot: raw, agentName: initialAgentID)
        defer { capacityAdmissionLedger.release(claim) }

        // The VM's host-global vsock context ID (STR-72), taken before the
        // driver runs and — like the NICs below — given back if the driver
        // never created the VM. Exhaustion fails the create rather than reusing
        // a CID, since a second guest on one CID is an isolation failure, not a
        // degraded VM. Only a QEMU VM opted into Strato's guest agent consumes
        // this namespace; Firecracker's UDS-backed device is process-local.
        //
        // The durable record is written *after* the driver succeeds, so a crash
        // in that window leaves a guest whose CID no manifest entry records.
        // That is the pre-existing shape of this path — the same crash loses
        // the whole entry, not just the CID — and it is left as it is
        // deliberately: claiming the workload before it exists would have the
        // manifest reserve capacity and block re-creates for a VM that may
        // never have been created. It fails safe rather than silently, because
        // the CID is the one field with no deterministic derivation to fall
        // back on: the kernel refuses a duplicate CID (`EADDRINUSE`), so a
        // later VM handed the orphaned CID fails to start instead of joining
        // the surviving guest's channel.
        let lease = try vsockCIDs.lease(
            for: item.id,
            needsHostCID: desired.hypervisorType.usesHostVsockNamespace
                && realizedSpec.guestAgentEnabled)

        // The orchestrator realizes the VM's NICs on this host before the
        // driver runs, and rolls them back if the driver never created the VM.
        let attachments: [ResolvedNetworkAttachment]
        do {
            attachments = try await networkOrchestrator.prepareAttachments(
                vmId: item.id, networks: realizedSpec.networks,
                metadataDenied: creationMetadata.map { !$0.isServiceEnabled } ?? false)
        } catch {
            vsockCIDs.rollBack(lease)
            throw error
        }
        do {
            try await service.createVM(
                vmId: item.id, spec: realizedSpec, imageInfo: desired.imageInfo,
                networkAttachments: attachments,
                metadata: creationMetadata,
                vsockCID: lease.cid)
        } catch {
            await networkOrchestrator.teardownAttachments(
                vmId: item.id, networks: realizedSpec.networks)
            vsockCIDs.rollBack(lease)
            throw error
        }

        // An existing edge record survives the rewrite. This path is reached for
        // a genuinely new VM (where there is none, and `recordAppliedEdges`
        // writes the first one right after) *and* for an orphan whose hypervisor
        // process turned out to be gone — where dropping it would read as "no
        // record" next sync and quietly discard a restore the user asked for.
        //
        // A workload that arrives on a *different* host has no record here to
        // carry, so it adopts its nonces rather than applying them: a pending
        // restore issued before the move is dropped. For a VM that is right —
        // the checkpoint lives inside the disks that did not move — and a
        // sandbox's placement is pinned today, so it is unreachable rather than
        // merely rare. It stops being unreachable the day a sandbox can move
        // with a restore outstanding.
        let appliedEdges = (managedVMs[item.id] ?? orphanedVMs[item.id])?.appliedEdges
        let firecrackerMMDSInterfaces: [String]? =
            desired.hypervisorType == .firecracker
            ? FirecrackerMMDSInterfacePlan.interfaceIDs(
                for: attachments,
                metadataServiceEnabled: creationMetadata?.isServiceEnabled ?? false)
            : nil
        managedVMs[item.id] = VMManifestEntry(
            hypervisorType: desired.hypervisorType, spec: realizedSpec,
            realizedMemoryReservationBytes: desired.hypervisorType == .qemu
                ? desiredReservation.memoryBytes : nil,
            vsockCID: lease.cid,
            appliedEdges: appliedEdges,
            firecrackerMMDSPolicyApplied: desired.hypervisorType == .firecracker ? true : nil,
            firecrackerMMDSInterfaces: firecrackerMMDSInterfaces)
        orphanedVMs.removeValue(forKey: item.id)
        persistManifest()
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .statusChange,
            message: "VM created by reconciliation", operation: "create")
    }

    /// Firecracker seeds MMDS from the same generation-guarded record used by
    /// refreshes. Other backends keep the desired entry's value because their
    /// create-time bootstrap contract is independent of MMDS.
    func metadataForHypervisorCreate(
        _ desired: DesiredVMState
    ) async -> InstanceMetadata? {
        guard desired.hypervisorType == .firecracker else { return desired.metadata }
        guard metadataServiceEnabled else { return nil }
        return await metadataStore.metadata(for: desired.vmId)
    }

    /// Applies a VM's new vCPU/memory sizing (issue #568) and records it in the
    /// manifest, so the next sync diffs against what the VM is now running with
    /// or, for a stopped VM, what its persistent definition will boot with.
    ///
    /// The manifest write happens only after the driver reports success:
    /// recording the new sizing first would make a failed resize look applied
    /// and silently strand the VM at its old size.
    func reconcileResize(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired else {
            throw HypervisorServiceError.invalidConfiguration("resize work item without a desired entry")
        }
        guard let entry = managedVMs[item.id] else {
            throw HypervisorServiceError.vmNotFound(item.id)
        }
        let currentReservation = VMHostReservation.forManifestEntry(
            entry, architecture: .current)
        let desiredReservation = VMHostReservation.forSpec(
            desired.spec, hypervisorType: desired.hypervisorType, architecture: .current)
        let bootClaim = bootCapacityClaims.removeValue(forKey: item.id)
        let claim: HostCapacityClaim?
        if let bootClaim {
            claim = bootClaim
        } else {
            let raw = await rawHostCapacitySnapshot()
            claim = try capacityAdmissionLedger.claim(
                .positiveDelta(from: currentReservation, to: desiredReservation),
                desiredWorkloadReservation: desiredReservation,
                snapshot: raw, agentName: initialAgentID)
        }
        defer { capacityAdmissionLedger.release(claim) }
        let service = try reconcileService(for: item.id)

        // An offline vCPU shrink can share a mutation with a memory or vCPU
        // growth. Widen first, exactly as boot does, or `resizeVM` can apply the
        // shrink and then fail forever against the old memory/vCPU ceiling while
        // the planner keeps the boot that would widen it behind this step.
        let status = try await service.getVMStatus(vmId: item.id)
        if status == .shutdown || status == .created {
            try await service.redefineVM(vmId: item.id, spec: desired.spec)
            if entry.hypervisorType == .qemu,
                desiredReservation.memoryBytes > currentReservation.memoryBytes
            {
                managedVMs[item.id] = entry.reservingMemory(
                    atLeast: desiredReservation.memoryBytes)
                // The persistent definition is already wider even if the
                // sizing write below fails, so its reservation is durable now.
                persistManifest()
            }
        }
        try await service.resizeVM(vmId: item.id, spec: desired.spec)

        let preparedEntry = managedVMs[item.id] ?? entry
        managedVMs[item.id] = preparedEntry.with(
            spec: preparedEntry.spec.withSizing(from: desired.spec))
        persistManifest()
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "VM resized to \(desired.spec.cpus) vCPUs and \(desired.spec.memoryBytes) bytes of memory",
            operation: "resize")
    }

    /// Converges the durable NIC manifest against desired state. A legacy
    /// manifest pairs by MAC and is hydrated with v40 identity fields without
    /// changing a device; array position is used only when neither side has an
    /// identity to match.
    func reconcileNetworks(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired else {
            throw HypervisorServiceError.invalidConfiguration(
                "network work item without a desired entry")
        }
        guard let entry = managedVMs[item.id] else {
            throw HypervisorServiceError.vmNotFound(item.id)
        }
        if entry.hypervisorType == .firecracker {
            try await reconcileFirecrackerMetadataInterfaces(
                item: item, desired: desired, entry: entry)
            return
        }
        guard entry.hypervisorType == .qemu else {
            throw HypervisorServiceError.notSupported(
                "VM network hot-plug is supported only for QEMU VMs")
        }

        let service = try reconcileService(for: item.id)
        let current = entry.spec.networks
        let target = desired.spec.networks
        let pairs = VMNetworkInterfaceDiff.between(current: current, desired: target)

        // A hot-added NIC is absent from the immutable cloud-init seed created
        // with the VM. DHCP is therefore the only guest L3 configuration path
        // available today. The API rejects this synchronously; keep the agent
        // defensive against legacy control planes and directly authored state.
        if let addedIndex = pairs.added.first(where: { !target[$0].dhcpEnabled }) {
            let spec = target[addedIndex]
            throw HypervisorServiceError.notSupported(
                "hot-plugging interface '\(spec.deviceName ?? "net\(spec.orderIndex ?? addedIndex)")' "
                    + "on DHCP-disabled network '\(spec.network)'; recreate the VM with this interface, "
                    + "or use a DHCP-enabled network")
        }

        let status = try await service.getVMStatus(vmId: item.id)
        if status != .running && status != .paused {
            // On an inactive domain, widen the stored PCIe root complex before
            // config-only device changes consume another slot.
            try await service.redefineVM(vmId: item.id, spec: desired.spec)
        }

        for oldIndex in pairs.removed {
            let spec = current[oldIndex]
            try await service.detachNetworkInterface(vmId: item.id, spec: spec)
            try await networkOrchestrator.removeAttachment(
                vmId: item.id, spec: spec, fallbackIndex: oldIndex)
        }

        for newIndex in pairs.added {
            let spec = target[newIndex]
            let attachment = try await networkOrchestrator.prepareAttachment(
                vmId: item.id,
                spec: spec,
                fallbackIndex: newIndex,
                metadataDenied: desired.metadata.map { !$0.isServiceEnabled } ?? false)
            do {
                try await service.attachNetworkInterface(
                    vmId: item.id, spec: spec, attachment: attachment)
            } catch {
                await networkOrchestrator.teardownAttachments(
                    vmId: item.id, networks: [spec])
                throw error
            }
        }

        // Identity hydration and every add/remove become durable only after
        // the complete operation succeeds. A replay then observes libvirt's
        // already-present/absent result and finishes any interrupted cleanup.
        managedVMs[item.id] = entry.with(spec: entry.spec.withNetworks(target))
        persistManifest()
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "VM network interfaces reconciled", operation: "network-hotplug")
    }

    /// Firecracker's MMDS allow-list is immutable after boot. Rebuild only the
    /// VMM process against the existing disks and TAPs, then let the remaining
    /// reconcile steps boot (and optionally pause) the replacement.
    func reconcileFirecrackerMetadataInterfaces(
        item: ReconcileWorkItem, desired: DesiredVMState, entry: VMManifestEntry
    ) async throws {
        let service = try reconcileService(for: item.id)
        let realization = try await replaceFirecrackerMMDSPolicy(
            item: item, desired: desired, entry: entry, service: service)

        managedVMs[item.id] = entry.with(spec: realization.spec)
            .applyingFirecrackerMMDSPolicy(interfaces: realization.interfaces)
        persistManifest()
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "Firecracker VM recreated to apply metadata interface policy",
            operation: "metadata-network-reconfigure")
    }

    /// Creates a stopped replacement VMM with the desired pre-boot MMDS
    /// allow-list. Manifest ownership stays with the caller so adoption can
    /// retain its orphan record until the replacement succeeds.
    func replaceFirecrackerMMDSPolicy(
        item: ReconcileWorkItem, desired: DesiredVMState, entry: VMManifestEntry,
        service: any HypervisorService
    ) async throws -> (spec: VMSpec, interfaces: [String]) {
        let targetSpec = entry.spec.withNetworks(desired.spec.networks)
        let realizedSpec = try await specWithRealizedVolumeAttachments(
            targetSpec, vmId: item.id, hypervisorType: .firecracker)
        let metadata = await metadataForHypervisorCreate(desired)

        // These TAPs already exist. Reassert each attachment individually so a
        // failure does not run create-time rollback and tear down the live set;
        // the VMM is replaced only after every attachment resolved.
        var attachments: [ResolvedNetworkAttachment] = []
        attachments.reserveCapacity(realizedSpec.networks.count)
        for (index, network) in realizedSpec.networks.enumerated() {
            attachments.append(
                try await networkOrchestrator.prepareAttachment(
                    vmId: item.id, spec: network, fallbackIndex: index,
                    metadataDenied: metadata.map { !$0.isServiceEnabled } ?? false))
        }

        try await service.reconfigureMetadataInterfaces(
            vmId: item.id, spec: realizedSpec, imageInfo: desired.imageInfo,
            networkAttachments: attachments, metadata: metadata)
        return (
            realizedSpec,
            FirecrackerMMDSInterfacePlan.interfaceIDs(
                for: attachments,
                metadataServiceEnabled: metadata?.isServiceEnabled ?? false)
        )
    }

    /// Re-adopts an orphan that is being deleted, classifying a failure by
    /// whether it says the hypervisor process is gone (`OrphanDeleteAdoption`).
    /// The distinction is the whole point: `try?` here discarded it, and the
    /// resulting delete could never tell a VM whose process is gone (reclaim
    /// its directory) from a live one this agent cannot reach (leave it alone).
    func adoptOrphanForDelete(
        vmId: String, entry: VMManifestEntry, service: (any HypervisorService)?
    ) async -> OrphanDeleteAdoption {
        guard let service else { return .indeterminate }
        do {
            _ = try await service.adoptVM(vmId: vmId, spec: entry.spec)
            return .adopted
        } catch {
            let adoption = OrphanDeleteAdoption.classify(adoptionFailure: error)
            logger.log(
                level: adoption == .processGone ? .info : .warning,
                "Could not re-adopt an orphaned VM to delete it",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "adoption": .string(String(describing: adoption)),
                    "error": .string(error.localizedDescription),
                ])
            return adoption
        }
    }

    func reconcileDelete(_ item: ReconcileWorkItem) async throws {
        // Orphan with no live session: try to re-adopt first so the surviving
        // hypervisor process is actually torn down instead of leaking. If the
        // session cannot be reattached, fall back to releasing the manifest
        // entry, reclaiming as much as the failure proves is safe to reclaim.
        if managedVMs[item.id] == nil, let entry = orphanedVMs[item.id] {
            let service = getHypervisorService(for: entry.hypervisorType)
            let adoption = await adoptOrphanForDelete(vmId: item.id, entry: entry, service: service)
            switch adoption {
            case .adopted:
                managedVMs[item.id] = entry

            case .processGone, .indeterminate:
                // Reclaim before releasing the manifest entry, not after: that
                // entry is the only record on this host that the VM was ever
                // here, so a crash between the two must leave the record
                // standing rather than the files (STR-179). A replayed delete
                // re-reclaims harmlessly. `reclaimVMDirectory` reports its own
                // outcome — success and failure both — so nothing is claimed
                // about the removal here.
                if adoption == .processGone, let service {
                    // Nothing is running from this VM's disks, so its whole
                    // directory — boot disk included — goes with it. A
                    // Firecracker adoption acquired the durable krbd mapping,
                    // so use its throwing delete path before forgetting it.
                    if entry.hypervisorType == .firecracker {
                        try await service.deleteVM(vmId: item.id)
                    } else {
                        await service.reclaimVMDirectory(vmId: item.id)
                    }
                } else {
                    logger.warning(
                        "Deleting an orphaned VM this agent could not re-adopt; any surviving hypervisor process and the VM's files must be cleaned up manually",
                        metadata: ["strato.vm.id": .string(item.id)])
                }

                orphanedVMs.removeValue(forKey: item.id)
                releaseVsockCID(item.id)
                persistManifest()
                // Host-side network resources are derived from deterministic
                // names, so they can be torn down even with no live session.
                await networkOrchestrator.teardownAttachments(
                    vmId: item.id, networks: entry.spec.networks)
                return
            }
        }

        guard let entry = managedVMs[item.id] else {
            // Already absent — deletion is idempotent. The CID is still
            // released: no manifest entry refers to this VM, so anything the
            // allocator still holds for it (a create that failed after taking
            // one, an orphan reaped by the branch above) is a leak.
            releaseVsockCID(item.id)
            return
        }
        let service = try reconcileService(for: item.id)

        // Stop gracefully first when the VM is actually running; deleting a
        // resting VM skips straight to teardown.
        let status = (try? await service.getVMStatus(vmId: item.id)) ?? .unknown
        if status == .running || status == .paused {
            try await service.stopAndDeleteVM(vmId: item.id)
        } else {
            try await service.deleteVM(vmId: item.id)
        }

        // Tear down the VM's host-side network resources now that the
        // hypervisor session is gone (best-effort; never blocks deletion).
        await networkOrchestrator.teardownAttachments(
            vmId: item.id, networks: entry.spec.networks)

        managedVMs.removeValue(forKey: item.id)
        orphanedVMs.removeValue(forKey: item.id)
        releaseVsockCID(item.id)
        persistManifest()
        await sendVMLog(
            vmId: item.id, level: .info, eventType: .operation,
            message: "VM deleted by reconciliation", operation: "delete")
    }
}
