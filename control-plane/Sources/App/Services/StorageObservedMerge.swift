import Fluent
import Foundation
import StratoShared
import Vapor

extension ObservedStateApplier {
    // MARK: - Volumes (STR-148)

    /// Volume counterpart of `applyObservedVMState`. Same shape and the same
    /// transition rules; what differs is that a volume's status is *entirely*
    /// derived here, since the control plane no longer writes a transitional
    /// status of its own before dispatching anything.
    func applyObservedVolumeState(
        volume: Volume,
        observed: ObservedVolumeState,
        agentId: String,
        on db: Database
    ) async throws -> Bool {
        let volumeID = try volume.requireID()
        try logSupersededFailureReport(volume, reportedGeneration: observed.failedGeneration)
        // Captured before anything mutates, for exactly the reasons the VM
        // path documents: `recordConvergence` mirrors the agent's own
        // `failedGeneration` onto the model and would otherwise satisfy the
        // idempotence guard with nothing recorded.
        let wasConverged = volume.isConverged
        let failedBefore = volume.failedGeneration
        let volumePool = try await VolumeService.pool(of: volume, on: db)
        let isCeph = volumePool?.mode == .ceph
        let observedCephAttachment: DiskAttachment?
        if isCeph, observed.present, let attachment = observed.attachment {
            guard
                case .rbd(
                    let poolName, let imageName, let namespace, let user, let monEndpoints,
                    let clusterID, let credentialID, let configPath
                ) = attachment,
                poolName == volumePool?.cephPoolName,
                namespace == volumePool?.cephNamespace,
                clusterID == volumePool?.$cephCluster.id,
                imageName == CephVolumeStorage.imageName(volumeId: volumeID),
                let cluster = try await CephCluster.find(clusterID, on: db),
                monEndpoints == cluster.monEndpoints,
                configPath
                    == CephVolumeStorage.configPath(
                        clusterId: clusterID, credentialId: credentialID),
                let access = try await CephProjectAccess.query(on: db)
                    .filter(\.$keyringSecret.$id == credentialID).first(),
                access.id == volumePool?.$cephProjectAccess.id,
                access.$cluster.id == clusterID,
                user == String(access.clientName.dropFirst("client.".count))
            else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Ceph reconciler reported an attachment outside the volume's configured pool or credential")
            }
            observedCephAttachment = attachment
        } else {
            observedCephAttachment = nil
        }
        let generationBeforeTarget = max(0, volume.generation - 1)
        let allStorageSettled: Bool
        let aggregateObservedGeneration: Int64
        if isCeph {
            allStorageSettled =
                observed.present
                && observedCephAttachment != nil
                && observed.convergencePhase == nil
                && observed.observedGeneration >= volume.generation
            aggregateObservedGeneration =
                observed.present
                ? observed.observedGeneration : min(observed.observedGeneration, generationBeforeTarget)
        } else {
            try await recordReplicaObservation(
                volumeID: volumeID, agentId: agentId, observed: observed,
                desiredGeneration: volume.generation, on: db)
            let requiredReplicas = try await VolumeReplica.query(on: db)
                .filter(\.$volume.$id == volumeID)
                .filter(\.$state ~~ VolumeService.authoritativeReplicaStates)
                .all()
            allStorageSettled =
                !requiredReplicas.isEmpty
                && requiredReplicas.allSatisfy {
                    $0.state == .healthy && $0.generation >= volume.generation
                }
            aggregateObservedGeneration =
                requiredReplicas.map { replica in
                    replica.state == .healthy
                        ? replica.generation : min(replica.generation, generationBeforeTarget)
                }.min() ?? 0
        }
        let failedAtTarget =
            observed.lastError != nil && observed.failedGeneration == volume.generation
        let nextPhase: String?
        let nextError: String?
        let nextFailedGeneration: Int64?
        if failedAtTarget {
            nextPhase = observed.convergencePhase
            nextError = observed.lastError
            nextFailedGeneration = observed.failedGeneration
        } else if allStorageSettled {
            nextPhase = nil
            nextError = nil
            nextFailedGeneration = nil
        } else {
            nextPhase = observed.convergencePhase ?? (isCeph ? "waiting for Ceph image" : "waiting for replicas")
            nextError = volume.errorMessage
            nextFailedGeneration = volume.failedGeneration
        }
        var changed = volume.recordConvergence(
            phase: nextPhase,
            lastError: nextError,
            failedGeneration: nextFailedGeneration
        )

        if isCeph, let attachment = observedCephAttachment,
            volume.diskAttachment != attachment
        {
            volume.diskAttachment = attachment
            changed = true
        }

        // The size the image actually has (STR-199) — recorded here for the same
        // reason the path is, and with the same asymmetry as the applied I/O
        // ceilings below: it is a fact about the volume rather than a verdict on
        // the mutation, so it lands before the converging early-return, and an
        // agent that reported *nothing* (pre-v38, or a probe that could not read
        // the image) leaves the column alone instead of clearing it. Writing nil
        // through would turn a silent agent into "this volume has no size",
        // which is the same wrong answer in the other direction.
        if let reported = observed.sizeBytes, volume.observedSizeBytes != reported {
            volume.observedSizeBytes = reported
            changed = true
        }

        // A source-backed volume may materialize larger than the requested
        // size. Admit that excess as soon as the agent reports it rather than
        // waiting for attachment: an unattached data volume still occupies the
        // bytes and must not remain permanently under-charged. Advancing the
        // generation makes the agent confirm the normalized desired size.
        var normalizedDesiredSize = false
        if volume.$sourceImage.id != nil || volume.$sourceVolume.id != nil,
            observed.present,
            observed.convergencePhase == nil,
            observed.lastError == nil,
            let materializedSize = observed.sizeBytes,
            materializedSize > volume.size
        {
            let admissionError: String?
            if materializedSize > WorkloadSizeLimits.maxDiskBytes {
                admissionError =
                    "Cannot admit the materialized volume at \(materializedSize) bytes: "
                    + "it exceeds the maximum supported volume size of "
                    + "\(WorkloadSizeLimits.maxDiskBytes) bytes."
            } else {
                do {
                    guard let project = try await Project.find(volume.$project.id, on: db) else {
                        throw Abort(
                            .internalServerError,
                            reason: "The volume's project no longer exists")
                    }
                    try await QuotaEnforcementService.reserveVolumeResize(
                        for: project,
                        environment: volume.environment,
                        sizeDelta: materializedSize - volume.size,
                        reason: "the materialized volume",
                        on: db)
                    admissionError = nil
                } catch let error as any AbortError {
                    admissionError =
                        "Cannot admit the materialized volume at \(materializedSize) bytes: "
                        + error.reason
                }
            }

            if let admissionError {
                changed =
                    volume.recordConvergence(
                        phase: nil,
                        lastError: admissionError,
                        failedGeneration: volume.generation) || changed
            } else {
                let expectedGeneration = volume.generation
                volume.size = materializedSize
                guard
                    case .applied = try await volume.advanceDesiredStateGeneration(
                        expectedGeneration: expectedGeneration, on: db)
                else {
                    throw ConvergenceWriteError.unsupportedDatabase
                }
                volume.extendConvergenceDeadline(
                    by: OperationResourceKind.volume.completionBudgetSeconds(for: .resize))
                changed = true
                normalizedDesiredSize = true
            }
        }
        // The applied I/O ceilings (STR-19) — an echo, not a derivation, and
        // recorded before the converging early-return for the same reason the
        // storage path is: it is a fact about the volume, not a verdict on the
        // mutation.
        //
        // Written *only* when the agent said something. Nil here means "this
        // agent does not report applied limits" — which is every agent until
        // the agent-side work lands — and writing that through would record an
        // agent's silence as "the caps were removed". An agent reporting an
        // explicitly uncapped disk sends a present-but-empty value instead, and
        // that one does clear the columns.
        if let applied = observed.ioLimits {
            if volume.appliedIOPSTotal != applied.iopsTotal {
                volume.appliedIOPSTotal = applied.iopsTotal
                changed = true
            }
            if volume.appliedBPSTotal != applied.bpsTotal {
                volume.appliedBPSTotal = applied.bpsTotal
                changed = true
            }
        }

        // Nil is a pre-v60 agent saying nothing, not an instruction to erase a
        // previously observed policy. A storage-only replica also reports an
        // explicit inactive policy, so accept policy only from the agent that
        // claims the attachment or from the persisted attachment owner clearing
        // its own state. This is the same ownership rule used for
        // `attachedAgentId` below, kept ahead of the convergence early-return
        // because applied policy remains a useful fact while peers catch up.
        let reporterOwnsAttachment =
            observed.attachedVMId != nil || volume.attachedAgentId == agentId
        if let applied = observed.blockPolicy,
            reporterOwnsAttachment,
            volume.appliedBlockPolicy != applied
        {
            volume.appliedBlockPolicy = applied
            changed = true
        }

        if aggregateObservedGeneration > volume.observedGeneration {
            volume.observedGeneration = aggregateObservedGeneration
            changed = true
        }

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil || (isCeph && !allStorageSettled) {
            if changed {
                try await volume.save(on: db)
            }
            return normalizedDesiredSize
        }

        // Where the realized attachment runs. A detached report may clear only
        // this reporter's own attachment; a storage-only replica must not erase
        // the VM host's observation.
        if observed.attachedVMId != nil {
            if volume.attachedAgentId != agentId {
                volume.attachedAgentId = agentId
                changed = true
            }
        } else if volume.attachedAgentId == agentId {
            volume.attachedAgentId = nil
            changed = true
        }

        // Status is derived, not reported: the agent describes the bytes and
        // the attachment, and those two facts plus the desired state are the
        // whole status vocabulary a volume has left.
        let derived: VolumeStatus
        if !observed.present {
            // Bytes not (yet) on disk with nothing in flight. Distinguishing a
            // create that has not started from one that failed is the
            // `lastError` check below; `.creating` is the honest reading here.
            derived = observed.lastError == nil ? .creating : .error
        } else if volume.attachedAgentId != nil {
            derived = .attached
        } else {
            derived = .available
        }
        // `.snapshotting` is no longer written by anything (STR-150 made a
        // volume snapshot its own converging resource), so there is nothing
        // left to protect it from: the report is authoritative.
        if volume.status != derived {
            volume.status = derived
            changed = true
        }
        // Preserve the desired state and deadline for an actionable refusal
        // the agent is still retrying. Replica and status facts above still
        // land, including the degraded reason.
        if failedAtTarget, observed.failureClassification == .blocked {
            if changed {
                try await volume.save(on: db)
            }
            return normalizedDesiredSize
        }
        _ = try await settleConvergence(
            volume,
            wasConverged: wasConverged,
            changed: changed,
            reportedError: observed.lastError,
            reportedFailedGeneration: observed.failedGeneration,
            previousFailureGeneration: failedBefore,
            defaultMutation: .create,
            on: db)
        return normalizedDesiredSize
    }

    /// The rows behind one family's reported-unrecognized ids, including rows
    /// placed on *other* agents — which is the whole re-point signal.
    func collectSnapshotPlacements<A: SnapshotArtifactResource>(
        _ type: A.Type,
        kind: WorkloadKind,
        from report: ObservedStateReport,
        into placements: inout [UUID: WorkloadPlacement],
        on db: Database
    ) async throws {
        let ids = report.unrecognized.filter { $0.kind == kind }.map(\.workloadId)
        guard !ids.isEmpty else { return }
        for artifact in try await A.query(on: db).filter(\._$id ~~ ids).all() {
            guard let id = artifact.id else { continue }
            placements[id] = WorkloadPlacement(agentId: artifact.agentId)
        }
    }

    // MARK: - Snapshot artifacts (STR-150)

    /// One family's half of a report. Written once and applied three times:
    /// the diff, the convergence metadata, the derived status and the
    /// absent-then-reap dance are identical across the families, and only what
    /// the captured facts *mean* differs — which each model absorbs in
    /// `applyCapturedFacts`.
    func applyObservedSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type,
        reported: [UUID: ObservedSnapshotState],
        agentId: String,
        on db: Database
    ) async throws {
        for artifact in try await A.placed(onAgent: agentId, on: db) {
            guard let artifactID = artifact.id else { continue }
            if let observed = reported[artifactID] {
                // A kind mismatch means two families minted the same UUID,
                // which cannot happen — but routing an entry to the wrong table
                // would apply one family's facts to another's row, so it is
                // checked rather than assumed.
                guard observed.kind == A.artifactKind else { continue }
                let shouldEnforceStorageQuota = try await withLockedCurrent(
                    artifact, reportedBy: agentId, on: db
                ) { artifact, tx in
                    try await applyObservedSnapshotState(
                        artifact: artifact, observed: observed, on: tx)
                }
                if shouldEnforceStorageQuota == true {
                    // Start quota enforcement only after the row-locking
                    // transaction commits. A quota-triggered delete takes the
                    // lineage advisory lock before it locks this row.
                    try await enforceStorageQuota(on: artifact, on: db)
                }
            } else {
                try await withLockedCurrent(artifact, reportedBy: agentId, on: db) { artifact, tx in
                    try await handleReportedSnapshotAbsence(
                        artifact: artifact, agentId: agentId, on: tx)
                }
            }
        }
    }

    /// Snapshot counterpart of `applyObservedVolumeState`, with the same
    /// transition rules and the same reasons for the order they run in.
    func applyObservedSnapshotState<A: SnapshotArtifactResource>(
        artifact: A,
        observed: ObservedSnapshotState,
        on db: Database
    ) async throws -> Bool {
        try logSupersededFailureReport(artifact, reportedGeneration: observed.failedGeneration)
        // Captured before anything mutates, for the reasons the VM path
        // documents: `recordConvergence` mirrors the agent's own
        // `failedGeneration` onto the model and would otherwise satisfy the
        // idempotence guard with nothing recorded.
        let wasConverged = artifact.isConverged
        let failedBefore = artifact.failedGeneration

        var changed = artifact.recordConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )

        // The captured facts — footprint, hypervisor version, fork layout,
        // architecture — are recorded before the converging early-return, and
        // this is the whole reason they moved onto the report. As an RPC reply
        // they were delivered once: a socket that dropped mid-flight lost them,
        // and the old paths had to treat that as a protocol error and mark a
        // checkpoint that in fact existed `.error`. A report is re-sent on every
        // heartbeat, so they simply arrive again.
        var footprintChanged = false
        if let facts = observed.facts, artifact.applyCapturedFacts(facts) {
            changed = true
            footprintChanged = true
        }
        if artifact.applyExported(observed.exported) {
            changed = true
        }

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await artifact.save(on: db)
            }
            return false
        }

        if observed.observedGeneration > artifact.observedGeneration {
            artifact.observedGeneration = observed.observedGeneration
            changed = true
        }

        // Status is derived, not reported: the agent describes the bytes, and
        // that fact plus the desired state is the whole status vocabulary an
        // artifact has.
        let failed = observed.lastError != nil
        if artifact.applyObservedPresence(present: observed.present, failed: failed) {
            changed = true
        }

        // A blocked capture/export keeps its requested intent until a later
        // same-generation report succeeds or the convergence deadline expires.
        let failedCurrentGeneration =
            observed.lastError != nil && observed.failedGeneration == artifact.generation
        if failedCurrentGeneration, observed.failureClassification == .blocked {
            if changed {
                try await artifact.save(on: db)
            }
            return footprintChanged
        }

        let settlement = try await settleConvergence(
            artifact,
            wasConverged: wasConverged,
            changed: changed,
            reportedError: observed.lastError,
            reportedFailedGeneration: observed.failedGeneration,
            previousFailureGeneration: failedBefore,
            defaultMutation: .create,
            on: db)
        if case .unchanged = settlement {
            return false
        }
        return footprintChanged
    }

    /// Re-checks the storage pool at the moment the agent's real footprint
    /// replaces the admission estimate, deleting the artifact when that put an
    /// enabled quota over its limit.
    ///
    /// This is the check the retired background create halves ran right after
    /// the RPC reply, and it has to survive the conversion because the estimate
    /// and the truth can differ by a lot: admission reserves a sandbox's guest
    /// memory, while the artifact adds vmstate and — without reflink support —
    /// a full rootfs copy. Without it a project sits over an enabled quota
    /// indefinitely, the artifact converges `ready`, and the only symptom is the
    /// *next* create being refused with no explanation of what consumed the
    /// pool.
    ///
    /// Deleting rather than tolerating is the pre-existing contract, kept
    /// deliberately: the alternative silently converts a quota into a
    /// suggestion. Both are defensible, but changing which one holds is not this
    /// conversion's business.
    ///
    /// Runs outside any transaction of ours — `storageOverCommit` resyncs and
    /// saves each quota, and `SnapshotArtifactMutation.delete` opens its own —
    /// so it is the last thing this method does. Failures are logged rather
    /// than thrown: an observed report that could not enforce a quota must
    /// still apply everything else it carried.
    func enforceStorageQuota<A: SnapshotArtifactResource>(
        on artifact: A, on db: Database
    ) async throws {
        guard let scope = artifact.storageQuotaScope, artifact.desiredStatus == .present else { return }
        do {
            guard
                let violated = try await QuotaEnforcementService.storageOverCommit(
                    projectID: scope.projectID, environment: scope.environment, on: db)
            else { return }

            let failureReason =
                "Snapshot's actual size exceeded storage quota '\(violated)' and was deleted"
            _ = try await SnapshotArtifactMutation.delete(
                artifact, actor: .system, on: db, app: app,
                failureReason: failureReason)

            let artifactID = try artifact.requireID()
            app.logger.notice(
                "Snapshot artifact's reported size exceeded a storage quota; deleting it",
                metadata: [
                    "resourceKind": .string(A.operationResourceKind.rawValue),
                    "resourceId": .string(artifactID.uuidString),
                    "quota": .string(violated),
                ])
        } catch {
            app.logger.error(
                "Failed to enforce the storage quota on a snapshot artifact: \(error)",
                metadata: ["resourceKind": .string(A.operationResourceKind.rawValue)])
        }
    }

    /// A snapshot artifact the database maps to this agent is absent from its
    /// full report: either a confirmed deletion (desired absent) or genuine
    /// loss.
    ///
    /// This is the only place a snapshot row is ever removed. The agent
    /// omitting the artifact from a full list is the confirmation that its
    /// bytes are gone — the same contract VMs, sandboxes and volumes have, and
    /// the reason a snapshot delete survives a control-plane restart at all.
    func handleReportedSnapshotAbsence<A: SnapshotArtifactResource>(
        artifact: A,
        agentId: String,
        on db: Database
    ) async throws {
        let artifactID = try artifact.requireID()

        if try await confirmTeardown(
            artifact,
            removedMessage: "Snapshot deletion confirmed by agent report; record removed",
            metadata: [
                "resourceKind": .string(A.operationResourceKind.rawValue),
                "resourceId": .string(artifactID.uuidString),
                "strato.agent.id": .string(agentId),
            ],
            on: db)
        {
            return
        }

        let convergenceCleared = artifact.recordConvergence(
            phase: nil, lastError: artifact.lastError, failedGeneration: artifact.failedGeneration)

        // Only escalate an artifact some agent has actually confirmed. A row at
        // `observedGeneration == 0` is mid-capture — the agent has not written
        // it yet, and its absence is expected rather than a loss.
        guard artifact.observedGeneration > 0, artifact.isPresentOnAgent else {
            if convergenceCleared {
                try await artifact.save(on: db)
            }
            return
        }

        _ = artifact.applyObservedPresence(present: false, failed: true)
        artifact.lastError = "snapshot artifacts are missing from their agent"
        try await artifact.save(on: db)
        app.logger.warning(
            "Snapshot missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "resourceKind": .string(A.operationResourceKind.rawValue),
                "resourceId": .string(artifactID.uuidString),
                "strato.agent.id": .string(agentId),
            ])
    }

    /// A volume the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    ///
    /// This is the only place a volume row is ever removed. The agent omitting
    /// the volume from a full list is the confirmation that its data is gone —
    /// the same contract VMs and sandboxes have, and the reason a volume delete
    /// can be re-driven indefinitely without ever orphaning bytes.
    func handleReportedVolumeAbsence(
        volume: Volume,
        agentId: String,
        on db: Database
    ) async throws {
        let volumeID = try volume.requireID()

        if volume.desiredStatus == .absent {
            if try await VolumeService.pool(of: volume, on: db)?.mode == .ceph {
                _ = try await confirmTeardown(
                    volume,
                    removedMessage: "Ceph volume deletion confirmed by reconciler; record removed",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "agentId": .string(agentId),
                    ],
                    on: db)
                return
            }
            // One report only confirms one physical copy is gone. Remove that
            // replica and keep the shared finalizer until every physical copy,
            // including degraded, resyncing, and faulted copies, has
            // independently disappeared.
            try await VolumeReplica.query(on: db)
                .filter(\.$volume.$id == volumeID)
                .filter(\.$agentId == agentId)
                .delete()
            let remainingAgentIDs = try await VolumeService.agentIDsWithPhysicalReplicas(
                of: volume, on: db)
            guard remainingAgentIDs.isEmpty else {
                app.logger.debug(
                    "Volume replica teardown confirmed; awaiting other replicas",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "strato.agent.id": .string(agentId),
                        "strato.agent.remaining.ids": .array(
                            remainingAgentIDs.sorted().map { .string($0) }),
                    ])
                return
            }
            _ = try await confirmTeardown(
                volume,
                removedMessage: "Volume deletion confirmed by agent report; record removed",
                heldMessage: "Volume teardown confirmed by agent report; awaiting finalizers",
                metadata: [
                    "volumeId": .string(volumeID.uuidString),
                    "strato.agent.id": .string(agentId),
                ],
                on: db)
            return
        }

        // Nothing to report means no progress to report — same rationale as the
        // VM and sandbox paths.
        let convergenceCleared = volume.recordConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)

        // Only escalate a volume some agent has actually confirmed. A row at
        // `observedGeneration == 0` may simply be waiting for its first sync to
        // reach the agent, and calling that an error would make every create
        // flash red before it went green.
        guard volume.observedGeneration > 0, volume.status != .error else {
            if convergenceCleared {
                try await volume.save(on: db)
            }
            return
        }

        let previous = volume.status
        volume.status = .error
        volume.errorMessage = "volume data is missing from its agent"
        try await volume.save(on: db)
        app.logger.warning(
            "Volume missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "volumeId": .string(volumeID.uuidString),
                "strato.agent.id": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

    /// Record one copy's convergence independently from the logical volume.
    /// The logical observed generation is the minimum across required copies,
    /// so one fast replica cannot settle a mutation for a lagging peer.
    ///
    /// Moved here from `VolumeService` with STR-148: the replica row is a
    /// record of *observed* placement, so it belongs on the path that ingests
    /// observations rather than on one that used to await an RPC response.
    func recordReplicaObservation(
        volumeID: UUID,
        agentId: String,
        observed: ObservedVolumeState,
        desiredGeneration: Int64,
        on db: Database
    ) async throws {
        let failedAtTarget =
            observed.lastError != nil && observed.failedGeneration == desiredGeneration
        let state: VolumeReplicaState =
            observed.present && observed.convergencePhase == nil && !failedAtTarget
            ? .healthy : .provisioning
        if let existing = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .filter(\.$agentId == agentId)
            .first()
        {
            var changed = false
            if let diskAttachment = observed.attachment,
                existing.diskAttachment != diskAttachment
            {
                existing.diskAttachment = diskAttachment
                changed = true
            }
            if existing.state != state {
                existing.state = state
                changed = true
            }
            if observed.observedGeneration > existing.generation {
                existing.generation = observed.observedGeneration
                changed = true
            }
            if changed {
                try await existing.save(on: db)
            }
            return
        }
        guard observed.present else { return }
        try await VolumeReplica(
            volumeID: volumeID,
            agentId: agentId,
            diskAttachment: observed.attachment,
            state: state,
            generation: observed.observedGeneration
        ).create(on: db)
    }
}
