import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns local checkpoint capture, restore, and deletion.
extension FirecrackerSandboxRuntime {
    // MARK: - Snapshots / checkpoint-resume (issue #426)

    /// Archive filenames inside a snapshot directory. `configImage` rides
    /// along (it is tiny) so a jailed restore can re-stage the chroot without
    /// depending on the live sandbox's staging surviving.
    enum SnapshotFile {
        static let memory = "memory.snap"
        static let vmstate = "vmstate.snap"
        static let rootfs = "rootfs.ext4"
        static let configImage = "config.img"
    }

    /// Host-owned archive directory for one snapshot. Lives under the
    /// sandbox's storage directory, so snapshot artifacts are removed with
    /// the sandbox (same-agent restore only in v1 — the volume-snapshot
    /// precedent).
    func snapshotDirectory(_ sandboxId: String, snapshotId: String) -> String {
        sandboxDirectory(sandboxId) + "/snapshots/" + snapshotId
    }

    func snapshotSandbox(
        sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode
    ) async throws -> SandboxSnapshotResult {
        guard !suspending.contains(sandboxId) else { throw SandboxRuntimeError.checkpointInProgress(sandboxId) }
        return try await captureSandboxSnapshot(sandboxId: sandboxId, snapshotId: snapshotId, mode: mode)
    }

    func captureSandboxSnapshot(
        sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode, internalArchive: Bool = false
    ) async throws -> SandboxSnapshotResult {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }

        let info = try await managed.manager.getInstanceInfo()
        guard info.state != .notStarted else {
            throw SandboxRuntimeError.notSnapshottable("the sandbox has never been booted")
        }
        // A warm-provisioned sandbox that has not launched yet is the same
        // lifecycle position as never-booted, even though its microVM sits
        // paused: the guest memory still carries the *template's* identity,
        // so a checkpoint taken now could never pass restore's identity
        // check. (The instance-state guard above cannot see this — a
        // pre-launch warm sandbox is `Paused`, exactly like a stopped one.)
        guard managed.warmHeldIdentity == nil else {
            throw SandboxRuntimeError.notSnapshottable(
                "the sandbox has never been booted (warm-provisioned, awaiting launch)")
        }

        // A running guest is queried immediately. A paused guest uses the
        // version learned during its last boot; after an agent restart that
        // value is unknown and checkpoint capture is refused until the sandbox
        // has resumed and verified the current contract.
        var guestControlProtocolVersion = managed.guestControlProtocolVersion
        if info.state == .running {
            let response = try await sendControl(
                .ping, udsPath: managed.vsockUdsPath, timeout: 10)
            guard
                identityMatches(
                    response, sandboxId: sandboxId, expectedNonce: managed.identityNonce)
            else {
                throw GuestControlError.identityMismatch(
                    expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(response)")
            }
            guestControlProtocolVersion = response.controlProtocolVersion
            sandboxes[sandboxId]?.guestControlProtocolVersion = guestControlProtocolVersion
        }
        guard let guestControlProtocolVersion else {
            throw SandboxRuntimeError.notSnapshottable(
                "the paused guest's control protocol version is unknown after agent restart; "
                    + "start the sandbox once to verify protocol "
                    + "\(SandboxGuestControlProtocol.currentVersion), then retry the checkpoint")
        }

        logger.info(
            "Checkpointing sandbox",
            metadata: [
                "strato.sandbox.id": .string(sandboxId),
                "snapshotId": .string(snapshotId),
                "mode": .string(mode.rawValue),
            ])

        // Stage the archive directory before touching the guest, so a
        // filesystem failure here cannot leave the sandbox paused.
        let archiveDir =
            internalArchive
            ? suspensionArchive(sandboxId: sandboxId, snapshotId: snapshotId)
            : snapshotDirectory(sandboxId, snapshotId: snapshotId)
        // A leftover from a failed earlier attempt must not pollute this one.
        try? FileManager.default.removeItem(atPath: archiveDir)
        try FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)

        // Drain host-side vsock connections first: Firecracker refuses to
        // snapshot a vsock device with live connections, and a paused guest
        // could not serve them anyway. Exec sessions end terminally; the log
        // follow keeps its seq state for the resume.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox checkpoint")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        let wasRunning = info.state == .running
        if wasRunning {
            do {
                try await managed.manager.pause()
            } catch {
                // Firecracker sends Pause to every vCPU before it waits for
                // their acknowledgements, but only changes GET / to Paused
                // after *all* replies arrive. A failed request can therefore
                // leave a subset paused while the VMM still reports Running.
                // Unconditionally send the idempotent Resumed transition to
                // every vCPU before surfacing the checkpoint failure (STR-205).
                await resumeAfterFailedPause(managed: managed, sandboxId: sandboxId)
                startLogFollow(sandboxId: sandboxId)
                throw error
            }
        }

        let archiveMemory = archiveDir + "/" + SnapshotFile.memory
        let archiveVmstate = archiveDir + "/" + SnapshotFile.vmstate
        let archiveRootfs = archiveDir + "/" + SnapshotFile.rootfs
        let archiveConfig = archiveDir + "/" + SnapshotFile.configImage

        do {
            try await captureSnapshot(
                manager: managed.manager, jail: managed.jail,
                memoryTarget: archiveMemory, vmstateTarget: archiveVmstate)

            // Copy the rootfs (and the tiny config drive, which a jailed
            // restore re-stages the chroot from) while the guest is still
            // paused, so disk and memory are one consistent point in time.
            // `cp --reflink=auto` makes this a free clone on filesystems that
            // support it and a full copy otherwise.
            try await reflinkCopy(from: managed.rootfsPath, to: archiveRootfs)
            try await reflinkCopy(from: managed.configPath, to: archiveConfig)

            // Local checkpoints need durability/integrity evidence before any
            // future STR-312 suspend can consume them. Hashing guest memory is
            // blocking I/O; keep it off this actor's cooperative executor.
            // This evidence is not a Firecracker restore-validation proof.
            _ = try await Task.detached {
                try SandboxCheckpointManifest.publish(
                    directory: archiveDir, sandboxId: sandboxId, snapshotId: snapshotId,
                    identityNonce: managed.identityNonce, firecrackerVersion: info.vmlinuxVersion,
                    guestControlProtocolVersion: guestControlProtocolVersion)
            }.value
        } catch {
            // Failed checkpoint: drop partial artifacts and put the guest
            // back the way it was found.
            try? FileManager.default.removeItem(atPath: archiveDir)
            if wasRunning {
                try? await managed.manager.resume()
                startLogFollow(sandboxId: sandboxId)
            }
            throw error
        }

        if mode == .resume, wasRunning {
            try await managed.manager.resume()
            startLogFollow(sandboxId: sandboxId)
        }
        // `mode == .stop` leaves the microVM paused — exactly the state a
        // control-plane stop produces, so the sandbox converges to `stopped`
        // and can later resume from this checkpoint via restore.

        let result = SandboxSnapshotResult(
            memorySizeBytes: fileSize(archiveMemory),
            vmstateSizeBytes: fileSize(archiveVmstate),
            rootfsSizeBytes: fileSize(archiveRootfs),
            storagePath: archiveDir,
            firecrackerVersion: info.vmlinuxVersion,
            guestControlProtocolVersion: guestControlProtocolVersion,
            forkLayoutVersion: managed.jail == nil ? nil : SandboxSnapshotForkLayout.currentVersion,
            cpuTemplate: managed.spec.cpuTemplate)
        logger.info(
            "Sandbox checkpoint complete",
            metadata: [
                "strato.sandbox.id": .string(sandboxId),
                "snapshotId": .string(snapshotId),
                "totalBytes": .stringConvertible(result.totalSizeBytes),
            ])
        return result
    }

    func restoreSandbox(
        sandboxId: String, snapshotId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        guard !suspending.contains(sandboxId) else { throw SandboxRuntimeError.checkpointInProgress(sandboxId) }
        try await restoreSandboxArchive(
            sandboxId: sandboxId, snapshotId: snapshotId, artifacts: artifacts,
            networkAttachments: networkAttachments)
    }

    func restoreSandbox(
        sandboxId: String, snapshotId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]?, networkAttachments: [ResolvedNetworkAttachment],
        expectedGeneration: Int64
    ) async throws {
        guard !suspending.contains(sandboxId) else { throw SandboxRuntimeError.checkpointInProgress(sandboxId) }
        try await restoreSandboxArchive(
            sandboxId: sandboxId, snapshotId: snapshotId, artifacts: artifacts,
            networkAttachments: networkAttachments, expectedGeneration: expectedGeneration)
    }

    func restoreSandboxArchive(
        sandboxId: String, snapshotId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]?,
        networkAttachments: [ResolvedNetworkAttachment], internalArchive: Bool = false,
        expectedGeneration: Int64? = nil
    ) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }
        let currentSuspension = try loadSuspensionRecord(sandboxId: sandboxId)
        let suspensionManagedRestore = internalArchive || currentSuspension != nil
        let resumeGeneration: Int64? =
            suspensionManagedRestore
            ? try suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].resumeGeneration(
                expected: expectedGeneration, allowRacedActivity: internalArchive)
            : nil

        // The reconciler re-realized this sandbox's NIC (idempotently) before
        // calling, so the netns, veth, TAP, tc filters and OVS port are all in
        // place before the guest resumes and starts transmitting. Record what
        // it produced: `adoptSandbox` cannot recover the attachment, so for an
        // adopted sandbox this is the first time the runtime learns it.
        //
        // A restore *in place* keeps the sandbox's identity, and the TAP name
        // is derived from that id, so the checkpoint already names the right
        // device — the override is redundant reinforcement, and deliberately
        // omitted on a Firecracker that would reject it (see
        // `networkOverrides`).
        if !networkAttachments.isEmpty {
            sandboxes[sandboxId]?.networkAttachments = networkAttachments
        }
        let overrides = await optionalNetworkOverrides(forTAP: try sandboxTAPName(networkAttachments))

        // Resolve the archive: local artifacts when this host took the
        // snapshot, otherwise a verified download of the exported copy
        // (issue #428). Either way every required file exists before the
        // live VM is destroyed, not after.
        let archiveDir =
            internalArchive
            ? suspensionArchive(sandboxId: sandboxId, snapshotId: snapshotId)
            : try await stageSnapshotArchive(
                sourceSandboxId: sandboxId, snapshotId: snapshotId, artifacts: artifacts)
        let archiveMemory = archiveDir + "/" + SnapshotFile.memory
        let archiveVmstate = archiveDir + "/" + SnapshotFile.vmstate
        let archiveRootfs = archiveDir + "/" + SnapshotFile.rootfs
        let archiveConfig = archiveDir + "/" + SnapshotFile.configImage

        // Validate the archived config before replacing the live microVM. This
        // catches schema-v1 checkpoints while the current sandbox is intact.
        let archivedConfig = try SandboxConfigDrive.decode(
            fromBlockImage: Data(contentsOf: URL(fileURLWithPath: archiveConfig)))
        guard archivedConfig.sandboxId == sandboxId else {
            throw GuestControlError.identityMismatch(
                expected: sandboxId, got: archivedConfig.sandboxId)
        }
        _ = try await Task.detached {
            try SandboxCheckpointManifest.verifyIfPresent(
                directory: archiveDir, sandboxId: sandboxId, snapshotId: snapshotId,
                identityNonce: archivedConfig.identityNonce)
        }.value
        if !internalArchive, var record = currentSuspension {
            record.phase = .restoring
            try saveSuspension(record)
        }

        logger.info(
            "Restoring sandbox from snapshot",
            metadata: ["strato.sandbox.id": .string(sandboxId), "snapshotId": .string(snapshotId)])

        // The current guest is about to be replaced wholesale.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox restore")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        // Tear down the current Firecracker process. For a jailed sandbox
        // this removes the whole chroot subtree, which the staging below
        // rebuilds from the archive.
        // The client's process-identity checks and bounded exit wait are the
        // teardown proof. Never stage or spawn a replacement when they fail.
        do {
            try await client.destroyVM(vmId: sandboxId)
        } catch FirecrackerError.vmNotFound {
            // A retry after failed staging can have no registered VMM. That
            // is not itself process-death evidence: scan both the id and the
            // recorded jail identity before permitting a replacement.
            try await confirmNoSandboxProcessBeforeReportingGone(
                sandboxId, jailUID: managed.jail?.uid)
        }

        let newManager: FirecrackerManager
        if let plan = managed.jail {
            // Re-stage the jail exactly as at snapshot time. The kernel and
            // initramfs are deliberately absent: a snapshot load restores
            // guest memory directly and never reads the boot source.
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            let rootfsHost = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: archiveRootfs, to: rootfsHost)
            let configHost = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try await reflinkCopy(from: archiveConfig, to: configHost)
            let snapshotDirHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try FileManager.default.createDirectory(
                atPath: snapshotDirHost, withIntermediateDirectories: true)
            try await reflinkCopy(
                from: archiveMemory,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail))
            try await reflinkCopy(
                from: archiveVmstate,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail))
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", rootfsHost, configHost, snapshotDirHost,
                plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            // The namespace usually survives the old process; recreate for a
            // crash-swept host (reused when it exists).
            try await createNetns(plan.netnsName)

            newManager = try await client.restoreVM(
                vmId: sandboxId,
                jail: makeJailerOptions(plan: plan, guestMemoryBytes: managed.spec.memoryBytes),
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    resumeVM: !suspensionManagedRestore,
                    networkOverrides: overrides))
        } else {
            // Unjailed: replace the live rootfs with the checkpointed copy
            // and load memory/vmstate straight from the archive (Firecracker
            // only reads the memory file for a file-backed load).
            try? FileManager.default.removeItem(atPath: managed.rootfsPath)
            try await reflinkCopy(from: archiveRootfs, to: managed.rootfsPath)
            if !FileManager.default.fileExists(atPath: managed.configPath) {
                try await reflinkCopy(from: archiveConfig, to: managed.configPath)
            }
            // The restored vsock device re-binds the deterministic UDS; a
            // stale file from the old process would make that bind fail.
            try? FileManager.default.removeItem(atPath: managed.vsockUdsPath)
            newManager = try await client.restoreVM(
                vmId: sandboxId, jail: nil,
                snapshot: SnapshotLoadConfig(
                    snapshotPath: archiveVmstate,
                    memFilePath: archiveMemory,
                    resumeVM: !suspensionManagedRestore,
                    networkOverrides: overrides))
        }

        sandboxes[sandboxId]?.manager = newManager
        // Whatever exit the pre-restore guest reported no longer describes
        // this guest; the restored one re-reports over vsock.
        sandboxes[sandboxId]?.lastExitCode = nil

        if suspensionManagedRestore {
            guard var record = try loadSuspensionRecord(sandboxId: sandboxId) else {
                throw SandboxSuspensionGuard.GateError.stale
            }
            // After this durable commit the guest may have advanced. A timeout
            // or failed health check must never rewind it to the checkpoint.
            try Task.checkCancellation()
            guard let resumeGeneration else { throw SandboxSuspensionGuard.GateError.stale }
            try suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].validateResumeGeneration(resumeGeneration)
            record.phase = .resuming
            try saveSuspension(record)
            try await newManager.resume()
        }

        // Health check: the restored guest must answer with this sandbox's
        // identity (the checkpointed memory carries the original nonce).
        let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
        guard identityMatches(response, sandboxId: sandboxId, expectedNonce: managed.identityNonce) else {
            throw GuestControlError.identityMismatch(
                expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(response)")
        }
        sandboxes[sandboxId]?.guestControlProtocolVersion = response.controlProtocolVersion
        if !internalArchive, var record = try loadSuspensionRecord(sandboxId: sandboxId) {
            record.phase = .resumed
            record.lastRestoreFailure = nil
            try saveSuspension(record)
        }

        // Best-effort clock resync: the restored guest's wall clock froze at
        // checkpoint time.
        await resyncGuestClock(sandboxId: sandboxId, udsPath: managed.vsockUdsPath)

        startLogFollow(sandboxId: sandboxId)
        logger.info(
            "Sandbox restored from snapshot",
            metadata: ["strato.sandbox.id": .string(sandboxId), "snapshotId": .string(snapshotId)])
    }

    func deleteSandboxSnapshot(sandboxId: String, snapshotId: String) async throws {
        // Independent of the microVM's state, and deliberately no managed
        // guard: cleanup must work for snapshots whose sandbox this runtime
        // never tracked (crash leftovers). Idempotent — a missing directory
        // confirms cleanly — but a real removal failure (permissions, I/O)
        // must surface: the control plane releases the storage charge on
        // this response, and a silent failure would strand real bytes
        // unaccounted.
        let directory = snapshotDirectory(sandboxId, snapshotId: snapshotId)
        if FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.removeItem(atPath: directory)
            } catch {
                throw SandboxRuntimeError.snapshotIOFailed(
                    "removing snapshot artifacts at \(directory) failed: \(error.localizedDescription)")
            }
        }
        // Any imported copy of the same snapshot goes too (a fork of it may
        // have run here); best-effort — the import cache is a re-downloadable
        // cache with its own LRU, unlike the accounted archive above.
        try? FileManager.default.removeItem(atPath: snapshotImportDirectory(snapshotId))
        logger.info(
            "Sandbox snapshot deleted",
            metadata: ["strato.sandbox.id": .string(sandboxId), "snapshotId": .string(snapshotId)])
    }
}

#endif
