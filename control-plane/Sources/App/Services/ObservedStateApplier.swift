import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Applies an agent's full observed-state report to the database (issue
/// #260): updates observed status and generation, completes pending
/// operations whose target state is now observed, confirms deletions by
/// absence, releases placement reservations the report proves stale, and
/// surfaces drift.
///
/// This is the workload half of report handling. The connection half —
/// decoding the envelope, the authenticated-connection ownership check, the
/// agent row's resource/liveness refresh, and per-agent ordering — stays with
/// the socket owner (`AgentService`), which calls `apply` once per report in
/// the agent's own send order.
struct ObservedStateApplier {
    let app: Application
    let database: PostgresStoreContext
    let workloads: WorkloadsPersistence

    private struct ResourceKey: Hashable {
        let kind: OperationResourceKind
        let id: UUID
    }

    /// Immutable report-level projection used to gate VM convergence without
    /// issuing one boot-volume query per VM.
    private struct BootVolumeDependency {
        let id: UUID
        let vmID: UUID
        let desiredSize: Int64
        let observedSize: Int64?
        let generation: Int64
        let degradedReason: String?
        let converged: Bool
        let status: VolumeStatus
        let attachedAgentID: String?

        init(_ volume: Volume) throws {
            guard let attachedVMID = volume.vmID else {
                throw Abort(.internalServerError, reason: "Boot volume is missing its VM relationship")
            }
            id = try volume.requireID()
            vmID = attachedVMID
            desiredSize = volume.size
            observedSize = volume.observedSizeBytes
            generation = volume.generation
            degradedReason = volume.conditions.degraded.flatMap {
                $0.sinceGeneration == volume.generation ? $0.reason : nil
            }
            converged = volume.isConverged
            status = volume.status
            attachedAgentID = volume.attachedAgentId
        }
    }

    /// What one report's teardown bookkeeping produced (STR-98), for the
    /// caller — which holds the agent row this needs to be reported against.
    struct UnrecognizedOutcome: Sendable {
        /// A teardown was newly authorized (or its generation advanced), so
        /// the agent should get a sync now rather than at the next period.
        var authorizedTeardown = false
        /// Applying an observation normalized desired state, so the reporting
        /// agent needs a fresh sync instead of waiting for the periodic one.
        var desiredStateChanged = false
        /// Held claims bucketed by reason, for a gauge recorded on every
        /// report. Both buckets are always present, including at zero, so the
        /// series falls back to 0 when the condition clears instead of going
        /// stale at its last non-zero value.
        var heldByReason: [String: Int] = [
            AgentWorkloadClaim.heldRowPresentReason: 0,
            AgentWorkloadClaim.heldOtherAgentBucket: 0,
        ]
    }

    /// Revalidates one row selected by the report's bulk prefetch before the
    /// report can write it. The bulk query is only an index of candidates; the
    /// row lock and refresh establish the authoritative desired state and
    /// placement at the moment this entry is applied.
    private func withLockedCurrent<R: ConvergingResource, Result: Sendable>(
        _ resource: R,
        reportedBy agentId: String,
        on db: PostgresStoreContext,
        applying body: @escaping @Sendable (R, PostgresStoreContext) async throws -> Result
    ) async throws -> Result? {
        try await db.transaction { tx -> Result? in
            guard let current = try await resource.lockingAndRefreshing(on: tx) else { return nil }
            let resourceID = try current.requireID()
            let placementAgentIDs = try await current.placementAgentIDs(on: tx)
            guard placementAgentIDs.contains(agentId) else {
                app.logger.debug(
                    "Ignoring an observed-state entry after the resource moved to another agent",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(resourceID.uuidString),
                        "reportingAgentId": .string(agentId),
                        "currentAgentId": .string(placementAgentIDs.joined(separator: ",")),
                    ])
                return nil
            }
            return try await body(current, tx)
        }
    }

    private func logSupersededFailureReport<R: ConvergingResource>(
        _ resource: R, reportedGeneration: Int64?
    ) throws {
        guard let reportedGeneration, reportedGeneration < resource.generation else { return }
        let resourceID = try resource.requireID()
        app.logger.debug(
            "Observed failure belongs to a superseded desired-state generation",
            metadata: [
                "resourceKind": .string(R.operationResourceKind.rawValue),
                "resourceId": .string(resourceID.uuidString),
                "reportedGeneration": .stringConvertible(reportedGeneration),
                "currentGeneration": .stringConvertible(resource.generation),
            ])
    }

    /// Apply one report, returning what the caller should do about the
    /// workloads the agent holds that no sync accounted for.
    @discardableResult
    func apply(_ report: ObservedStateReport) async throws -> UnrecognizedOutcome {
        let db = database

        // Network observations are independent of the workload manifest. A
        // host can fail to enumerate its local VM store while its site's OVN
        // author still has a valid view of shared load-balancer rows.
        if let loadBalancers = report.loadBalancers {
            try await applyObservedLoadBalancers(loadBalancers, on: db)
        }

        // A report from an agent that cannot read its own workload manifest
        // carries no inventory (STR-138). Its `vms`/`sandboxes` lists are
        // empty because the host's contents are unknown, not because it is
        // idle — and everything below reads meaning into absence: a missing VM
        // whose desired state is `.absent` clears the `agent.absent`
        // finalizer, which *deletes the row* for a guest that is still
        // running, and a missing VM in any live status is escalated to
        // `.error`. Nothing here may run against a blind report; the agent's
        // resources and the condition itself are folded in by the caller,
        // which is the whole useful content of such a report.
        if let manifest = report.manifestStatus, !manifest.inventoryComplete {
            app.logger.warning(
                "Ignoring the workload half of an observed-state report: the agent cannot enumerate its own workloads",
                metadata: [
                    "agentId": .string(report.agentId),
                    "reason": .string(manifest.reason),
                ])
            return UnrecognizedOutcome()
        }

        let reported = Dictionary(
            report.vms.map { ($0.vmId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Decide what the agent is holding that no sync accounted for
        // (STR-98) before touching the workloads themselves: a claim recorded
        // here is what authorizes — or permanently withholds — a teardown, and
        // the loud path below reads whether the same report also observed the
        // workload.
        var unrecognizedOutcome = try await applyUnrecognizedWorkloads(report, on: db)

        let dbVMs = try await LegacyVMStore.vms(hypervisorID: report.agentId, on: db)

        // Sandboxes apply with the same shape as VMs: settled observations
        // update the row and resolve pending operations; absence either
        // confirms a deletion or escalates a lost sandbox.
        let reportedSandboxes = Dictionary(
            report.sandboxes.map { ($0.sandboxId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let dbSandboxes = try await LegacySandboxStore.sandboxes(
            hypervisorID: report.agentId, on: db)

        // Only a workload no agent has ever confirmed can still own a placement
        // reservation, and this report is that confirmation: once it appears
        // here its resources are already reflected in the agent snapshot.
        // `observedGeneration == 0` is what "no agent has confirmed this yet"
        // means, and it replaces the pending-create lookup this used to do
        // (STR-147) — same set, one fewer table. Steady-state reports have no
        // unconfirmed workloads and therefore avoid the reservation-index
        // SMEMBERS entirely.
        let accountedReservationIDs =
            dbVMs.compactMap { vm -> String? in
                guard let id = vm.id, vm.observedGeneration == 0, reported[id] != nil else { return nil }
                return id.uuidString
            }
            + dbSandboxes.compactMap { sandbox -> String? in
                guard let id = sandbox.id, sandbox.observedGeneration == 0,
                    reportedSandboxes[id] != nil
                else { return nil }
                return id.uuidString
            }
        if !accountedReservationIDs.isEmpty {
            await app.coordination.releaseReservations(
                agentId: report.agentId,
                vmIds: accountedReservationIDs
            )
        }

        // Guest NIC state is another report-level batch. Only VMs whose
        // observation can read or clear guest data participate, so agents
        // without QGA payloads pay no NIC query at all.
        let interfaceVMIDs = dbVMs.compactMap { vm -> UUID? in
            guard let vmID = vm.id, let observed = reported[vmID] else { return nil }
            if observed.appliedNetworkInterfaceIds != nil { return vmID }
            if observed.guestInfo != nil {
                return vmID
            }
            if Self.guestInfoClearedByStatus.contains(observed.status),
                vm.qgaAvailable != nil || vm.observedHostname != nil
            {
                return vmID
            }
            return nil
        }
        let interfacesByVMID: [UUID: [VMNetworkInterface]]
        let observedAddressesByInterfaceID: [UUID: [ObservedInterfaceAddressSnapshot]]
        if interfaceVMIDs.isEmpty {
            interfacesByVMID = [:]
            observedAddressesByInterfaceID = [:]
        } else {
            let interfaces = try await LegacyVMNetworkInterfaceStore.interfaces(
                vmIDs: interfaceVMIDs, on: db)
            interfacesByVMID = Dictionary(grouping: interfaces, by: \.vmID)
            let observedAddresses = try await workloads.observedInterfaceAddresses(
                interfaceIDs: interfaces.compactMap(\.id))
            observedAddressesByInterfaceID = Dictionary(
                grouping: observedAddresses, by: \.interfaceID)
        }

        // Volumes are dependencies of VM convergence (STR-242), so apply this
        // report's volume facts before its VM facts. A single report can then
        // make a boot volume healthy and let the dependent VM settle; doing the
        // VM half first would leave it waiting on the previous volume state
        // until a second otherwise-identical heartbeat.
        //
        // `guard let` on the field, not on a version lookup: an agent below v31
        // omits `volumes` entirely, and treating that silence as an empty,
        // authoritative inventory would reap terminating rows and error live
        // ones.
        if let reportedVolumeList = report.volumes {
            let reportedVolumes = Dictionary(
                reportedVolumeList.map { ($0.volumeId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let dbVolumes = try await VolumeService.volumes(onAgent: report.agentId, on: db)
            for volume in dbVolumes {
                guard let volumeID = volume.id else { continue }
                if let observed = reportedVolumes[volumeID] {
                    let desiredStateChanged = try await withLockedCurrent(
                        volume, reportedBy: report.agentId, on: db
                    ) {
                        volume, tx in
                        return try await applyObservedVolumeState(
                            volume: volume, observed: observed, agentId: report.agentId, on: tx)
                    }
                    unrecognizedOutcome.desiredStateChanged =
                        unrecognizedOutcome.desiredStateChanged || desiredStateChanged == true
                } else {
                    try await withLockedCurrent(volume, reportedBy: report.agentId, on: db) {
                        volume, tx in
                        try await handleReportedVolumeAbsence(
                            volume: volume, agentId: report.agentId, on: tx)
                    }
                }
            }
        }

        // One dependency query per report, not per VM. It runs after volume
        // application so the snapshot includes this heartbeat's observed size,
        // phase, and attachment.
        let bootVolumesByVMID: [UUID: [BootVolumeDependency]]
        if report.volumes != nil {
            let vmIDs = dbVMs.compactMap(\.id)
            if vmIDs.isEmpty {
                bootVolumesByVMID = [:]
            } else {
                let bootVolumes = try await LegacyVolumeStore.volumes(
                    attachment: .attachedToAny(vmIDs), volumeType: .boot, on: db)
                bootVolumesByVMID = Dictionary(
                    grouping: try bootVolumes.map(BootVolumeDependency.init),
                    by: \.vmID)
            }
        } else {
            bootVolumesByVMID = [:]
        }

        for vm in dbVMs {
            guard let vmID = vm.id else { continue }
            if let observed = reported[vmID] {
                let interfaces = interfacesByVMID[vmID] ?? []
                try await withLockedCurrent(vm, reportedBy: report.agentId, on: db) { vm, tx in
                    try await applyObservedVMState(
                        vm: vm, observed: observed, interfaces: interfaces,
                        observedAddressesByInterfaceID: observedAddressesByInterfaceID,
                        bootVolumes: report.volumes == nil ? nil : bootVolumesByVMID[vmID] ?? [],
                        on: tx)
                }
            } else {
                try await withLockedCurrent(vm, reportedBy: report.agentId, on: db) { vm, tx in
                    try await handleReportedAbsence(
                        vm: vm, agentId: report.agentId, on: tx)
                }
            }
        }

        for sandbox in dbSandboxes {
            guard let sandboxID = sandbox.id else { continue }
            if let observed = reportedSandboxes[sandboxID] {
                try await withLockedCurrent(sandbox, reportedBy: report.agentId, on: db) {
                    sandbox, tx in
                    try await applyObservedSandboxState(
                        sandbox: sandbox, observed: observed, on: tx)
                }
            } else {
                try await withLockedCurrent(sandbox, reportedBy: report.agentId, on: db) {
                    sandbox, tx in
                    try await handleReportedSandboxAbsence(
                        sandbox: sandbox, agentId: report.agentId, on: tx)
                }
            }
        }

        // Snapshot artifacts (STR-150). `guard let` on the field for exactly
        // the volume reason above, one step more expensive to get wrong: an
        // empty list the control plane believed would reap every checkpoint row
        // it holds for this agent, and a checkpoint is a point in time nothing
        // can recreate.
        if let reportedSnapshotList = report.snapshots {
            let reported = Dictionary(
                reportedSnapshotList.map { ($0.snapshotId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            try await applyObservedSnapshots(
                VolumeSnapshot.self, reported: reported, agentId: report.agentId, on: db)
            try await applyObservedSnapshots(
                VMSnapshot.self, reported: reported, agentId: report.agentId, on: db)
            try await applyObservedSnapshots(
                SandboxSnapshot.self, reported: reported, agentId: report.agentId, on: db)
        }

        return unrecognizedOutcome
    }

    private func applyObservedLoadBalancers(
        _ observations: [ObservedLoadBalancerState], on db: PostgresStoreContext
    ) async throws {
        for observed in observations {
            try await db.transaction { tx in
                guard let loadBalancer = try await LegacyLoadBalancerStore.locked(
                    id: observed.id, on: tx)
                else {
                    return
                }
                // A delayed report may describe a superseded desired row; it
                // must not make the current generation look converged. A value
                // ahead of the database indicates a rollback/split-brain and
                // is equally unsafe to apply.
                guard observed.observedGeneration <= loadBalancer.generation,
                    observed.observedGeneration >= loadBalancer.observedGeneration
                else { return }

                let observedState: LoadBalancerObservedState =
                    switch observed.status {
                    case .pending: .pending
                    case .active: .active
                    case .error: .error
                    }
                _ = try await LegacyLoadBalancerStore.updateObserved(
                    id: observed.id,
                    observedGeneration: observed.observedGeneration,
                    observedState: observedState,
                    lastError: observed.lastError,
                    on: tx)

                for backendObservation in observed.backends {
                    let healthStatus: LoadBalancerBackendHealth =
                        switch backendObservation.healthStatus {
                        case .unknown: .unknown
                        case .online: .online
                        case .offline: .offline
                        case .error: .error
                        }
                    _ = try await LegacyLoadBalancerTargetStore.recordHealth(
                        id: backendObservation.id,
                        loadBalancerID: observed.id,
                        healthStatus: healthStatus,
                        lastHealthCheckAt: backendObservation.lastCheckedAt,
                        on: tx)
                }
            }
        }
    }

    // MARK: - Unrecognized workloads (STR-98)

    /// Decide what to do about the workloads an agent holds that its last sync
    /// did not list, and record each verdict as an `AgentWorkloadClaim`.
    ///
    /// This is the control-plane half of taking omission out of the
    /// destructive path. The agent no longer destroys what a sync forgot; it
    /// holds it and asks. Only one answer authorizes teardown:
    ///
    /// * **No row at all** — the workload really is a stray (its project was
    ///   deleted, its row was removed out of band). Tombstoned, at a
    ///   generation that outranks whatever the agent last applied.
    /// * **A row that maps to this very agent** — the sync that omitted it is
    ///   the bug. Never tombstoned, however many times it is reported.
    /// * **A row placed on another agent** — the node is very likely the same
    ///   host under a new `Agent` row (a re-enrollment, or a trust-domain
    ///   migration). Never tombstoned either: the fix is to re-point the
    ///   placement, which `AgentController.adoptWorkloads` does once an
    ///   operator confirms.
    ///
    /// Returns whether a tombstone was newly authorized or advanced, so the
    /// caller can nudge a sync rather than waiting a full period for it.
    private func applyUnrecognizedWorkloads(
        _ report: ObservedStateReport,
        on db: PostgresStoreContext
    ) async throws -> UnrecognizedOutcome {
        let existingClaims = try await workloads.claims(agentID: report.agentId)
            .map(AgentWorkloadClaimRecord.init)

        // Everything this report mentions at all: an id that has dropped out
        // of both lists is gone from the host, which retires its claim.
        var mentioned: Set<ResourceKey> = []
        for vm in report.vms { mentioned.insert(ResourceKey(kind: .virtualMachine, id: vm.vmId)) }
        for sandbox in report.sandboxes {
            mentioned.insert(ResourceKey(kind: .sandbox, id: sandbox.sandboxId))
        }
        for entry in report.unrecognized {
            mentioned.insert(ResourceKey(kind: entry.kind.resourceKind, id: entry.workloadId))
        }

        var claimsByKey = Dictionary(
            existingClaims.map { (ResourceKey(kind: $0.resourceKind, id: $0.resourceID), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Retire claims for workloads the host no longer has: the tombstoned
        // ones because the teardown converged, the held ones because whatever
        // was holding them is over.
        var staleClaims = claimsByKey.filter { !mentioned.contains($0.key) }

        // Also retire a tombstone whose record has come back — a restored
        // database, an operator re-creating the row. The workload is described
        // again, so this sync lists it and the agent's own diff would ignore
        // the tombstone anyway; leaving the claim would ship a contradictory
        // "keep this / destroy this" pair on every sync forever.
        let reportedUnrecognized = Set(
            report.unrecognized.map { ResourceKey(kind: $0.kind.resourceKind, id: $0.workloadId) })
        let revivable = claimsByKey.filter {
            $0.value.disposition == .tombstoned && !reportedUnrecognized.contains($0.key)
                && !staleClaims.keys.contains($0.key)
        }
        if !revivable.isEmpty {
            var revived: Set<ResourceKey> = []
            let vmCandidates = revivable.keys.filter { $0.kind == .virtualMachine }.map(\.id)
            if !vmCandidates.isEmpty {
                for id in try await LegacyVMStore.vms(ids: vmCandidates, on: db).compactMap(\.id) {
                    revived.insert(ResourceKey(kind: .virtualMachine, id: id))
                }
            }
            let sandboxCandidates = revivable.keys.filter { $0.kind == .sandbox }.map(\.id)
            if !sandboxCandidates.isEmpty {
                for id in try await LegacySandboxStore.sandboxes(
                    ids: sandboxCandidates, on: db).compactMap(\.id)
                {
                    revived.insert(ResourceKey(kind: .sandbox, id: id))
                }
            }
            for (key, claim) in revivable where revived.contains(key) {
                staleClaims[key] = claim
            }
        }

        // One delete for the whole set: a database restored from backup makes
        // a 500-VM host report 500 strays at once, and this runs on every
        // report, ahead of the reconciliation it precedes.
        if !staleClaims.isEmpty {
            _ = try await workloads.deleteClaims(ids: staleClaims.values.map(\.id))
            for (key, claim) in staleClaims {
                claimsByKey.removeValue(forKey: key)
                app.logger.info(
                    "Agent no longer holds a workload it claimed; claim retired",
                    metadata: [
                        "agentId": .string(report.agentId),
                        "resourceKind": .string(key.kind.rawValue),
                        "resourceId": .string(key.id.uuidString),
                        "disposition": .string(claim.disposition.rawValue),
                    ])
            }
        }

        // Held claims this report doesn't re-decide keep the disposition they
        // already have; the loop below adds the ones it decides. Counted so
        // the gauge answers "is this still happening", which the transition
        // counter cannot.
        var outcome = UnrecognizedOutcome()
        for (key, claim) in claimsByKey
        where claim.disposition == .held && !reportedUnrecognized.contains(key) {
            outcome.heldByReason[claim.reasonBucket, default: 0] += 1
        }
        guard !report.unrecognized.isEmpty else { return outcome }

        // One query per kind for the rows behind the reported ids — including
        // rows placed on *other* agents, which is the whole re-point signal.
        let vmIDs = report.unrecognized.filter { $0.kind == .vm }.map(\.workloadId)
        let sandboxIDs = report.unrecognized.filter { $0.kind == .sandbox }.map(\.workloadId)
        var vmPlacements: [UUID: WorkloadPlacement] = [:]
        if !vmIDs.isEmpty {
            for vm in try await LegacyVMStore.vms(ids: vmIDs, on: db) {
                guard let id = vm.id else { continue }
                vmPlacements[id] = WorkloadPlacement(agentId: vm.hypervisorId)
            }
        }
        var sandboxPlacements: [UUID: WorkloadPlacement] = [:]
        if !sandboxIDs.isEmpty {
            for sandbox in try await LegacySandboxStore.sandboxes(ids: sandboxIDs, on: db) {
                guard let id = sandbox.id else { continue }
                sandboxPlacements[id] = WorkloadPlacement(agentId: sandbox.hypervisorId)
            }
        }
        let volumeIDs = report.unrecognized.filter { $0.kind == .volume }.map(\.workloadId)
        var volumePlacements: [UUID: WorkloadPlacement] = [:]
        if !volumeIDs.isEmpty {
            let replicas = try await VolumeService.replicas(volumeIDs: volumeIDs, on: db)
            for volumeID in volumeIDs {
                guard let rows = replicas[volumeID] else { continue }
                let placed = rows.first(where: { $0.agentId == report.agentId }) ?? rows.first
                volumePlacements[volumeID] = WorkloadPlacement(agentId: placed?.agentId)
            }
        }

        // Snapshot artifacts (STR-150). One map across the three families,
        // populated per family from its own table: ids are UUIDs, so an id can
        // only ever belong to one, and merging them here keeps the lookup below
        // a single expression per kind rather than three near-identical ones.
        var snapshotPlacements: [UUID: WorkloadPlacement] = [:]
        try await collectSnapshotPlacements(
            VolumeSnapshot.self, kind: .volumeSnapshot, from: report, into: &snapshotPlacements, on: db)
        try await collectSnapshotPlacements(
            VMSnapshot.self, kind: .vmCheckpoint, from: report, into: &snapshotPlacements, on: db)
        try await collectSnapshotPlacements(
            SandboxSnapshot.self, kind: .sandboxSnapshot, from: report, into: &snapshotPlacements, on: db)

        // New claims accumulate for one batched create at the end — see the
        // stale-delete note above for why this path can't afford a round trip
        // per workload.
        var newClaims: [AgentWorkloadClaimWrite] = []
        for entry in report.unrecognized {
            let key = ResourceKey(kind: entry.kind.resourceKind, id: entry.workloadId)
            // An exhaustive switch, not a ternary: the two-kind ternary this
            // replaces would have silently bucketed a volume entry into the
            // sandbox lookup, and "no sandbox row with that id" reads as "no
            // row at all" — which is what authorizes a teardown.
            let placement: WorkloadPlacement?
            switch entry.kind {
            case .vm: placement = vmPlacements[entry.workloadId]
            case .sandbox: placement = sandboxPlacements[entry.workloadId]
            case .volume: placement = volumePlacements[entry.workloadId]
            case .volumeSnapshot: placement = snapshotPlacements[entry.workloadId]
            case .vmCheckpoint: placement = snapshotPlacements[entry.workloadId]
            case .sandboxSnapshot: placement = snapshotPlacements[entry.workloadId]
            }
            let existing = claimsByKey[key]

            guard let placement else {
                // No row: teardown is authorized. The generation must outrank
                // what the agent last applied, or its staleness guard drops
                // the tombstone and the stray would be held forever.
                let generation = max(entry.observedGeneration + 1, existing?.tombstoneGeneration ?? 0)
                let changed =
                    existing?.disposition != .tombstoned || existing?.tombstoneGeneration != generation
                try await upsertClaim(
                    existing,
                    agentId: report.agentId,
                    key: key,
                    disposition: .tombstoned,
                    tombstoneGeneration: generation,
                    reason: nil,
                    entry: entry,
                    pendingCreates: &newClaims)
                if changed {
                    outcome.authorizedTeardown = true
                    app.logger.notice(
                        "Agent holds a workload with no control-plane record; authorizing teardown",
                        metadata: [
                            "agentId": .string(report.agentId),
                            "resourceKind": .string(key.kind.rawValue),
                            "resourceId": .string(key.id.uuidString),
                            "observedStatus": .string(entry.status ?? "unknown"),
                            "tombstoneGeneration": .stringConvertible(generation),
                        ])
                    Telemetry.workloadTombstoned(kind: key.kind.rawValue)
                }
                continue
            }

            // A row exists. Nothing here can authorize a teardown — this is
            // the control plane failing to describe a workload it owns, and
            // destroying it would be acting on our own bug.
            let onThisAgent = placement.agentId == report.agentId
            let reason =
                onThisAgent
                ? AgentWorkloadClaim.heldRowPresentReason
                : AgentWorkloadClaim.heldOnOtherAgentReason(placement.agentId ?? "none")
            try await upsertClaim(
                existing,
                agentId: report.agentId,
                key: key,
                disposition: .held,
                tombstoneGeneration: nil,
                reason: reason,
                entry: entry,
                pendingCreates: &newClaims)
            outcome.heldByReason[
                onThisAgent
                    ? AgentWorkloadClaim.heldRowPresentReason
                    : AgentWorkloadClaim.heldOtherAgentBucket, default: 0] += 1
            if existing?.disposition != .held || existing?.reason != reason {
                app.logger.error(
                    onThisAgent
                        ? "Agent holds a workload its own desired-state sync omitted; withholding teardown (sync assembly bug)"
                        : "Agent holds a workload placed on a different agent record; withholding teardown (re-point required)",
                    metadata: [
                        "agentId": .string(report.agentId),
                        "resourceKind": .string(key.kind.rawValue),
                        "resourceId": .string(key.id.uuidString),
                        "placedOnAgentId": .string(placement.agentId ?? "none"),
                        "observedStatus": .string(entry.status ?? "unknown"),
                    ])
                Telemetry.workloadTeardownWithheld(
                    reason: onThisAgent
                        ? AgentWorkloadClaim.heldRowPresentReason
                        : AgentWorkloadClaim.heldOtherAgentBucket)
            }
        }
        if !newClaims.isEmpty {
            try await workloads.insertClaims(newClaims.map(\.native))
        }
        return outcome
    }

    /// Where a workload row currently says it lives, or nil when the row is
    /// gone. `agentId` nil means the row exists but was never placed.
    private struct WorkloadPlacement {
        let agentId: String?
    }

    /// Record one verdict, updating the existing claim in place so its
    /// `first_seen_at` keeps saying how long the situation has persisted.
    private func upsertClaim(
        _ existing: AgentWorkloadClaimRecord?,
        agentId: String,
        key: ResourceKey,
        disposition: WorkloadClaimDisposition,
        tombstoneGeneration: Int64?,
        reason: String?,
        entry: UnrecognizedWorkload,
        pendingCreates: inout [AgentWorkloadClaimWrite]
    ) async throws {
        guard let claim = existing else {
            pendingCreates.append(
                AgentWorkloadClaimWrite(
                    agentId: agentId,
                    resourceKind: key.kind,
                    resourceID: key.id,
                    disposition: disposition,
                    tombstoneGeneration: tombstoneGeneration,
                    reason: reason,
                    observedGeneration: entry.observedGeneration,
                    observedStatus: entry.status
                ))
            return
        }
        guard
            claim.disposition != disposition
                || claim.tombstoneGeneration != tombstoneGeneration
                || claim.reason != reason
                || claim.observedGeneration != entry.observedGeneration
                || claim.observedStatus != entry.status
        else { return }  // unchanged: don't churn the row on every report
        try await workloads.updateClaim(
            id: claim.id,
            disposition: disposition,
            tombstoneGeneration: tombstoneGeneration,
            reason: reason,
            observedGeneration: entry.observedGeneration,
            observedStatus: entry.status)
    }

    /// Apply one settled (or failing) observation to its VM row and record the
    /// convergence transition it produces.
    private func applyObservedVMState(
        vm: VM,
        observed: ObservedVMState,
        interfaces: [VMNetworkInterface],
        observedAddressesByInterfaceID: [UUID: [ObservedInterfaceAddressSnapshot]],
        bootVolumes: [BootVolumeDependency]?,
        on db: PostgresStoreContext
    ) async throws {
        var current = vm
        let vmID = try current.requireID()
        try logSupersededFailureReport(current, reportedGeneration: observed.failedGeneration)

        // Where the VM stood before this report. Every convergence outcome
        // below is a *transition* out of this state, which is what makes the
        // completion webhook fire exactly once without a side-table row to
        // compare-and-swap on (STR-147): `observedGeneration` only moves
        // forward, and the write that closes the transition commits with the
        // outbox row inside `recordSuccess`/`recordFailure`.
        //
        // `failedBefore` has to be captured here too, because `recordConvergence`
        // below mirrors the agent's own `failedGeneration` onto the in-memory
        // model — after which it can no longer say whether *we* had already
        // recorded the failure. It must stay in memory until the transition
        // call persists it: committing the mirror on its own would satisfy the
        // guard with nothing recorded, and no later pass would re-enter.
        let wasConverged = current.isConverged
        let failedBefore = current.failedGeneration

        // The guest-agent view (issue #563) is orthogonal to convergence and
        // operation completion, so record it up front — before the converging
        // early-return below. A present `guestInfo` is persisted; a nil one on a
        // VM the agent observes definitively *not running* clears the stale view
        // (a stopped VM also drops out of the agent's poll cache and reports
        // nil, so without this its "guest agent connected" state would persist
        // forever). A nil on a running/paused/transitional/unknown VM is left
        // alone — that's a transient probe miss, and nil-preserves-last-known.
        if let guestInfo = observed.guestInfo {
            current = try await persistGuestInfo(
                vm: current,
                guestInfo: guestInfo,
                interfaces: interfaces,
                observedAddressesByInterfaceID: observedAddressesByInterfaceID,
                on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            current = try await clearGuestInfo(vm: current, interfaces: interfaces, on: db)
        }

        // Balloon memory stats (issue #567) follow the same contract as
        // guestInfo, independently: a guest can report balloon stats without
        // qga (and vice versa), so their presence is tracked separately.
        if let memoryStats = observed.memoryStats {
            current = try await persistMemoryStats(vm: current, stats: memoryStats, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            current = try await clearMemoryStats(vm: current, on: db)
        }

        // Mirror the report's convergence progress onto the row (STR-142) so
        // the API can project it as the VM's `conditions` block. Recorded on
        // both the converging and settled paths — the phase only exists on the
        // former, and the error pair has to be *cleared* on the latter.
        let bootVolumePhase: String?
        if let bootVolumes, observed.convergencePhase == nil, observed.lastError == nil,
            current.desiredStatus != .absent
        {
            bootVolumePhase = pendingBootVolumePhase(for: current, bootVolumes: bootVolumes)
        } else {
            bootVolumePhase = nil
        }
        let effectivePhase = observed.convergencePhase ?? bootVolumePhase
        let convergence = current.recordingTimestampedConvergence(
            phase: effectivePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )
        current = convergence.resource
        var changed = convergence.changed

        // Still converging: progress only. The status is not settled, so it
        // must not overwrite the row or complete operations.
        if effectivePhase != nil {
            if changed {
                try await current.persist(on: db)
            }
            app.logger.debug(
                "VM converging on agent",
                metadata: [
                    "vmId": .string(vmID.uuidString),
                    "phase": .string(effectivePhase ?? ""),
                    "targetGeneration": .stringConvertible(current.generation),
                ])
            return
        }

        if observed.observedGeneration > current.observedGeneration {
            current.observedGeneration = observed.observedGeneration
            changed = true
        }

        // A detach releases its address only after the agent's durable manifest
        // says the target generation no longer contains the interface. The
        // generation check rejects a stale report; the explicit id set rejects
        // the more dangerous interpretation of silence as absence.
        if let appliedInterfaceIDs = observed.appliedNetworkInterfaceIds {
            let applied = Set(appliedInterfaceIDs)
            for interface in interfaces {
                guard let detachGeneration = interface.detachGeneration,
                    observed.observedGeneration >= detachGeneration,
                    let interfaceID = interface.id,
                    !applied.contains(interfaceID)
                else { continue }
                _ = try await LegacyVMNetworkInterfaceStore.delete(id: interfaceID, on: db)
            }
        }

        var statusTransition: (previous: VMStatus, current: VMStatus)?
        if current.status != observed.status,
            observed.status != .unknown || current.status.isTransitional
        {
            let previous = current.status
            current.setStatus(observed.status)
            changed = true
            statusTransition = (previous, observed.status)

            // Drift telemetry: an out-of-band change on an already-converged VM
            // (nothing in flight asked for anything) means agent reality moved
            // on its own — e.g. a guest powered itself off, or someone paused
            // it over QMP.
            if wasConverged, !previous.isTransitional {
                app.logger.warning(
                    "VM state drifted with nothing in flight",
                    metadata: [
                        "vmId": .string(vmID.uuidString),
                        "previousStatus": .string(previous.rawValue),
                        "observedStatus": .string(observed.status.rawValue),
                    ])
                Telemetry.vmDriftDetected()
            }
        }
        if current.desiredSatisfied, current.divergenceDetectedAt != nil {
            current.divergenceDetectedAt = nil
            changed = true
        }

        let failedCurrentGeneration =
            observed.lastError != nil && observed.failedGeneration == current.generation
        // No deadline means no user mutation is outstanding. This is a
        // steady-state repair failure: persist exactly what the agent observed,
        // but retain the desired state and generation so the level-triggered
        // loop can heal it later. In particular, do not synthesize a stale
        // mutation outcome from whichever resource event happens to be latest.
        if failedCurrentGeneration, current.convergenceDeadline == nil {
            if changed {
                try await current.persist(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: current, on: db)
            return
        }
        // Deletions are settled by absence from the report, never by a status.
        //
        // The save is deferred to the transition below where there is one:
        // `recordSuccess`/`recordFailure` persist the model inside the same
        // transaction as the outbox row, and this report's changes include the
        // mirrored `failedGeneration` that would otherwise suppress every
        // future pass if it committed alone.
        let settlesConvergence =
            current.desiredStatus != .absent
            && ((!wasConverged && current.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == current.generation))
        if !settlesConvergence {
            if changed {
                try await current.persist(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: current, on: db)
            return
        }

        if !wasConverged, current.isConverged {
            // The agent converged to the current generation and the observed
            // status satisfies the desired one: everything outstanding reached
            // its goal.
            let result = try await ResourceConvergence.recordValueSuccess(current, on: db)
            current = result.resource
            await emitVMStatusTransition(statusTransition, vm: current, on: db)
        } else if let lastError = observed.lastError,
            observed.failedGeneration == current.generation
        {
            // The agent tried to converge to *this* generation and failed —
            // the failedGeneration match is what distinguishes that from a
            // stale error still carried on heartbeats while a newer mutation
            // waits for its first attempt. Report the real reason instead of
            // waiting out the convergence deadline.
            //
            // `recordFailure` resolves the in-flight state and realigns desired
            // with observed, so the unachieved intent does not linger and
            // replay on a later sync; its `failedGeneration` guard is what
            // keeps the failure webhook to one per generation, however many
            // reports repeat the error.
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: .virtualMachine, resourceID: vmID, on: db
                )?.mutation ?? .boot

            // A VM with no settled presence on the agent (e.g. a create that
            // never got off the ground) is surfaced as `.error` rather than
            // left in a healthy-looking resting state — and *before*
            // `recordFailure`, because the realignment of desired state it
            // performs reads the status. Gated on the same guard
            // `recordFailure` applies, so a repeated report of an
            // already-recorded failure changes nothing.
            let previousStatus = current.status
            var enteredError = false
            if failedBefore != current.generation,
                observed.status == .unknown, current.status != .error
            {
                current.setStatus(.error)
                enteredError = true
                Telemetry.vmEnteredError(reason: "convergence_failed")
            }

            let result = try await ResourceConvergence.recordValueFailure(
                current, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            current = result.resource
            if result.outcome == .alreadyRecorded, changed {
                // A repeat of an already-recorded failure: nothing was
                // persisted by the call above, so this report's own changes
                // (observed generation, status) still need writing.
                try await current.persist(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: current, on: db)
            if result.outcome == .recorded, enteredError {
                await WebhookEvents.emitVMStateChanged(
                    vm: current, previous: previousStatus, current: .error, on: db, logger: app.logger)
            }
        }
    }

    /// The control-plane half of the managed boot-volume dependency (STR-242).
    ///
    /// The agent prevents the unsafe boot. This gate prevents the independent VM
    /// generation from being declared successful while the volume resource is
    /// still provisioning or degraded, or while its measured virtual size is
    /// smaller than the request. The requested size is a floor: a source image
    /// can have a larger native virtual size, and that is already a usable boot
    /// volume. A dependency failure remains a phase, not a VM failure: volume
    /// reconciliation is level-triggered and can repair a transient delay at
    /// the same generation without a stop or a second start.
    private func pendingBootVolumePhase(
        for vm: VM, bootVolumes: [BootVolumeDependency]
    ) -> String? {
        guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
            return "waiting for exactly one canonical managed boot volume"
        }

        let prefix = "waiting for boot volume \(bootVolume.id.uuidString)"
        if let degradedReason = bootVolume.degradedReason {
            return "\(prefix): \(degradedReason)"
        }
        guard let observedSize = bootVolume.observedSize else {
            return "\(prefix): the agent has not reported its virtual size"
        }
        guard observedSize == bootVolume.desiredSize else {
            return "\(prefix): observed \(observedSize) of \(bootVolume.desiredSize) admitted bytes"
        }
        guard bootVolume.converged else {
            return "\(prefix) to converge to generation \(bootVolume.generation)"
        }
        guard bootVolume.status == .attached,
            bootVolume.attachedAgentID == vm.hypervisorId
        else {
            return "\(prefix) to become healthy and attached on this VM's agent"
        }
        return nil
    }

    /// Emits `vm.state_changed` for an observed status transition, once the
    /// write that produced it has committed. Best-effort by contract, so it is
    /// deliberately outside the convergence transaction: a webhook that cannot
    /// be enqueued must not roll back the observation it describes.
    private func emitVMStatusTransition(
        _ transition: (previous: VMStatus, current: VMStatus)?, vm: VM, on db: PostgresStoreContext
    ) async {
        guard let transition else { return }
        await WebhookEvents.emitVMStateChanged(
            vm: vm, previous: transition.previous, current: transition.current,
            on: db, logger: app.logger)
    }

    /// Persists a VM's observed guest-agent view (issue #563): the VM-level
    /// hostname/availability flags and, per NIC (matched by MAC), the addresses
    /// the guest actually configured. Best-effort and additive — it never
    /// clears data on a nil report, so a momentary probe miss doesn't wipe the
    /// last-known view; a NIC's rows are reconciled wholesale only when the
    /// guest's set actually differs from what's stored, so unchanged reports do
    /// no writes.
    private func persistGuestInfo(
        vm: VM,
        guestInfo: GuestInfo,
        interfaces: [VMNetworkInterface],
        observedAddressesByInterfaceID: [UUID: [ObservedInterfaceAddressSnapshot]],
        on db: PostgresStoreContext
    ) async throws -> VM {
        var current = vm
        var vmChanged = false
        if current.qgaAvailable != guestInfo.qgaAvailable {
            current.qgaAvailable = guestInfo.qgaAvailable
            vmChanged = true
        }
        if current.observedHostname != guestInfo.hostname {
            current.observedHostname = guestInfo.hostname
            vmChanged = true
        }
        if vmChanged {
            try await current.persist(on: db)
        }

        // Group the guest's addresses by MAC (lowercased for case-insensitive
        // matching against the stored NIC MAC).
        var addressesByMAC: [String: [GuestIPAddress]] = [:]
        for iface in guestInfo.interfaces {
            guard let mac = iface.hardwareAddress?.lowercased() else { continue }
            addressesByMAC[mac, default: []].append(contentsOf: iface.addresses)
        }

        for nic in interfaces {
            let nicID = try nic.requireID()
            // Dedupe by (family, address): a guest can list link-local twice,
            // and the unique index would reject the duplicate row.
            var seen: Set<String> = []
            let desired = (addressesByMAC[nic.macAddress.lowercased()] ?? []).filter {
                seen.insert("\($0.family.rawValue)|\($0.address)").inserted
            }

            let storedKeys = Set(
                (observedAddressesByInterfaceID[nicID] ?? []).map {
                    "\($0.family)|\($0.address)|\($0.prefixLength.map(String.init) ?? "")"
                })
            let desiredKeys = Set(
                desired.map { "\($0.family.rawValue)|\($0.address)|\($0.prefixLength.map(String.init) ?? "")" })
            if storedKeys == desiredKeys { continue }

            try await workloads.replaceObservedInterfaceAddresses(
                interfaceID: nicID,
                addresses: desired.map {
                    ObservedInterfaceAddressWrite(
                        family: $0.family.rawValue,
                        address: $0.address,
                        prefixLength: $0.prefixLength)
                })
        }
        return current
    }

    /// Persists a VM's observed balloon memory stats (issue #567), stamping
    /// the report time. Skips the write when the numbers are unchanged (the
    /// steady state for an idle guest) so the report stream doesn't churn the
    /// row — which means `guestMemoryStatsAt` records when the values last
    /// *changed*, a freshness signal that survives unchanged reports.
    private func persistMemoryStats(
        vm: VM, stats: VMMemoryStats, on db: PostgresStoreContext
    ) async throws -> VM {
        guard
            vm.guestMemoryTotalBytes != stats.totalBytes
                || vm.guestMemoryAvailableBytes != stats.availableBytes
                || vm.guestMemoryBalloonActualBytes != stats.balloonActualBytes
        else { return vm }
        var updated = vm
        updated.guestMemoryTotalBytes = stats.totalBytes
        updated.guestMemoryAvailableBytes = stats.availableBytes
        updated.guestMemoryBalloonActualBytes = stats.balloonActualBytes
        updated.guestMemoryStatsAt = Date()
        try await updated.persist(on: db)
        return updated
    }

    /// Clears a VM's observed memory stats once the guest is definitively not
    /// running — a stopped guest's last-known usage is stale, and surfacing it
    /// as current would mislead the "committed vs used" view.
    private func clearMemoryStats(vm: VM, on db: PostgresStoreContext) async throws -> VM {
        guard
            vm.guestMemoryTotalBytes != nil || vm.guestMemoryAvailableBytes != nil
                || vm.guestMemoryBalloonActualBytes != nil
        else { return vm }
        var updated = vm
        updated.guestMemoryTotalBytes = nil
        updated.guestMemoryAvailableBytes = nil
        updated.guestMemoryBalloonActualBytes = nil
        updated.guestMemoryStatsAt = nil
        try await updated.persist(on: db)
        return updated
    }

    /// VM statuses for which a nil `guestInfo` should *clear* the stored qga
    /// view rather than preserve it: the guest is definitively not running, so
    /// its last-known hostname/addresses are stale. Running, paused,
    /// transitional, and unknown are deliberately excluded — a nil there is a
    /// transient probe miss, and nil-preserves-last-known keeps the UI stable.
    /// The balloon memory stats (issue #567) share this contract.
    private static let guestInfoClearedByStatus: Set<VMStatus> = [.shutdown, .created, .error]

    /// Clears a VM's observed guest-agent state (hostname, availability, and all
    /// per-NIC observed addresses). Short-circuits when there's nothing recorded
    /// so it's a no-op on the steady stream of reports for a VM that never had a
    /// guest agent.
    private func clearGuestInfo(
        vm: VM,
        interfaces: [VMNetworkInterface],
        on db: PostgresStoreContext
    ) async throws -> VM {
        guard vm.qgaAvailable != nil || vm.observedHostname != nil else { return vm }
        var updated = vm
        updated.qgaAvailable = nil
        updated.observedHostname = nil
        try await updated.persist(on: db)

        let nicIDs = interfaces.compactMap(\.id)
        if !nicIDs.isEmpty {
            _ = try await workloads.deleteObservedInterfaceAddresses(interfaceIDs: nicIDs)
        }
        return updated
    }

    /// A VM the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedAbsence(
        vm: VM,
        agentId: String,
        on db: PostgresStoreContext
    ) async throws {
        var current = vm
        let vmID = try current.requireID()

        if current.desiredStatus == .absent {
            // Teardown confirmed: this is the `agent.absent` finalizer's
            // participant (ADR 0001). Nothing is recorded *here* — the reap
            // that clearing the last token triggers appends the terminal
            // `resource_events` row, which is what tells a client polling a
            // delete that it finished (STR-147).
            switch try await ResourceFinalizerService.clear(
                .agentAbsent, from: current, on: db, app: app)
            {
            case .reaped:
                app.logger.info(
                    "VM deletion confirmed by agent report; record removed",
                    metadata: ["vmId": .string(vmID.uuidString), "agentId": .string(agentId)])
            case .held(let remaining):
                // Other participants still owe cleanup. Logged on every report
                // until they finish, so this stays at debug.
                app.logger.debug(
                    "VM teardown confirmed by agent report; awaiting finalizers",
                    metadata: [
                        "vmId": .string(vmID.uuidString), "agentId": .string(agentId),
                        "finalizers": .string(remaining.joined(separator: ",")),
                    ])
            case .alreadyGone, .notTerminating:
                // Raced another reaper, or the row went between the query and
                // here. Nothing to say: whoever removed it logged the removal.
                break
            }
            return
        }

        // A report lists everything the agent is converging or has failed to
        // converge, so an omitted VM has no progress to report at all — most
        // often because the agent restarted and lost its in-memory view. Drop
        // whatever it last said, rather than leave `conditions` claiming a
        // download that nothing is doing (STR-142).
        let convergence = current.recordingTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)
        current = convergence.resource

        // Same established-state rule as the heartbeat reconciliation: only
        // states that assert live agent presence are safe to escalate on
        // absence. (`.created` may be mid-create on an agent that hasn't
        // received the sync yet.) The reconcile loop will re-create the VM on
        // its next sync; if it succeeds, a later report restores the status.
        guard current.status.assertsAgentPresence else {
            if convergence.changed {
                try await current.persist(on: db)
            }
            return
        }

        let previous = current.status
        current.setStatus(.error)
        try await current.persist(on: db)
        Telemetry.vmEnteredError(reason: "reconciliation")
        await WebhookEvents.emitVMStateChanged(
            vm: current, previous: previous, current: .error, on: db, logger: app.logger)
        app.logger.warning(
            "VM missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "vmId": .string(vmID.uuidString),
                "agentId": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

    /// Sandbox counterpart of `applyObservedVMState`: apply one settled (or
    /// failing) observation and record the convergence transition it produces.
    private func applyObservedSandboxState(
        sandbox: Sandbox,
        observed: ObservedSandboxState,
        on db: PostgresStoreContext
    ) async throws {
        var current = sandbox
        let sandboxID = try current.requireID()
        try logSupersededFailureReport(current, reportedGeneration: observed.failedGeneration)
        let wasConverged = current.isConverged
        let failedBefore = current.failedGeneration

        // Convergence progress for the `conditions` block (STR-142) — same
        // contract as VMs, recorded on both paths for the same reasons.
        let convergence = current.recordingTimestampedConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )
        current = convergence.resource
        var changed = convergence.changed

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await current.persist(on: db)
            }
            app.logger.debug(
                "Sandbox converging on agent",
                metadata: [
                    "sandboxId": .string(sandboxID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(current.generation),
                ])
            return
        }

        if observed.observedGeneration > current.observedGeneration {
            current.observedGeneration = observed.observedGeneration
            changed = true
        }

        if current.status != observed.status, observed.status != .unknown || current.status.isTransitional {
            let previous = current.status
            current.setStatus(observed.status)
            changed = true

            // A workload finishing on its own (`.exited`) is the normal end
            // of a one-shot sandbox, not drift — only flag other unprompted
            // changes.
            if wasConverged, !previous.isTransitional, observed.status != .exited {
                app.logger.warning(
                    "Sandbox state drifted with nothing in flight",
                    metadata: [
                        "sandboxId": .string(sandboxID.uuidString),
                        "previousStatus": .string(previous.rawValue),
                        "observedStatus": .string(observed.status.rawValue),
                    ])
            }
        }
        if current.exitCode != observed.exitCode {
            current.exitCode = observed.exitCode
            changed = true
        }
        if current.desiredSatisfied, current.divergenceDetectedAt != nil {
            current.divergenceDetectedAt = nil
            changed = true
        }

        let failedCurrentGeneration =
            observed.lastError != nil && observed.failedGeneration == current.generation
        // A failure with no deadline belongs to steady-state repair, not to a
        // pending mutation. Keep intent and generation intact and emit no
        // operation outcome; a later same-generation retry can still recover.
        if failedCurrentGeneration, current.convergenceDeadline == nil {
            if changed {
                try await current.persist(on: db)
            }
            return
        }
        // Deletions are settled by absence from the report, never by a status.
        // The save is deferred to the transition where there is one, for the
        // reason the VM path defers it.
        let settlesConvergence =
            current.desiredStatus != .absent
            && ((!wasConverged && current.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == current.generation))
        if !settlesConvergence {
            if changed {
                try await current.persist(on: db)
            }
            return
        }

        if !wasConverged, current.isConverged {
            _ = try await ResourceConvergence.recordValueSuccess(current, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == current.generation {
            // The agent tried to converge to *this* generation and failed —
            // report the real reason instead of waiting out the convergence
            // deadline (same contract as VMs, including the pre-escalation of a
            // sandbox with no settled presence on the agent).
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: .sandbox, resourceID: sandboxID, on: db
                )?.mutation ?? .boot
            if failedBefore != current.generation, observed.status == .unknown {
                current.setStatus(.error)
            }
            let result = try await ResourceConvergence.recordValueFailure(
                current, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if result.outcome == .alreadyRecorded, changed {
                try await current.persist(on: db)
            }
        }
    }

    /// A sandbox the database maps to this agent is absent from its full
    /// report: either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedSandboxAbsence(
        sandbox: Sandbox,
        agentId: String,
        on db: PostgresStoreContext
    ) async throws {
        var current = sandbox
        let sandboxID = try current.requireID()

        if current.desiredStatus == .absent {
            // Teardown confirmed: the `agent.absent` participant. The reap
            // appends the terminal event, same as VMs.
            switch try await ResourceFinalizerService.clear(
                .agentAbsent, from: current, on: db, app: app)
            {
            case .reaped:
                app.logger.info(
                    "Sandbox deletion confirmed by agent report; record removed",
                    metadata: ["sandboxId": .string(sandboxID.uuidString), "agentId": .string(agentId)])
            case .held(let remaining):
                app.logger.debug(
                    "Sandbox teardown confirmed by agent report; awaiting finalizers",
                    metadata: [
                        "sandboxId": .string(sandboxID.uuidString), "agentId": .string(agentId),
                        "finalizers": .string(remaining.joined(separator: ",")),
                    ])
            case .alreadyGone, .notTerminating:
                break
            }
            return
        }

        // Nothing to report means no progress to report — same rationale as
        // the VM path (STR-142).
        let convergence = current.recordingTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)
        current = convergence.resource

        // Only escalate established sandboxes: a never-confirmed row
        // (observedGeneration 0) may be mid-create on an agent that hasn't
        // received the sync yet, and non-presence-asserting states are owned
        // by the sweep.
        guard current.observedGeneration > 0, current.status.assertsAgentPresence else {
            if convergence.changed {
                try await current.persist(on: db)
            }
            return
        }

        let previous = current.status
        current.setStatus(.error)
        try await current.persist(on: db)
        app.logger.warning(
            "Sandbox missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "sandboxId": .string(sandboxID.uuidString),
                "agentId": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

    // MARK: - Volumes (STR-148)

    /// Volume counterpart of `applyObservedVMState`. Same shape and the same
    /// transition rules; what differs is that a volume's status is *entirely*
    /// derived here, since the control plane no longer writes a transitional
    /// status of its own before dispatching anything.
    private func applyObservedVolumeState(
        volume: Volume,
        observed: ObservedVolumeState,
        agentId: String,
        on db: PostgresStoreContext
    ) async throws -> Bool {
        var current = volume
        let volumeID = try current.requireID()
        try logSupersededFailureReport(current, reportedGeneration: observed.failedGeneration)
        // Captured before anything mutates, for exactly the reasons the VM
        // path documents: `recordConvergence` mirrors the agent's own
        // `failedGeneration` onto the model and would otherwise satisfy the
        // idempotence guard with nothing recorded.
        let wasConverged = current.isConverged
        let failedBefore = current.failedGeneration

        try await recordReplicaObservation(
            volumeID: volumeID, agentId: agentId, observed: observed,
            desiredGeneration: current.generation, on: db)
        let requiredReplicas = try await LegacyVolumeReplicaStore.replicas(
            volumeIDs: [volumeID],
            states: VolumeService.authoritativeReplicaStates,
            on: db
        )
        let allReplicasSettled =
            !requiredReplicas.isEmpty
            && requiredReplicas.allSatisfy {
                $0.state == .healthy && $0.generation >= current.generation
            }
        let generationBeforeTarget = max(0, current.generation - 1)
        let aggregateObservedGeneration =
            requiredReplicas.map { replica in
                replica.state == .healthy
                    ? replica.generation : min(replica.generation, generationBeforeTarget)
            }.min() ?? 0
        let failedAtTarget =
            observed.lastError != nil && observed.failedGeneration == current.generation
        let nextPhase: String?
        let nextError: String?
        let nextFailedGeneration: Int64?
        if failedAtTarget {
            nextPhase = observed.convergencePhase
            nextError = observed.lastError
            nextFailedGeneration = observed.failedGeneration
        } else if allReplicasSettled {
            nextPhase = nil
            nextError = nil
            nextFailedGeneration = nil
        } else {
            nextPhase = observed.convergencePhase ?? "waiting for replicas"
            nextError = current.errorMessage
            nextFailedGeneration = current.failedGeneration
        }
        let convergence = current.recordingConvergence(
            phase: nextPhase,
            lastError: nextError,
            failedGeneration: nextFailedGeneration
        )
        current = convergence.resource
        var changed = convergence.changed

        // The size the image actually has (STR-199) — recorded here for the same
        // reason the path is, and with the same asymmetry as the applied I/O
        // ceilings below: it is a fact about the volume rather than a verdict on
        // the mutation, so it lands before the converging early-return, and an
        // agent that reported *nothing* (pre-v38, or a probe that could not read
        // the image) leaves the column alone instead of clearing it. Writing nil
        // through would turn a silent agent into "this volume has no size",
        // which is the same wrong answer in the other direction.
        if let reported = observed.sizeBytes, current.observedSizeBytes != reported {
            current = current.replacing(observedSizeBytes: .some(reported))
            changed = true
        }

        // A managed boot volume is attached as part of VM creation, so it does
        // not pass through VolumeController.attachVolume's materialized-size
        // admission. When an image's native virtual size exceeds the request,
        // reserve that excess and make the measured size desired state before
        // either VM convergence gate may treat the disk as bootable. Advancing
        // the generation makes the agent confirm this normalized contract; its
        // exact-size boot gate keeps the guest stopped until that confirmation.
        var normalizedDesiredSize = false
        if current.volumeType == .boot,
            current.sourceImageID != nil || current.sourceVolumeID != nil,
            observed.present,
            observed.convergencePhase == nil,
            observed.lastError == nil,
            let materializedSize = observed.sizeBytes,
            materializedSize > current.size
        {
            let admissionError: String?
            if materializedSize > WorkloadSizeLimits.maxDiskBytes {
                admissionError =
                    "Cannot admit the materialized boot volume at \(materializedSize) bytes: "
                    + "it exceeds the maximum supported volume size of "
                    + "\(WorkloadSizeLimits.maxDiskBytes) bytes."
            } else {
                do {
                    guard let project = try await Project.find(current.projectID, on: db) else {
                        throw Abort(
                            .internalServerError,
                            reason: "The boot volume's project no longer exists")
                    }
                    try await QuotaEnforcementService.reserveVolumeResize(
                        for: project,
                        environment: current.environment,
                        sizeDelta: materializedSize - current.size,
                        reason: "the materialized boot volume",
                        on: db)
                    admissionError = nil
                } catch let error as any AbortError {
                    admissionError =
                        "Cannot admit the materialized boot volume at \(materializedSize) bytes: "
                        + error.reason
                }
            }

            if let admissionError {
                let failed = current.recordingConvergence(
                    phase: nil, lastError: admissionError,
                    failedGeneration: current.generation)
                current = failed.resource
                changed = failed.changed || changed
            } else {
                let expectedGeneration = current.generation
                current = current.replacing(size: materializedSize)
                let advance = try await current.advancingDesiredStateGeneration(
                    expectedGeneration: expectedGeneration, on: db)
                guard case .applied = advance.outcome else {
                    throw ConvergenceWriteError.unsupportedDatabase
                }
                current = advance.resource.extendingConvergenceDeadline(
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
            if current.appliedIOPSTotal != applied.iopsTotal
                || current.appliedBPSTotal != applied.bpsTotal
            {
                current = current.replacing(
                    appliedIOPSTotal: .some(applied.iopsTotal),
                    appliedBPSTotal: .some(applied.bpsTotal))
                changed = true
            }
        }

        if aggregateObservedGeneration > current.observedGeneration {
            current = current.replacing(observedGeneration: aggregateObservedGeneration)
            changed = true
        }

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await current.save(on: db)
            }
            return normalizedDesiredSize
        }

        // Where the realized attachment runs. A detached report may clear only
        // this reporter's own attachment; a storage-only replica must not erase
        // the VM host's observation.
        if observed.attachedVMId != nil {
            if current.attachedAgentId != agentId {
                current = current.replacing(attachedAgentId: .some(agentId))
                changed = true
            }
        } else if current.attachedAgentId == agentId {
            current = current.replacing(attachedAgentId: .some(nil))
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
        } else if current.attachedAgentId != nil {
            derived = .attached
        } else {
            derived = .available
        }
        // `.snapshotting` is no longer written by anything (STR-150 made a
        // volume snapshot its own converging resource), so there is nothing
        // left to protect it from: the report is authoritative.
        if current.status != derived {
            current = current.replacing(status: derived)
            changed = true
        }
        let settlesConvergence =
            current.desiredStatus != .absent
            && ((!wasConverged && current.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == current.generation))
        if !settlesConvergence {
            if changed {
                try await current.save(on: db)
            }
            return normalizedDesiredSize
        }

        if !wasConverged, current.isConverged {
            _ = try await ResourceConvergence.recordValueSuccess(current, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == current.generation {
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: .volume, resourceID: volumeID, on: db
                )?.mutation ?? .create
            let outcome = try await ResourceConvergence.recordValueFailure(
                current, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if outcome.outcome == .alreadyRecorded, changed {
                try await current.save(on: db)
            }
        }
        return normalizedDesiredSize
    }

    /// The rows behind one family's reported-unrecognized ids, including rows
    /// placed on *other* agents — which is the whole re-point signal.
    private func collectSnapshotPlacements<A: SnapshotArtifactResource>(
        _ type: A.Type,
        kind: WorkloadKind,
        from report: ObservedStateReport,
        into placements: inout [UUID: WorkloadPlacement],
        on db: PostgresStoreContext
    ) async throws {
        let ids = report.unrecognized.filter { $0.kind == kind }.map(\.workloadId)
        guard !ids.isEmpty else { return }
        for artifact in try await A.matching(ids: ids, on: db) {
            guard let id = artifact.id else { continue }
            placements[id] = WorkloadPlacement(agentId: artifact.agentId)
        }
    }

    // MARK: - Snapshot artifacts (STR-150)

    /// One family's half of a report. Written once and applied three times:
    /// the diff, the convergence quartet, the derived status and the
    /// absent-then-reap dance are identical across the families, and only what
    /// the captured facts *mean* differs — which each model absorbs in
    /// `applyCapturedFacts`.
    private func applyObservedSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type,
        reported: [UUID: ObservedSnapshotState],
        agentId: String,
        on db: PostgresStoreContext
    ) async throws {
        for artifact in try await A.placed(onAgent: agentId, on: db) {
            guard let artifactID = artifact.id else { continue }
            if let observed = reported[artifactID] {
                // A kind mismatch means two families minted the same UUID,
                // which cannot happen — but routing an entry to the wrong table
                // would apply one family's facts to another's row, so it is
                // checked rather than assumed.
                guard observed.kind == A.artifactKind else { continue }
                try await withLockedCurrent(artifact, reportedBy: agentId, on: db) { artifact, tx in
                    try await applyObservedSnapshotState(
                        artifact: artifact, observed: observed, on: tx)
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
    private func applyObservedSnapshotState<A: SnapshotArtifactResource>(
        artifact initialArtifact: A,
        observed: ObservedSnapshotState,
        on db: PostgresStoreContext
    ) async throws {
        var artifact = initialArtifact
        let artifactID = try artifact.requireID()
        try logSupersededFailureReport(artifact, reportedGeneration: observed.failedGeneration)
        // Captured before anything mutates, for the reasons the VM path
        // documents: `recordConvergence` mirrors the agent's own
        // `failedGeneration` onto the model and would otherwise satisfy the
        // idempotence guard with nothing recorded.
        let wasConverged = artifact.isConverged
        let failedBefore = artifact.failedGeneration

        let convergence = artifact.recordingConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )
        artifact = convergence.resource
        var changed = convergence.changed

        // The captured facts — footprint, hypervisor version, fork layout,
        // architecture — are recorded before the converging early-return, and
        // this is the whole reason they moved onto the report. As an RPC reply
        // they were delivered once: a socket that dropped mid-flight lost them,
        // and the old paths had to treat that as a protocol error and mark a
        // checkpoint that in fact existed `.error`. A report is re-sent on every
        // heartbeat, so they simply arrive again.
        var footprintChanged = false
        if let facts = observed.facts {
            let capture = artifact.recordingCapturedFacts(facts)
            artifact = capture.resource
            if capture.changed {
                changed = true
                footprintChanged = true
            }
        }
        let export = artifact.recordingExported(observed.exported)
        artifact = export.resource
        if export.changed {
            changed = true
        }

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await artifact.persist(on: db)
            }
            return
        }

        if observed.observedGeneration > artifact.observedGeneration {
            artifact = artifact.replacingObservedGeneration(observed.observedGeneration)
            changed = true
        }

        // Status is derived, not reported: the agent describes the bytes, and
        // that fact plus the desired state is the whole status vocabulary an
        // artifact has.
        let failed = observed.lastError != nil
        let presence = artifact.recordingObservedPresence(present: observed.present, failed: failed)
        artifact = presence.resource
        if presence.changed {
            changed = true
        }

        let settlesConvergence =
            artifact.desiredStatus != .absent
            && ((!wasConverged && artifact.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == artifact.generation))
        if !settlesConvergence {
            if changed {
                try await artifact.persist(on: db)
            }
            return
        }

        if !wasConverged, artifact.isConverged {
            _ = try await ResourceConvergence.recordValueSuccess(artifact, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == artifact.generation {
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: A.operationResourceKind, resourceID: artifactID, on: db
                )?.mutation ?? .create
            let result = try await ResourceConvergence.recordValueFailure(
                artifact, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            artifact = result.resource
            if result.outcome == .alreadyRecorded, changed {
                try await artifact.persist(on: db)
            }
        }

        if footprintChanged {
            try await enforceStorageQuota(on: artifact, on: db)
        }
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
    private func enforceStorageQuota<A: SnapshotArtifactResource>(
        on artifact: A, on db: PostgresStoreContext
    ) async throws {
        guard let scope = artifact.storageQuotaScope, artifact.desiredStatus == .present else { return }
        do {
            guard
                let violated = try await QuotaEnforcementService.storageOverCommit(
                    projectID: scope.projectID, environment: scope.environment, on: db)
            else { return }

            let updated = artifact.replacingConvergence(
                phase: artifact.convergencePhase,
                lastError: "Snapshot's actual size exceeded storage quota '\(violated)' and was deleted",
                failedGeneration: artifact.failedGeneration)
            try await updated.persist(on: db)
            _ = try await SnapshotArtifactMutation.delete(
                updated, actor: .system, on: db, app: app)

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
    private func handleReportedSnapshotAbsence<A: SnapshotArtifactResource>(
        artifact initialArtifact: A,
        agentId: String,
        on db: PostgresStoreContext
    ) async throws {
        var artifact = initialArtifact
        let artifactID = try artifact.requireID()

        if artifact.desiredStatus == .absent {
            let outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: artifact, on: db, app: app)
            if outcome.isRemoved {
                app.logger.info(
                    "Snapshot deletion confirmed by agent report; record removed",
                    metadata: [
                        "resourceKind": .string(A.operationResourceKind.rawValue),
                        "resourceId": .string(artifactID.uuidString),
                        "agentId": .string(agentId),
                    ])
            }
            return
        }

        let convergence = artifact.recordingConvergence(
            phase: nil, lastError: artifact.lastError, failedGeneration: artifact.failedGeneration)
        artifact = convergence.resource

        // Only escalate an artifact some agent has actually confirmed. A row at
        // `observedGeneration == 0` is mid-capture — the agent has not written
        // it yet, and its absence is expected rather than a loss.
        guard artifact.observedGeneration > 0, artifact.isPresentOnAgent else {
            if convergence.changed {
                try await artifact.persist(on: db)
            }
            return
        }

        artifact = artifact.recordingObservedPresence(present: false, failed: true).resource
        artifact = artifact.replacingConvergence(
            phase: artifact.convergencePhase,
            lastError: "snapshot artifacts are missing from their agent",
            failedGeneration: artifact.failedGeneration)
        try await artifact.persist(on: db)
        app.logger.warning(
            "Snapshot missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "resourceKind": .string(A.operationResourceKind.rawValue),
                "resourceId": .string(artifactID.uuidString),
                "agentId": .string(agentId),
            ])
    }

    /// A volume the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    ///
    /// This is the only place a volume row is ever removed. The agent omitting
    /// the volume from a full list is the confirmation that its data is gone —
    /// the same contract VMs and sandboxes have, and the reason a volume delete
    /// can be re-driven indefinitely without ever orphaning bytes.
    private func handleReportedVolumeAbsence(
        volume: Volume,
        agentId: String,
        on db: PostgresStoreContext
    ) async throws {
        var current = volume
        let volumeID = try current.requireID()

        if volume.desiredStatus == .absent {
            // One report only confirms one physical copy is gone. Remove that
            // replica and keep the shared finalizer until every physical copy,
            // including degraded, resyncing, and faulted copies, has
            // independently disappeared.
            try await LegacyVolumeReplicaStore.delete(
                volumeID: volumeID,
                agentId: agentId,
                on: db
            )
            let remainingAgentIDs = try await VolumeService.agentIDsWithPhysicalReplicas(
                of: volume, on: db)
            guard remainingAgentIDs.isEmpty else {
                app.logger.debug(
                    "Volume replica teardown confirmed; awaiting other replicas",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "agentId": .string(agentId),
                        "remainingAgentIds": .string(remainingAgentIDs.joined(separator: ",")),
                    ])
                return
            }
            switch try await ResourceFinalizerService.clear(
                .agentAbsent, from: volume, on: db, app: app)
            {
            case .reaped:
                app.logger.info(
                    "Volume deletion confirmed by agent report; record removed",
                    metadata: ["volumeId": .string(volumeID.uuidString), "agentId": .string(agentId)])
            case .held(let remaining):
                app.logger.debug(
                    "Volume teardown confirmed by agent report; awaiting finalizers",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString), "agentId": .string(agentId),
                        "finalizers": .string(remaining.joined(separator: ",")),
                    ])
            case .alreadyGone, .notTerminating:
                break
            }
            return
        }

        // Nothing to report means no progress to report — same rationale as the
        // VM and sandbox paths.
        let convergence = current.recordingConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)
        current = convergence.resource

        // Only escalate a volume some agent has actually confirmed. A row at
        // `observedGeneration == 0` may simply be waiting for its first sync to
        // reach the agent, and calling that an error would make every create
        // flash red before it went green.
        guard current.observedGeneration > 0, current.status != .error else {
            if convergence.changed {
                try await current.save(on: db)
            }
            return
        }

        let previous = current.status
        current = current.replacing(
            status: .error,
            errorMessage: .some("volume data is missing from its agent"))
        try await current.save(on: db)
        app.logger.warning(
            "Volume missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "volumeId": .string(volumeID.uuidString),
                "agentId": .string(agentId),
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
    private func recordReplicaObservation(
        volumeID: UUID,
        agentId: String,
        observed: ObservedVolumeState,
        desiredGeneration: Int64,
        on db: PostgresStoreContext
    ) async throws {
        let failedAtTarget =
            observed.lastError != nil && observed.failedGeneration == desiredGeneration
        let state: VolumeReplicaState =
            observed.present && observed.convergencePhase == nil && !failedAtTarget
            ? .healthy : .provisioning
        let existing = try await LegacyVolumeReplicaStore.replica(
            volumeID: volumeID,
            agentId: agentId,
            on: db
        )
        guard existing != nil || observed.present else { return }
        _ = try await LegacyVolumeReplicaStore.recordObservation(
            volumeID: volumeID,
            agentId: agentId,
            diskAttachment: observed.attachment,
            state: state,
            generation: observed.observedGeneration,
            on: db
        )
    }
}

extension Application {
    private struct ObservedStateApplierKey: StorageKey {
        typealias Value = ObservedStateApplier
    }

    var observedStateApplier: ObservedStateApplier {
        get {
            guard let applier = storage[ObservedStateApplierKey.self] else {
                preconditionFailure("Observed-state applier has not been configured")
            }
            return applier
        }
        set { storage[ObservedStateApplierKey.self] = newValue }
    }
}
