import Foundation
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

extension FirecrackerSandboxRuntime {
    func suspensionValidationReservations() async throws -> [String: HostReservation] {
        let records = try validationProofStore.loadAll()
        let known = Set(records.map(\.proofId))
        // Legacy/unrecorded debris has unknown sizing. A successful crash sweep
        // must establish process death before any new capacity can be admitted.
        let names = try directoryContentsIfPresent(atPath: sandboxStoragePath)
        guard
            names.filter({ $0.hasPrefix("warm-template-suspend-proof-") })
                .allSatisfy({ known.contains($0) })
        else { throw SandboxSuspensionGuard.GateError.stale }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.proofId, $0.reservation) })
    }

    /// Retry only abandoned validation owners. Re-running the general warm
    /// template crash sweep here could kill a concurrently building template.
    func recoverAbandonedValidationProofs() async throws {
        if let task = validationProofRecoveryTask {
            try await task.value
            return
        }
        guard validationProofRecoveryPending else { return }
        let task = Task { try await self.sweepAbandonedValidationProofs() }
        validationProofRecoveryTask = task
        defer { validationProofRecoveryTask = nil }
        try await task.value
    }

    func sweepAbandonedValidationProofs() async throws {
        for record in try validationProofStore.loadAll() where !activeValidationProofs.contains(record.proofId) {
            let reservation = jailUIDs.reserve(record.jailUID, for: record.proofId)
            guard reservation != .notAssignable else { throw SandboxSuspensionGuard.GateError.stale }
            let plan = try jailPlan(for: record.proofId, recordedUID: record.jailUID)
            try await finishValidationProofCleanup(templateId: record.proofId) {
                try await destroyLeakedWarmTemplateProcess(record.proofId, plan: plan)
                try removeWarmTemplateArtifacts(record.proofId, plan: plan)
            }
            _ = jailUIDs.release(record.proofId)
        }
        // Another validation may have failed while cleanup was awaiting its
        // process proof. Recompute rather than erasing its pending recovery.
        validationProofRecoveryPending = try validationProofStore.loadAll().contains {
            !activeValidationProofs.contains($0.proofId)
        }
    }

    /// The cleanup closure must prove process death and remove its artifacts.
    /// Any failed proof keeps both durable capacity and restore ownership.
    func finishValidationProofCleanup(
        templateId: String, cleanup: () async throws -> Void
    ) async throws {
        try await cleanup()
        try releaseValidationProof(templateId: templateId)
    }

    func releaseValidationProof(templateId: String) throws {
        guard let record = try validationProofStore.loadAll().first(where: { $0.proofId == templateId }) else { return }
        try validationProofStore.remove(record.id)
        restoreAdmission.release(record.permit)
    }

    func suspensionStorageEstimate(sandboxId: String) async throws -> Int64 {
        guard let managed = sandboxes[sandboxId], managed.jail != nil else {
            throw SandboxRuntimeError.notSnapshottable("suspension requires a jailed sandbox")
        }
        var total = managed.spec.memoryBytes
        for path in [managed.rootfsPath, managed.configPath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
                throw SandboxCheckpointManifest.CheckpointError.invalidArtifact
            }
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { throw SandboxSuspensionGuard.GateError.stale }
            total = next
        }
        let (upper, overflow) = total.addingReportingOverflow(64 * 1024 * 1024)
        guard !overflow else { throw SandboxSuspensionGuard.GateError.stale }
        return upper
    }

    func resumeSuspension(sandboxId: String, networkAttachments: [ResolvedNetworkAttachment]) async throws {
        guard !suspending.contains(sandboxId) else { throw SandboxRuntimeError.checkpointInProgress(sandboxId) }
        sandboxes[sandboxId]?.networkAttachments = networkAttachments
        try await resumeSuspendedSandbox(sandboxId: sandboxId)
    }

    func resumeSuspension(sandboxId: String, networkAttachments: [ResolvedNetworkAttachment], expectedGeneration: Int64)
        async throws
    {
        guard !suspending.contains(sandboxId) else { throw SandboxRuntimeError.checkpointInProgress(sandboxId) }
        sandboxes[sandboxId]?.networkAttachments = networkAttachments
        try await resumeSuspendedSandbox(sandboxId: sandboxId, expectedGeneration: expectedGeneration)
    }

    func noteSandboxIntent(sandboxId: String, generation: Int64, desiredRunning: Bool) async {
        suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].updateIntent(
            generation: generation, desiredRunning: desiredRunning)
    }

    func suspensionArchive(sandboxId: String, snapshotId: String) -> String {
        sandboxDirectory(sandboxId) + "/hibernation/" + snapshotId
    }

    func suspensionRecord(sandboxId: String) async throws -> SandboxSuspensionRecord? {
        try loadSuspensionRecord(sandboxId: sandboxId)
    }

    func loadSuspensionRecord(sandboxId: String) throws -> SandboxSuspensionRecord? {
        if let record = suspensionRecords[sandboxId] { return record }
        guard let id = UUID(uuidString: sandboxId) else { throw SandboxSuspensionGuard.GateError.stale }
        let record = try suspensionStore.load(sandboxId: id)
        suspensionRecords[sandboxId] = record
        return record
    }

    func saveSuspension(_ record: SandboxSuspensionRecord) throws {
        try suspensionStore.save(record)
        suspensionRecords[record.sandboxId.uuidString] = record
    }

    func automaticFenceLifecycle() throws -> SandboxAutomaticSuspensionLifecycle {
        guard let transport = automaticSuspensionTransport else {
            throw SandboxRuntimeError.notSnapshottable("automatic suspension transport is not configured")
        }
        return SandboxAutomaticSuspensionLifecycle(store: suspensionStore, transport: transport)
    }

    func prepareAutomaticSuspensionFence(_ record: SandboxSuspensionRecord) async throws -> SandboxSuspensionRecord {
        suspensionRecords.removeValue(forKey: record.sandboxId.uuidString)
        let lifecycle = try automaticFenceLifecycle()
        let result = try await StageBudget.run(seconds: 20, stage: "automatic-suspension-prepare") {
            try await lifecycle.prepare(record)
        }
        suspensionRecords[result.sandboxId.uuidString] = result
        return result
    }

    /// Caller reaches this only after proving the same running guest identity.
    func releaseAutomaticSuspensionFence(_ record: SandboxSuspensionRecord, restoredCopy: Bool = false)
        async throws -> SandboxSuspensionRecord
    {
        guard let fence = record.guestFence else { return record }
        if fence.state == .released && !restoredCopy { return record }
        guard let managed = sandboxes[record.sandboxId.uuidString], managed.identityNonce == fence.identityNonce else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
        guard
            identityMatches(
                response, sandboxId: record.sandboxId.uuidString,
                expectedNonce: fence.identityNonce),
            case .pong(_, _, let version) = response,
            version == SandboxGuestControlProtocol.idlePolicyVersion,
            version == fence.request.guestProtocolVersion,
            sandboxes[record.sandboxId.uuidString]?.identityNonce == managed.identityNonce
        else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        // A paused adopted guest has no cached capability until its first
        // identity-verified ping after resume. Release uses the same v5
        // transport guard as prepare, so learn the actual capability first.
        sandboxes[record.sandboxId.uuidString]?.guestControlProtocolVersion = version
        suspensionRecords.removeValue(forKey: record.sandboxId.uuidString)
        let lifecycle = try automaticFenceLifecycle()
        let result = try await StageBudget.run(seconds: 20, stage: "automatic-suspension-release") {
            try await lifecycle.release(record, restoredCopy: restoredCopy)
        }
        suspensionRecords[result.sandboxId.uuidString] = result
        return result
    }

    /// Recover a prepare/release interrupted before any checkpoint commit.
    /// Never recreate a missing original or infer that it was unfrozen.
    func recoverAutomaticSuspensionRollback(_ record: SandboxSuspensionRecord) async throws {
        guard record.phase == .capturing || record.phase == .resumed,
            record.guestFence?.blocksWorkloadAdmission == true,
            let managed = sandboxes[record.sandboxId.uuidString]
        else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        let generation = try suspensionGuards[record.sandboxId.uuidString, default: SandboxSuspensionGuard()]
            .resumeGeneration()
        let info = try await managed.manager.getInstanceInfo()
        guard info.state == .running || info.state == .paused else { throw SandboxSuspensionGuard.GateError.stale }
        if info.state == .paused {
            try suspensionGuards[record.sandboxId.uuidString, default: SandboxSuspensionGuard()]
                .validateResumeGeneration(generation)
            try await managed.manager.resume()
        }
        _ = try await releaseAutomaticSuspensionFence(record)
    }

    func suspendSandbox(sandboxId: String, generation: Int64, automatic: Bool) async throws {
        guard !automatic else {
            throw SandboxRuntimeError.notSnapshottable("automatic suspension requires a journaled guest fence")
        }
        try await suspendSandbox(sandboxId: sandboxId, generation: generation, fence: nil)
    }

    func suspendSandbox(sandboxId: String, fence: SandboxAutomaticSuspensionFence) async throws {
        try await suspendSandbox(sandboxId: sandboxId, generation: fence.generation, fence: fence)
    }

    func suspendSandbox(sandboxId: String, generation: Int64, fence: SandboxAutomaticSuspensionFence?) async throws {
        let automatic = fence != nil
        if automatic {
            guard automaticSuspensionTransport != nil else {
                throw SandboxRuntimeError.notSnapshottable("automatic suspension transport is not configured")
            }
        }
        if automatic {
            guard
                idleSuspensionAdmissions[sandboxId]?.permitsDestruction(
                    evidence: idleSuspensionEvidence(sandboxId: sandboxId), at: Date()) == true
            else { throw SandboxSuspensionGuard.GateError.stale }
        }
        defer { if automatic { idleSuspensionAdmissions.removeValue(forKey: sandboxId) } }
        if let existing = try loadSuspensionRecord(sandboxId: sandboxId), existing.phase == .suspended {
            if let fence {
                guard existing.guestFence?.request == fence else { throw SandboxSuspensionGuard.GateError.stale }
            }
            return
        }
        guard let id = UUID(uuidString: sandboxId), let managed = sandboxes[sandboxId],
            let jail = managed.jail
        else {
            throw SandboxRuntimeError.notSnapshottable(
                "durable suspension requires an adopted, jailed sandbox")
        }
        try BurstableRuntimeGate.requireSupport(
            resourceClass: managed.spec.resourceClass, enforcement: burstableEnforcement)
        guard !checkpointing.contains(sandboxId), suspending.insert(sandboxId).inserted else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        defer { suspending.remove(sandboxId) }
        guard !execSessions.values.contains(where: { $0.sandboxId == sandboxId }) else {
            throw SandboxSuspensionGuard.GateError.active
        }
        let ticket = try suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].beginSuspension(
            generation: generation, automatic: automatic)
        defer { suspensionGuards[sandboxId]?.finish(ticket) }
        let previous = try loadSuspensionRecord(sandboxId: sandboxId)
        guard previous?.guestFence?.blocksWorkloadAdmission != true else {
            throw SandboxSuspensionGuard.GateError.busy
        }
        let snapshotId = previous.flatMap { $0.phase == .capturing ? $0.snapshotId : nil } ?? UUID()
        var record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: snapshotId,
            generation: generation, activityEpoch: ticket.activityEpoch,
            jailUID: jail.uid, spec: managed.spec,
            previousSnapshotId: previous?.phase == .capturing ? previous?.previousSnapshotId : previous?.snapshotId)
        if let fence {
            record.guestFence = SandboxSuspensionGuestFence(request: fence, identityNonce: managed.identityNonce)
            guard record.guestFence?.hasValidShape(for: record) == true,
                managed.guestControlProtocolVersion == fence.guestProtocolVersion
            else {
                throw SandboxRuntimeError.notSnapshottable("automatic suspension requires a no-NIC v5 guest")
            }
        }
        let estimate = try await suspensionStorageEstimate(sandboxId: sandboxId)
        record.storageReservationBytes = estimate
        if let old = previous?.checkpointBytes {
            let (total, overflow) = estimate.addingReportingOverflow(old)
            guard !overflow else { throw SandboxSuspensionGuard.GateError.stale }
            record.storageReservationBytes = total
        }
        let originalWasRunning = try await managed.manager.getInstanceInfo().state == .running
        guard !automatic || originalWasRunning else { throw SandboxSuspensionGuard.GateError.stale }
        try saveSuspension(record)
        var committed = false
        var capturePaused = false
        do {
            if automatic { record = try await prepareAutomaticSuspensionFence(record) }
            _ = try await captureSandboxSnapshot(
                sandboxId: sandboxId, snapshotId: record.snapshotId.uuidString, mode: .stop, internalArchive: true)
            capturePaused = true
            let directory = suspensionArchive(sandboxId: sandboxId, snapshotId: record.snapshotId.uuidString)
            let snapshotId = record.snapshotId.uuidString
            let checkpoint = try await Task.detached {
                try SandboxCheckpointManifest.verifyIfPresent(
                    directory: directory, sandboxId: sandboxId, snapshotId: snapshotId,
                    identityNonce: managed.identityNonce)
            }.value
            guard let checkpoint else { throw SandboxCheckpointManifest.CheckpointError.invalidManifest }
            var bytes: Int64 = 0
            for artifact in checkpoint.artifacts {
                let (next, overflow) = bytes.addingReportingOverflow(artifact.sizeBytes)
                guard !overflow else { throw SandboxCheckpointManifest.CheckpointError.invalidArtifact }
                bytes = next
            }
            guard bytes <= estimate else {
                throw SandboxRuntimeError.snapshotIOFailed("checkpoint exceeded admitted storage estimate")
            }
            try await validateSuspensionCheckpoint(checkpoint, managed: managed, sandboxId: sandboxId)
            record.checkpoint = checkpoint
            record.phase = .verified
            try saveSuspension(record)
            if automatic {
                let lifecycle = try automaticFenceLifecycle()
                let verifiedRecord = record
                try await StageBudget.run(seconds: 20, stage: "automatic-suspension-admission") {
                    try await lifecycle.validateDestruction(verifiedRecord)
                }
            }
            // No await between this admission commit and the durable journal
            // write. Activity after this point requests restore, not rollback.
            if automatic {
                guard
                    idleSuspensionAdmissions[sandboxId]?.permitsFrozenDestruction(
                        evidence: idleSuspensionEvidence(sandboxId: sandboxId)) == true
                else { throw SandboxSuspensionGuard.GateError.stale }
            }
            try suspensionGuards[sandboxId]?.commitDestruction(ticket)
            record.phase = .destroying
            try saveSuspension(record)
            committed = true
            try await client.destroyVM(vmId: sandboxId)
            try await confirmNoSandboxProcessBeforeReportingGone(sandboxId, jailUID: jail.uid)
            record.phase = .suspended
            try saveSuspension(record)
            try retirePreviousSuspensionCheckpoint(&record)
            if suspensionGuards[sandboxId]?.needsRestore(after: ticket) == true {
                suspending.remove(sandboxId)
                try await resumeSuspendedSandbox(sandboxId: sandboxId, allowRacedActivity: true)
            }
        } catch {
            if !committed {
                // Validation, journal, cancellation, generation and activity
                // failures before destruction preserve the original guest.
                if capturePaused && originalWasRunning {
                    try await managed.manager.resume()
                    startLogFollow(sandboxId: sandboxId)
                }
                if automatic {
                    // Resolve a possibly lost prepare response before removing
                    // the only journal that identifies the frozen guest.
                    record = try loadSuspensionRecord(sandboxId: sandboxId) ?? record
                    record = try await releaseAutomaticSuspensionFence(record)
                }
                try removeItemIfPresent(
                    atPath: suspensionArchive(sandboxId: sandboxId, snapshotId: record.snapshotId.uuidString))
                if let previous {
                    try saveSuspension(previous)
                } else {
                    try suspensionStore.remove(sandboxId: id)
                    suspensionRecords.removeValue(forKey: sandboxId)
                }
            }
            throw error
        }
    }

    /// A real fresh-VMM snapshot/load with vCPUs held paused proves loadability
    /// before destroying the original. It never runs a duplicate guest. The
    /// shadow has a distinct jail/UID/vsock filesystem and an isolated TAP in
    /// its own namespace, attached to nothing. This is jailed-only because snapshots use jail-relative
    /// disk and vsock paths. Successful mock validation cannot enter this path.
    func validateSuspensionCheckpoint(
        _ checkpoint: SandboxCheckpointManifest, managed: Managed, sandboxId: String
    ) async throws {
        try await ensureWarmTemplateSweep()
        try await recoverAbandonedValidationProofs()
        let permit = try restoreAdmission.acquire()
        var durableOwner = false
        defer { if !durableOwner { restoreAdmission.release(permit) } }
        guard managed.jail != nil else { throw SandboxSuspensionGuard.GateError.stale }
        let version = await HypervisorProbe.firecrackerVersion(binaryPath: firecrackerBinaryPath)
        guard version == checkpoint.firecrackerVersion else {
            throw SandboxRuntimeError.notSnapshottable("checkpoint Firecracker version does not match this host")
        }
        // Reuse the existing crash-swept temporary UID ownership mechanism.
        let id = UUID()
        let proofId = "warm-template-suspend-proof-" + id.uuidString.lowercased()
        let lease = try jailUIDs.lease(for: proofId)
        activeValidationProofs.insert(proofId)
        defer { activeValidationProofs.remove(proofId) }
        let reservation = HostReservation(
            cpus: managed.spec.cpus,
            memoryBytes: WorkloadMemoryReservation.sandbox(memoryBytes: managed.spec.memoryBytes).effectiveBytes,
            diskBytes: checkpoint.artifacts.reduce(0) { total, artifact in
                let (next, overflow) = total.addingReportingOverflow(artifact.sizeBytes)
                return overflow ? Int64.max : next
            })
        do {
            try validationProofStore.save(
                SandboxValidationProof(
                    id: id, permit: permit, jailUID: lease.uid, reservation: reservation))
        } catch {
            jailUIDs.rollBack(lease)
            throw error
        }
        durableOwner = true
        do {
            try persistWarmTemplateUID(lease.uid, templateId: proofId)
            let plan = try jailPlan(for: proofId, recordedUID: lease.uid)
            let attachments = try await prepareTemplateNIC(
                templateId: proofId, nicCount: managed.spec.network == nil ? 0 : 1)
            if attachments.isEmpty { try await createNetns(plan.netnsName) }
            let overrides = try await requiredNetworkOverrides(
                forTAP: try sandboxTAPName(attachments), operation: "validating a suspension checkpoint")
            try FileManager.default.createDirectory(atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            let archive = suspensionArchive(sandboxId: sandboxId, snapshotId: checkpoint.snapshotId)
            let files = [
                (SnapshotFile.rootfs, SandboxJailPlan.rootfsPathInJail),
                (SnapshotFile.configImage, SandboxJailPlan.configPathInJail),
                (SnapshotFile.memory, SandboxJailPlan.snapshotMemoryPathInJail),
                (SnapshotFile.vmstate, SandboxJailPlan.snapshotVmstatePathInJail),
            ]
            try FileManager.default.createDirectory(
                atPath: plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail), withIntermediateDirectories: true)
            for (source, destination) in files {
                let path = plan.hostPath(forInJail: destination)
                try await reflinkCopy(from: archive + "/" + source, to: path)
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            let options = try makeJailerOptions(
                plan: plan, guestMemoryBytes: managed.spec.memoryBytes, resourceClass: managed.spec.resourceClass)
            let manager = try await client.restoreVM(
                vmId: proofId, jail: options,
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail, resumeVM: false, networkOverrides: overrides)
            )
            let info = try await manager.getInstanceInfo()
            guard info.state == .paused else { throw SandboxSuspensionGuard.GateError.stale }
        } catch {
            // Cleanup failure takes precedence: retain the lease until the
            // existing crash sweep can prove the shadow process gone.
            do {
                try await finishValidationProofCleanup(templateId: proofId) {
                    try await teardownWarmTemplate(templateId: proofId, vm: nil, lease: lease)
                }
            } catch {
                validationProofRecoveryPending = true
                throw error
            }
            throw error
        }
        do {
            try await finishValidationProofCleanup(templateId: proofId) {
                try await teardownWarmTemplate(templateId: proofId, vm: nil, lease: lease)
            }
        } catch {
            validationProofRecoveryPending = true
            throw error
        }
    }

    func resumeSuspendedSandbox(sandboxId: String, expectedGeneration: Int64? = nil, allowRacedActivity: Bool = false)
        async throws
    {
        invalidateIdleActivity(sandboxId: sandboxId)
        guard var record = try loadSuspensionRecord(sandboxId: sandboxId), record.checkpoint != nil else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        guard record.phase != .resumed else { return }
        let resumeGeneration = try suspensionGuards[sandboxId, default: SandboxSuspensionGuard()]
            .resumeGeneration(expected: expectedGeneration, allowRacedActivity: allowRacedActivity)
        try await ensureWarmTemplateSweep()
        try await recoverAbandonedValidationProofs()
        let permit = try restoreAdmission.acquire()
        defer { restoreAdmission.release(permit) }
        if [.verified, .destroying].contains(record.phase), let managed = sandboxes[sandboxId] {
            do {
                let info = try await managed.manager.getInstanceInfo()
                if info.state == .running || info.state == .paused {
                    // Prefer the surviving original copy. It may be newer than
                    // the checkpoint if a prior rollback resumed it.
                    record.phase = .resuming
                    try saveSuspension(record)
                }
            } catch {
                try await confirmNoSandboxProcessBeforeReportingGone(sandboxId, jailUID: record.jailUID)
            }
        }
        if record.phase == .resuming {
            guard let managed = sandboxes[sandboxId] else { throw SandboxSuspensionGuard.GateError.stale }
            let info = try await managed.manager.getInstanceInfo()
            if info.state == .paused {
                try suspensionGuards[sandboxId, default: SandboxSuspensionGuard()].validateResumeGeneration(
                    resumeGeneration)
                try await managed.manager.resume()
            }
            let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
            guard identityMatches(response, sandboxId: sandboxId, expectedNonce: managed.identityNonce) else {
                throw SandboxSuspensionGuard.GateError.stale
            }
            record = try await releaseAutomaticSuspensionFence(record)
            recordIdleResidency(sandboxId: sandboxId)
            record.phase = .resumed
            record.lastRestoreFailure = nil
            try saveSuspension(record)
            startLogFollow(sandboxId: sandboxId)
            return
        }
        record.phase = .restoring
        record.lastRestoreFailure = nil
        try saveSuspension(record)
        let began = ContinuousClock.now
        let snapshotId = record.snapshotId.uuidString
        let attachments = sandboxes[sandboxId]?.networkAttachments ?? []
        do {
            try await StageBudget.run(seconds: suspensionRestoreTimeoutSeconds, stage: "sandbox-suspension-restore") {
                try await self.restoreSandboxArchive(
                    sandboxId: sandboxId, snapshotId: snapshotId, artifacts: nil,
                    networkAttachments: attachments, internalArchive: true, expectedGeneration: resumeGeneration)
            }
            record = try loadSuspensionRecord(sandboxId: sandboxId) ?? record
            recordIdleResidency(sandboxId: sandboxId)
            record.phase = .resumed
            let elapsed = began.duration(to: .now).components
            record.lastRestoreMillis = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            try saveSuspension(record)
        } catch {
            if var current = try loadSuspensionRecord(sandboxId: sandboxId), current.phase == .resuming {
                current.lastRestoreFailure =
                    current.guestFence?.blocksWorkloadAdmission == true
                    ? "guest fence release unconfirmed" : "resume health unconfirmed"
                try saveSuspension(current)
                throw error
            }
            // Retain both the permit and checkpoint while proving a failed
            // replacement is gone. Never cold-boot or silently rewind a live
            // guest after an identity/health failure.
            do {
                try await client.destroyVM(vmId: sandboxId)
            } catch FirecrackerError.vmNotFound {
                try await confirmNoSandboxProcessBeforeReportingGone(sandboxId, jailUID: record.jailUID)
            }
            record.phase = .suspended
            record.lastRestoreFailure = "restore failed"
            try saveSuspension(record)
            throw error
        }
    }

    func recoverSuspendedContext(sandboxId: String, jailUID: UInt32?) async throws -> SandboxStatus {
        guard var record = try loadSuspensionRecord(sandboxId: sandboxId),
            let checkpoint = record.checkpoint, jailUID == record.jailUID,
            record.mayReplayCheckpointWithoutGuest
        else {
            // A guest that may have run beyond its checkpoint cannot silently
            // restore an older copy, or fall through adoptionTargetGone to OCI.
            throw SandboxRuntimeError.notSnapshottable("suspension recovery cannot safely replay this checkpoint")
        }
        try await confirmNoSandboxProcessBeforeReportingGone(sandboxId, jailUID: record.jailUID)
        let archive = suspensionArchive(sandboxId: sandboxId, snapshotId: record.snapshotId.uuidString)
        let verified = try await Task.detached {
            try SandboxCheckpointManifest.verifyIfPresent(
                directory: archive, sandboxId: sandboxId, snapshotId: checkpoint.snapshotId,
                identityNonce: checkpoint.identityNonce)
        }.value
        guard verified == checkpoint else { throw SandboxCheckpointManifest.CheckpointError.integrityMismatch }
        let config = try SandboxConfigDrive.decode(
            fromBlockImage: Data(contentsOf: URL(fileURLWithPath: archive + "/" + SnapshotFile.configImage)))
        guard config.sandboxId == sandboxId, config.identityNonce == checkpoint.identityNonce else {
            throw SandboxCheckpointManifest.CheckpointError.identityMismatch
        }
        let plan = try jailPlan(for: sandboxId, recordedUID: record.jailUID)
        let options = try makeJailerOptions(
            plan: plan, guestMemoryBytes: record.spec.memoryBytes, resourceClass: record.spec.resourceClass)
        let manager = await client.disconnectedManager(vmId: sandboxId, jail: options)
        sandboxes[sandboxId] = Managed(
            spec: record.spec, rootfsPath: plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail),
            configPath: plan.hostPath(forInJail: SandboxJailPlan.configPathInJail),
            vsockUdsPath: plan.vsockUDSHostPath, identityNonce: checkpoint.identityNonce, jail: plan,
            manager: manager, lastExitCode: nil)
        record.phase = .suspended
        try saveSuspension(record)
        return .suspended
    }

    func retirePreviousSuspensionCheckpoint(_ record: inout SandboxSuspensionRecord) throws {
        if let old = record.previousSnapshotId, old != record.snapshotId {
            try removeItemIfPresent(
                atPath: suspensionArchive(sandboxId: record.sandboxId.uuidString, snapshotId: old.uuidString))
            try synchronizeDirectory(atPath: sandboxDirectory(record.sandboxId.uuidString) + "/hibernation")
        }
        record.previousSnapshotId = nil
        record.storageReservationBytes = record.checkpointBytes
        try saveSuspension(record)
    }
}
#endif
