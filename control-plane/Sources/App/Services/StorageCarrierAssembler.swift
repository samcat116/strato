import Fluent
import Foundation
import Metrics
import SQLKit
import StratoShared
import Vapor

extension DesiredStateAssembler {
    /// Every snapshot artifact this agent holds, as desired entries (STR-150).
    ///
    /// Three queries into one kind-tagged list, because that is the shape the
    /// agent's reconciler wants: one inventory to diff, with the entry's own
    /// `kind` routing the capture or the delete to a backend.
    ///
    /// Like volumes, nothing here carries a path or a size. The agent owns
    /// artifact layout and is the only party that can measure what it wrote, so
    /// both travel the other way, on the observed report.
    func desiredSnapshots(agentId: String, on db: any Database) async throws
        -> [DesiredSnapshotState]
    {
        var entries: [DesiredSnapshotState] = []

        let volumeSnapshots = try await VolumeSnapshot.placed(onAgent: agentId, on: db)
        // One query for every parent volume's current attachment rather than
        // one per snapshot: assembly runs on every poll of every agent, so an
        // N+1 here is a per-sync cost that grows with the host's snapshot count.
        var attachedVMIds: [UUID: UUID] = [:]
        var snapshotVolumeStorage: [UUID: DesiredVolumeStorage] = [:]
        if !volumeSnapshots.isEmpty {
            let volumeIDs = Set(volumeSnapshots.map(\.$volume.id))
            let parentVolumes = try await Volume.query(on: db)
                .filter(\.$id ~~ Array(volumeIDs)).all()
            snapshotVolumeStorage = try await desiredVolumeStorages(
                for: parentVolumes, on: db)
            for volume in parentVolumes {
                guard let volumeID = volume.id, let vmID = volume.$vm.id else { continue }
                attachedVMIds[volumeID] = vmID
            }
        }
        for snapshot in volumeSnapshots {
            guard let snapshotId = snapshot.id else { continue }
            guard let storage = snapshotVolumeStorage[snapshot.$volume.id] else {
                throw Abort(
                    .internalServerError,
                    reason: "Volume snapshot references a missing parent storage configuration")
            }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .volumeSnapshot,
                    parentId: snapshot.$volume.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation,
                    // The capture strategy, read by the agent only when the
                    // overlay does not exist yet. Naming the holder is what lets
                    // the agent refuse rather than write a snapshot that is not
                    // point-in-time (issue #747), even though the API refused
                    // the same thing at admission: a level-triggered entry
                    // outlives the request that made it, and the volume may have
                    // been attached since.
                    capture: DesiredSnapshotCapture(
                        attachedVMId: attachedVMIds[snapshot.$volume.id]),
                    volumeStorage: storage))
        }

        for snapshot in try await VMSnapshot.placed(onAgent: agentId, on: db) {
            guard let snapshotId = snapshot.id else { continue }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .vmCheckpoint,
                    parentId: snapshot.$vm.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation))
        }

        for snapshot in try await SandboxSnapshot.placed(onAgent: agentId, on: db) {
            guard let snapshotId = snapshot.id else { continue }
            // The export placement fact: "this snapshot should also exist in
            // the control plane's object store". Upload slots are
            // control-plane-relative paths presented with the agent's SVID, so
            // — like image downloads since v13 — nothing here expires and the
            // entry is safe to sit in a sync indefinitely.
            var export: DesiredSnapshotExport?
            if snapshot.exportDesired {
                export = DesiredSnapshotExport(
                    uploads: SandboxSnapshotArtifactKind.allCases.map { kind in
                        SandboxSnapshotArtifactUploadTarget(
                            kind: kind,
                            uploadURL: SandboxSnapshot.artifactTransferPath(
                                sandboxId: snapshot.$sandbox.id, snapshotId: snapshotId, kind: kind))
                    })
            }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .sandboxSnapshot,
                    parentId: snapshot.$sandbox.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation,
                    capture: DesiredSnapshotCapture(sandboxMode: snapshot.captureMode),
                    export: export))
        }

        return entries
    }

    /// Every volume placed on this agent, as desired entries (STR-148).
    ///
    /// It never carries a host path: the backend owns attachment realization
    /// and reports the canonical attachment back. Local ownership is expressed
    /// by replica scope; Ceph carries the external cluster coordinates and its
    /// write-only project credential because every eligible client can reach
    /// the same image.
    func desiredVolumes(agentId: String, on db: any Database) async throws -> [DesiredVolumeState] {
        let scopedVolumes = try await VolumeService.volumes(onAgent: agentId, on: db)
        let scopedVolumeIDs = scopedVolumes.compactMap(\.id)
        guard !scopedVolumeIDs.isEmpty else { return [] }
        let volumes = try await Volume.query(on: db)
            .filter(\.$id ~~ scopedVolumeIDs)
            .with(\.$sourceImage) { $0.with(\.$artifacts) }
            .all()
        let volumeStorages = try await desiredVolumeStorages(for: volumes, on: db)
        let attachedVMIDs = Array(Set(volumes.compactMap(\.$vm.id)))
        let attachmentVMs: [UUID: (agentId: String, hypervisorType: HypervisorType)]
        if attachedVMIDs.isEmpty {
            attachmentVMs = [:]
        } else {
            attachmentVMs = Dictionary(
                uniqueKeysWithValues: try await VM.query(on: db)
                    .filter(\.$id ~~ attachedVMIDs)
                    .all()
                    .compactMap { vm in
                        guard let vmID = vm.id, let vmAgentID = vm.hypervisorId else { return nil }
                        return (vmID, (vmAgentID, vm.hypervisorType))
                    })
        }
        let cloneSourceIDs = Array(Set(volumes.compactMap(\.$sourceVolume.id)))
        let cloneSourceVMIDs: [UUID: UUID]
        if cloneSourceIDs.isEmpty {
            cloneSourceVMIDs = [:]
        } else {
            cloneSourceVMIDs = Dictionary(
                uniqueKeysWithValues: try await Volume.query(on: db)
                    .filter(\.$id ~~ cloneSourceIDs)
                    .all()
                    .compactMap { source in
                        guard let sourceID = source.id, let sourceVMID = source.$vm.id else { return nil }
                        return (sourceID, sourceVMID)
                    })
        }

        var entries: [DesiredVolumeState] = []
        for volume in volumes {
            guard let volumeId = volume.id else { continue }

            // The create strategy, read by the agent only when it does not
            // already hold the volume. `sourceVolume` beats `sourceImage` when
            // both are set, because a clone's bytes come from the source volume
            // and its image lineage is only provenance.
            var source: DesiredVolumeSource?
            if let sourceVolumeID = volume.$sourceVolume.id {
                source = .clone(
                    from: sourceVolumeID,
                    sourceVMId: cloneSourceVMIDs[sourceVolumeID],
                    format: volume.format.rawValue)
            } else if let image = volume.sourceImage, image.status == .ready, let imageId = image.id {
                do {
                    let artifactKind: ArtifactKind =
                        volume.volumeType == .boot
                            && volume.$vm.id.flatMap { attachmentVMs[$0]?.hypervisorType } == .firecracker
                        ? .rootfs : .diskImage
                    source = .image(
                        try VMSpecBuilder.buildImageInfo(from: image),
                        artifactKind: artifactKind)
                    // Emitting the URLs is what authorizes the fetch, exactly as
                    // it does for a VM's boot image (issue #562). This grant
                    // moved here from the old create RPC's dispatch: with no
                    // dispatch left, assembly is the only place that knows which
                    // agent is about to be asked to download what.
                    await app.coordination.grantImageDownload(agentId: agentId, imageId: imageId)
                } catch {
                    app.logger.warning(
                        "Failed to build image info for a volume's desired state; syncing without it",
                        metadata: [
                            "volumeId": .string(volumeId.uuidString),
                            "imageId": .string(imageId.uuidString),
                            "error": .string(error.localizedDescription),
                        ])
                }
            } else if volume.$sourceImage.id != nil {
                app.logger.warning(
                    "Volume references an image that is missing or not ready; syncing without image info",
                    metadata: ["volumeId": .string(volumeId.uuidString)])
            }

            // Storage realization follows replica placement, but attachment
            // realization follows VM placement. Only the VM-hosting agent may
            // receive the attachment: every other replica receives the same
            // volume generation with `attachment: nil`, so it keeps its bytes
            // realized without trying to plug them into a VM it cannot host.
            // The attachment is otherwise projected from the same columns
            // `VMSpecBuilder.volumeSpecs` reads, so the two projections cannot
            // disagree.
            //
            // A name outside `VolumeDeviceName`'s charset cannot be stored (the
            // API validates it and the schema's check constraint plus unique
            // index hold the column to it), so the failed initializer below is
            // unreachable. `VMSpecBuilder.volumeSpecs` fails that VM's entry in
            // the same impossible case; here the volume lane must instead keep
            // the volume entry and omit only its attachment. An entry with no
            // attachment reads as *detach*, while dropping the entry entirely
            // reads as a volume this agent should not hold. An attachment the
            // agent would refuse is the worse of the three, so it is the one
            // not sent — loudly, because a row that reached this state is a
            // broken invariant, not a routine skip.
            var attachment: DesiredVolumeAttachment?
            if let vmID = volume.$vm.id,
                attachmentVMs[vmID]?.agentId == agentId,
                let raw = volume.deviceName
            {
                if let deviceName = VolumeDeviceName(raw) {
                    attachment = DesiredVolumeAttachment(
                        vmId: vmID, deviceName: deviceName, readonly: volume.readonly,
                        bootOrder: volume.bootOrder)
                } else {
                    app.logger.error(
                        "Volume stores a device name no hypervisor accepts; syncing it detached",
                        metadata: [
                            "volumeId": .string(volumeId.uuidString),
                            "deviceName": .string(raw),
                        ])
                }
            }

            entries.append(
                DesiredVolumeState(
                    volumeId: volumeId,
                    desiredStatus: volume.desiredStatus,
                    generation: volume.generation,
                    sizeBytes: volume.size,
                    format: volume.format.rawValue,
                    storage: volumeStorages[volumeId] ?? .local,
                    source: source,
                    attachment: attachment,
                    // Emitted whether or not the volume is attached: a ceiling
                    // is a property of the volume, latent while it is detached
                    // and realized by the attach. `Volume.ioLimits` normalizes,
                    // so an uncapped volume omits the field entirely.
                    ioLimits: volume.ioLimits))
        }
        return entries
    }

    /// Resolve the durable pool/access graph into the agent's write-only Ceph
    /// configuration. The encrypted keyring is decrypted only while building
    /// the mTLS desired-state message and is never copied into an API DTO or an
    /// observed disk attachment.
    func desiredVolumeStorages(
        for volumes: [Volume], on db: any Database
    ) async throws -> [UUID: DesiredVolumeStorage] {
        let poolIDs = Array(Set(volumes.compactMap(\.$pool.id)))
        let pools =
            poolIDs.isEmpty
            ? []
            : try await StoragePool.query(on: db)
                .filter(\.$id ~~ poolIDs).all()
        let poolsByID = Dictionary(
            uniqueKeysWithValues: pools.compactMap { pool in
                pool.id.map { ($0, pool) }
            })
        let cephPools = pools.filter { $0.mode == .ceph }
        let clusterIDs = Array(Set(cephPools.compactMap(\.$cephCluster.id)))
        let accessIDs = Array(Set(cephPools.compactMap(\.$cephProjectAccess.id)))
        let clusters =
            clusterIDs.isEmpty
            ? []
            : try await CephCluster.query(on: db)
                .filter(\.$id ~~ clusterIDs).all()
        let accesses =
            accessIDs.isEmpty
            ? []
            : try await CephProjectAccess.query(on: db)
                .filter(\.$id ~~ accessIDs).all()
        let clustersByID = Dictionary(
            uniqueKeysWithValues: clusters.compactMap { cluster in
                cluster.id.map { ($0, cluster) }
            })
        let accessesByID = Dictionary(
            uniqueKeysWithValues: accesses.compactMap { access in
                access.id.map { ($0, access) }
            })
        let secretIDs = Array(Set(accesses.map(\.$keyringSecret.id)))
        let secrets =
            secretIDs.isEmpty
            ? []
            : try await StoredSecret.query(on: db)
                .filter(\.$id ~~ secretIDs).all()
        let secretsByID = Dictionary(
            uniqueKeysWithValues: secrets.compactMap { secret in
                secret.id.map { ($0, secret) }
            })

        var result: [UUID: DesiredVolumeStorage] = [:]
        for volume in volumes {
            guard let volumeID = volume.id else { continue }
            guard let poolID = volume.$pool.id, let pool = poolsByID[poolID], pool.mode == .ceph else {
                result[volumeID] = .local
                continue
            }
            guard let clusterID = pool.$cephCluster.id,
                let accessID = pool.$cephProjectAccess.id,
                let cephPoolName = pool.cephPoolName,
                let namespace = pool.cephNamespace,
                let cluster = clustersByID[clusterID],
                let access = accessesByID[accessID],
                access.$cluster.id == clusterID,
                access.$project.id == volume.$project.id,
                let secret = secretsByID[access.$keyringSecret.id]
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Ceph volume has an incomplete or inconsistent storage pool")
            }
            result[volumeID] = .ceph(
                CephVolumeStorage(
                    clusterId: clusterID,
                    fsid: cluster.fsid,
                    pool: cephPoolName,
                    namespace: namespace,
                    clientName: access.clientName,
                    monEndpoints: cluster.monEndpoints,
                    // Runtime identity follows the secret version, not the
                    // stable project-access row. A rotated cephx key therefore
                    // receives a new deterministic libvirt/config identity and
                    // the retired UUID can remain in the revocation ledger.
                    credentialId: access.$keyringSecret.id,
                    keyring: try app.secretsEncryption.decrypt(secret.encryptedValue),
                    messengerMode: .secure))
        }
        return result
    }

    /// The teardowns this sync authorizes (STR-98).
    ///
    /// Every entry is the second half of a round trip: the agent reported
    /// holding a workload this assembly does not list, and
    /// `ObservedStateApplier` confirmed no row describes it. Nothing here is
    /// derived from the assembly's own queries, which is the point — a sync
    /// that under-lists an agent produces no tombstones at all, so a scoping
    /// bug can no longer authorize its own cleanup.
    func tombstones(agentId: String, on db: any Database) async throws
        -> [DesiredWorkloadTombstone]
    {
        try await AgentWorkloadClaim.query(on: db)
            .filter(\.$agentId == agentId)
            .filter(\.$disposition == .tombstoned)
            .all()
            .compactMap { claim in
                guard let generation = claim.tombstoneGeneration else { return nil }
                return DesiredWorkloadTombstone(
                    kind: claim.resourceKind.workloadKind,
                    workloadId: claim.resourceID,
                    generation: generation)
            }
            .sorted { $0.workloadId.uuidString < $1.workloadId.uuidString }
    }

    /// The agent self-update this sync should carry (issue #434): whatever
    /// version the agent row has been assigned — by the fleet rollout sweep or
    /// by an operator's "update now", which since STR-145 is the same field —
    /// with its artifact re-resolved on every assembly, so a long-assigned
    /// update never carries a stale (possibly presigned) link. An operator's
    /// explicit artifact override has no release to re-resolve from and rides
    /// the row instead.
    ///
    /// Deliberately keyed on the assignment rather than on `autoUpdate`:
    /// enrollment governs whether the *sweep* may assign this agent, not
    /// whether an assignment is delivered — and withdrawing enrollment clears
    /// the assignment anyway. Nil whenever there is nothing actionable: not
    /// assigned, already converged, or an artifact that cannot currently be
    /// resolved. Artifact lookup is best effort because the sync also carries
    /// workload state and must not fail when the release host is down.
    func desiredAgentUpdateForSync(agent: Agent?) async -> DesiredAgentUpdate? {
        guard let agent,
            let assigned = agent.updateDesiredVersion,
            AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned)
        else { return nil }

        if let override = agent.updateArtifactOverride {
            return DesiredAgentUpdate(
                targetVersion: assigned,
                artifactURL: override.url,
                sha256: override.sha256,
                artifactKind: override.kind,
                tarballMember: override.kind == .tarball ? override.tarballMember : nil
            )
        }

        guard let operatingSystem = agent.hostOperatingSystem,
            let architecture = agent.cpuArchitecture
        else { return nil }

        do {
            let artifact = try await app.agentArtifactResolver.resolve(
                version: assigned, operatingSystem: operatingSystem, architecture: architecture)
            return DesiredAgentUpdate(
                targetVersion: assigned,
                artifactURL: artifact.url,
                sha256: artifact.sha256,
                artifactKind: artifact.kind,
                tarballMember: artifact.kind == .tarball ? artifact.tarballMember : nil
            )
        } catch {
            app.logger.warning(
                "Could not resolve the agent update artifact for the sync; omitting it",
                metadata: [
                    "strato.agent.name": .string(agent.name),
                    "targetVersion": .string(assigned),
                    "error": .string(String(describing: error)),
                ])
            return nil
        }
    }

}
