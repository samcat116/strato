import Fluent
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

    private struct ResourceKey: Hashable {
        let kind: OperationResourceKind
        let id: UUID
    }

    /// What one report's teardown bookkeeping produced (STR-98), for the
    /// caller — which holds the agent row this needs to be reported against.
    struct UnrecognizedOutcome: Sendable {
        /// A teardown was newly authorized (or its generation advanced), so
        /// the agent should get a sync now rather than at the next period.
        var authorizedTeardown = false
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
    private func withLockedCurrent<R: ConvergingResource>(
        _ resource: R,
        reportedBy agentId: String,
        on db: any Database,
        applying body: @escaping @Sendable (R, any Database) async throws -> Void
    ) async throws {
        try await db.transaction { tx in
            guard try await resource.lockAndRefresh(on: tx) else { return }
            let resourceID = try resource.requireID()
            let placementAgentIDs = try await resource.placementAgentIDs(on: tx)
            guard placementAgentIDs.contains(agentId) else {
                app.logger.debug(
                    "Ignoring an observed-state entry after the resource moved to another agent",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(resourceID.uuidString),
                        "reportingAgentId": .string(agentId),
                        "currentAgentId": .string(placementAgentIDs.joined(separator: ",")),
                    ])
                return
            }
            try await body(resource, tx)
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
        let db = app.db

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
        let unrecognizedOutcome = try await applyUnrecognizedWorkloads(report, on: db)

        let dbVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId == report.agentId)
            .all()

        // Sandboxes apply with the same shape as VMs: settled observations
        // update the row and resolve pending operations; absence either
        // confirms a deletion or escalates a lost sandbox.
        let reportedSandboxes = Dictionary(
            report.sandboxes.map { ($0.sandboxId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let dbSandboxes = try await Sandbox.query(on: db)
            .filter(\.$hypervisorId == report.agentId)
            .all()

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
        if interfaceVMIDs.isEmpty {
            interfacesByVMID = [:]
        } else {
            let interfaces = try await VMNetworkInterface.query(on: db)
                .filter(\.$vm.$id ~~ interfaceVMIDs)
                .with(\.$observedAddresses)
                .all()
            interfacesByVMID = Dictionary(grouping: interfaces, by: \.$vm.id)
        }

        for vm in dbVMs {
            guard let vmID = vm.id else { continue }
            if let observed = reported[vmID] {
                let interfaces = interfacesByVMID[vmID] ?? []
                try await withLockedCurrent(vm, reportedBy: report.agentId, on: db) { vm, tx in
                    try await applyObservedVMState(
                        vm: vm, observed: observed, interfaces: interfaces, on: tx)
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

        // Volumes (STR-148). `guard let` on the *field*, not on a version
        // lookup: an agent below v31 omits `volumes` entirely, and the whole
        // loop below treats an unlisted volume as confirmed gone. Reading that
        // silence as authoritative would reap every terminating volume row the
        // agent holds and error every live one — a data-loss-shaped bug, so it
        // is guarded by the payload describing itself rather than by a
        // `wireProtocolVersion` column being current.
        if let reportedVolumeList = report.volumes {
            let reportedVolumes = Dictionary(
                reportedVolumeList.map { ($0.volumeId, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let dbVolumes = try await VolumeService.volumes(onAgent: report.agentId, on: db)
            for volume in dbVolumes {
                guard let volumeID = volume.id else { continue }
                if let observed = reportedVolumes[volumeID] {
                    try await withLockedCurrent(volume, reportedBy: report.agentId, on: db) {
                        volume, tx in
                        try await applyObservedVolumeState(
                            volume: volume, observed: observed, agentId: report.agentId, on: tx)
                    }
                } else {
                    try await withLockedCurrent(volume, reportedBy: report.agentId, on: db) {
                        volume, tx in
                        try await handleReportedVolumeAbsence(
                            volume: volume, agentId: report.agentId, on: tx)
                    }
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
        _ observations: [ObservedLoadBalancerState], on db: any Database
    ) async throws {
        for observed in observations {
            try await db.transaction { tx in
                guard let loadBalancer = try await LoadBalancer.find(observed.id, on: tx) else {
                    return
                }
                // A delayed report may describe a superseded desired row; it
                // must not make the current generation look converged. A value
                // ahead of the database indicates a rollback/split-brain and
                // is equally unsafe to apply.
                guard observed.observedGeneration <= loadBalancer.generation,
                    observed.observedGeneration >= loadBalancer.observedGeneration
                else { return }

                loadBalancer.observedGeneration = observed.observedGeneration
                loadBalancer.observedState =
                    switch observed.status {
                    case .pending: .pending
                    case .active: .active
                    case .error: .error
                    }
                loadBalancer.lastError = observed.lastError
                try await loadBalancer.save(on: tx)

                for backendObservation in observed.backends {
                    guard
                        let backend = try await LoadBalancerBackend.query(on: tx)
                            .filter(\.$id == backendObservation.id)
                            .filter(\.$loadBalancer.$id == observed.id)
                            .first()
                    else { continue }
                    backend.healthStatus =
                        switch backendObservation.healthStatus {
                        case .unknown: .unknown
                        case .online: .online
                        case .offline: .offline
                        case .error: .error
                        }
                    backend.lastHealthCheckAt = backendObservation.lastCheckedAt
                    try await backend.save(on: tx)
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
        on db: Database
    ) async throws -> UnrecognizedOutcome {
        let existingClaims = try await AgentWorkloadClaim.query(on: db)
            .filter(\.$agentId == report.agentId)
            .all()

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
                for id in try await VM.query(on: db).filter(\.$id ~~ vmCandidates).all().compactMap(\.id) {
                    revived.insert(ResourceKey(kind: .virtualMachine, id: id))
                }
            }
            let sandboxCandidates = revivable.keys.filter { $0.kind == .sandbox }.map(\.id)
            if !sandboxCandidates.isEmpty {
                for id in try await Sandbox.query(on: db).filter(\.$id ~~ sandboxCandidates).all()
                    .compactMap(\.id)
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
            try await AgentWorkloadClaim.query(on: db)
                .filter(\.$id ~~ staleClaims.values.compactMap(\.id))
                .delete()
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
            for vm in try await VM.query(on: db).filter(\.$id ~~ vmIDs).all() {
                guard let id = vm.id else { continue }
                vmPlacements[id] = WorkloadPlacement(agentId: vm.hypervisorId)
            }
        }
        var sandboxPlacements: [UUID: WorkloadPlacement] = [:]
        if !sandboxIDs.isEmpty {
            for sandbox in try await Sandbox.query(on: db).filter(\.$id ~~ sandboxIDs).all() {
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
        var newClaims: [AgentWorkloadClaim] = []
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
                    pendingCreates: &newClaims,
                    on: db)
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
                pendingCreates: &newClaims,
                on: db)
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
            try await newClaims.create(on: db)
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
        _ existing: AgentWorkloadClaim?,
        agentId: String,
        key: ResourceKey,
        disposition: WorkloadClaimDisposition,
        tombstoneGeneration: Int64?,
        reason: String?,
        entry: UnrecognizedWorkload,
        pendingCreates: inout [AgentWorkloadClaim],
        on db: Database
    ) async throws {
        guard let claim = existing else {
            pendingCreates.append(
                AgentWorkloadClaim(
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
        claim.disposition = disposition
        claim.tombstoneGeneration = tombstoneGeneration
        claim.reason = reason
        claim.observedGeneration = entry.observedGeneration
        claim.observedStatus = entry.status
        try await claim.save(on: db)
    }

    /// Apply one settled (or failing) observation to its VM row and record the
    /// convergence transition it produces.
    private func applyObservedVMState(
        vm: VM,
        observed: ObservedVMState,
        interfaces: [VMNetworkInterface],
        on db: Database
    ) async throws {
        let vmID = try vm.requireID()
        try logSupersededFailureReport(vm, reportedGeneration: observed.failedGeneration)

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
        let wasConverged = vm.isConverged
        let failedBefore = vm.failedGeneration

        // The guest-agent view (issue #563) is orthogonal to convergence and
        // operation completion, so record it up front — before the converging
        // early-return below. A present `guestInfo` is persisted; a nil one on a
        // VM the agent observes definitively *not running* clears the stale view
        // (a stopped VM also drops out of the agent's poll cache and reports
        // nil, so without this its "guest agent connected" state would persist
        // forever). A nil on a running/paused/transitional/unknown VM is left
        // alone — that's a transient probe miss, and nil-preserves-last-known.
        if let guestInfo = observed.guestInfo {
            try await persistGuestInfo(vm: vm, guestInfo: guestInfo, interfaces: interfaces, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            try await clearGuestInfo(vm: vm, interfaces: interfaces, on: db)
        }

        // Balloon memory stats (issue #567) follow the same contract as
        // guestInfo, independently: a guest can report balloon stats without
        // qga (and vice versa), so their presence is tracked separately.
        if let memoryStats = observed.memoryStats {
            try await persistMemoryStats(vm: vm, stats: memoryStats, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            try await clearMemoryStats(vm: vm, on: db)
        }

        // Mirror the report's convergence progress onto the row (STR-142) so
        // the API can project it as the VM's `conditions` block. Recorded on
        // both the converging and settled paths — the phase only exists on the
        // former, and the error pair has to be *cleared* on the latter.
        var changed = vm.recordTimestampedConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )

        // Still converging: progress only. The status is not settled, so it
        // must not overwrite the row or complete operations.
        if observed.convergencePhase != nil {
            if changed {
                try await vm.save(on: db)
            }
            app.logger.debug(
                "VM converging on agent",
                metadata: [
                    "vmId": .string(vmID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(vm.generation),
                ])
            return
        }

        if observed.observedGeneration > vm.observedGeneration {
            vm.observedGeneration = observed.observedGeneration
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
                try await interface.delete(on: db)
            }
        }

        var statusTransition: (previous: VMStatus, current: VMStatus)?
        if vm.status != observed.status, observed.status != .unknown || vm.status.isTransitional {
            let previous = vm.status
            vm.setStatus(observed.status)
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
        if vm.desiredSatisfied, vm.divergenceDetectedAt != nil {
            vm.divergenceDetectedAt = nil
            changed = true
        }

        let failedCurrentGeneration =
            observed.lastError != nil && observed.failedGeneration == vm.generation
        // No deadline means no user mutation is outstanding. This is a
        // steady-state repair failure: persist exactly what the agent observed,
        // but retain the desired state and generation so the level-triggered
        // loop can heal it later. In particular, do not synthesize a stale
        // mutation outcome from whichever resource event happens to be latest.
        if failedCurrentGeneration, vm.convergenceDeadline == nil {
            if changed {
                try await vm.save(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
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
            vm.desiredStatus != .absent
            && ((!wasConverged && vm.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == vm.generation))
        if !settlesConvergence {
            if changed {
                try await vm.save(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
            return
        }

        if !wasConverged, vm.isConverged {
            // The agent converged to the current generation and the observed
            // status satisfies the desired one: everything outstanding reached
            // its goal.
            _ = try await ResourceConvergence.recordSuccess(vm, on: db)
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == vm.generation {
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
            let previousStatus = vm.status
            var enteredError = false
            if failedBefore != vm.generation, observed.status == .unknown, vm.status != .error {
                vm.setStatus(.error)
                enteredError = true
                Telemetry.vmEnteredError(reason: "convergence_failed")
            }

            let outcome = try await ResourceConvergence.recordFailure(
                vm, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if outcome == .alreadyRecorded, changed {
                // A repeat of an already-recorded failure: nothing was
                // persisted by the call above, so this report's own changes
                // (observed generation, status) still need writing.
                try await vm.save(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
            if outcome == .recorded, enteredError {
                await WebhookEvents.emitVMStateChanged(
                    vm: vm, previous: previousStatus, current: .error, on: db, logger: app.logger)
            }
        }
    }

    /// Emits `vm.state_changed` for an observed status transition, once the
    /// write that produced it has committed. Best-effort by contract, so it is
    /// deliberately outside the convergence transaction: a webhook that cannot
    /// be enqueued must not roll back the observation it describes.
    private func emitVMStatusTransition(
        _ transition: (previous: VMStatus, current: VMStatus)?, vm: VM, on db: Database
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
        on db: Database
    ) async throws {
        var vmChanged = false
        if vm.qgaAvailable != guestInfo.qgaAvailable {
            vm.qgaAvailable = guestInfo.qgaAvailable
            vmChanged = true
        }
        if vm.observedHostname != guestInfo.hostname {
            vm.observedHostname = guestInfo.hostname
            vmChanged = true
        }
        if vmChanged {
            try await vm.save(on: db)
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
                nic.observedAddresses.map { "\($0.family)|\($0.address)|\($0.prefixLength.map(String.init) ?? "")" })
            let desiredKeys = Set(
                desired.map { "\($0.family.rawValue)|\($0.address)|\($0.prefixLength.map(String.init) ?? "")" })
            if storedKeys == desiredKeys { continue }

            // The set changed: replace this NIC's observed rows wholesale, in a
            // transaction so a crash can't leave the NIC with the delete applied
            // but the re-inserts missing.
            try await db.transaction { db in
                try await VMInterfaceObservedAddress.query(on: db)
                    .filter(\.$interface.$id == nicID)
                    .delete()
                for address in desired {
                    try await VMInterfaceObservedAddress(
                        interfaceID: nicID,
                        family: address.family,
                        address: address.address,
                        prefixLength: address.prefixLength
                    ).save(on: db)
                }
            }
        }
    }

    /// Persists a VM's observed balloon memory stats (issue #567), stamping
    /// the report time. Skips the write when the numbers are unchanged (the
    /// steady state for an idle guest) so the report stream doesn't churn the
    /// row — which means `guestMemoryStatsAt` records when the values last
    /// *changed*, a freshness signal that survives unchanged reports.
    private func persistMemoryStats(vm: VM, stats: VMMemoryStats, on db: Database) async throws {
        guard
            vm.guestMemoryTotalBytes != stats.totalBytes
                || vm.guestMemoryAvailableBytes != stats.availableBytes
                || vm.guestMemoryBalloonActualBytes != stats.balloonActualBytes
        else { return }
        vm.guestMemoryTotalBytes = stats.totalBytes
        vm.guestMemoryAvailableBytes = stats.availableBytes
        vm.guestMemoryBalloonActualBytes = stats.balloonActualBytes
        vm.guestMemoryStatsAt = Date()
        try await vm.save(on: db)
    }

    /// Clears a VM's observed memory stats once the guest is definitively not
    /// running — a stopped guest's last-known usage is stale, and surfacing it
    /// as current would mislead the "committed vs used" view.
    private func clearMemoryStats(vm: VM, on db: Database) async throws {
        guard
            vm.guestMemoryTotalBytes != nil || vm.guestMemoryAvailableBytes != nil
                || vm.guestMemoryBalloonActualBytes != nil
        else { return }
        vm.guestMemoryTotalBytes = nil
        vm.guestMemoryAvailableBytes = nil
        vm.guestMemoryBalloonActualBytes = nil
        vm.guestMemoryStatsAt = nil
        try await vm.save(on: db)
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
        on db: Database
    ) async throws {
        guard vm.qgaAvailable != nil || vm.observedHostname != nil else { return }
        vm.qgaAvailable = nil
        vm.observedHostname = nil
        try await vm.save(on: db)

        let nicIDs = interfaces.compactMap(\.id)
        if !nicIDs.isEmpty {
            try await VMInterfaceObservedAddress.query(on: db)
                .filter(\.$interface.$id ~~ nicIDs)
                .delete()
        }
    }

    /// A VM the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedAbsence(
        vm: VM,
        agentId: String,
        on db: Database
    ) async throws {
        let vmID = try vm.requireID()

        if vm.desiredStatus == .absent {
            // Teardown confirmed: this is the `agent.absent` finalizer's
            // participant (ADR 0001). Nothing is recorded *here* — the reap
            // that clearing the last token triggers appends the terminal
            // `resource_events` row, which is what tells a client polling a
            // delete that it finished (STR-147).
            switch try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: db, app: app) {
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
        let convergenceCleared = vm.recordTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)

        // Same established-state rule as the heartbeat reconciliation: only
        // states that assert live agent presence are safe to escalate on
        // absence. (`.created` may be mid-create on an agent that hasn't
        // received the sync yet.) The reconcile loop will re-create the VM on
        // its next sync; if it succeeds, a later report restores the status.
        guard vm.status.assertsAgentPresence else {
            if convergenceCleared {
                try await vm.save(on: db)
            }
            return
        }

        let previous = vm.status
        vm.setStatus(.error)
        try await vm.save(on: db)
        Telemetry.vmEnteredError(reason: "reconciliation")
        await WebhookEvents.emitVMStateChanged(
            vm: vm, previous: previous, current: .error, on: db, logger: app.logger)
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
        on db: Database
    ) async throws {
        let sandboxID = try sandbox.requireID()
        try logSupersededFailureReport(sandbox, reportedGeneration: observed.failedGeneration)
        let wasConverged = sandbox.isConverged
        let failedBefore = sandbox.failedGeneration

        // Convergence progress for the `conditions` block (STR-142) — same
        // contract as VMs, recorded on both paths for the same reasons.
        var changed = sandbox.recordTimestampedConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration
        )

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await sandbox.save(on: db)
            }
            app.logger.debug(
                "Sandbox converging on agent",
                metadata: [
                    "sandboxId": .string(sandboxID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(sandbox.generation),
                ])
            return
        }

        if observed.observedGeneration > sandbox.observedGeneration {
            sandbox.observedGeneration = observed.observedGeneration
            changed = true
        }

        if sandbox.status != observed.status, observed.status != .unknown || sandbox.status.isTransitional {
            let previous = sandbox.status
            sandbox.setStatus(observed.status)
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
        if sandbox.exitCode != observed.exitCode {
            sandbox.exitCode = observed.exitCode
            changed = true
        }
        if sandbox.desiredSatisfied, sandbox.divergenceDetectedAt != nil {
            sandbox.divergenceDetectedAt = nil
            changed = true
        }

        let failedCurrentGeneration =
            observed.lastError != nil && observed.failedGeneration == sandbox.generation
        // A failure with no deadline belongs to steady-state repair, not to a
        // pending mutation. Keep intent and generation intact and emit no
        // operation outcome; a later same-generation retry can still recover.
        if failedCurrentGeneration, sandbox.convergenceDeadline == nil {
            if changed {
                try await sandbox.save(on: db)
            }
            return
        }
        // Deletions are settled by absence from the report, never by a status.
        // The save is deferred to the transition where there is one, for the
        // reason the VM path defers it.
        let settlesConvergence =
            sandbox.desiredStatus != .absent
            && ((!wasConverged && sandbox.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == sandbox.generation))
        if !settlesConvergence {
            if changed {
                try await sandbox.save(on: db)
            }
            return
        }

        if !wasConverged, sandbox.isConverged {
            _ = try await ResourceConvergence.recordSuccess(sandbox, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == sandbox.generation {
            // The agent tried to converge to *this* generation and failed —
            // report the real reason instead of waiting out the convergence
            // deadline (same contract as VMs, including the pre-escalation of a
            // sandbox with no settled presence on the agent).
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: .sandbox, resourceID: sandboxID, on: db
                )?.mutation ?? .boot
            if failedBefore != sandbox.generation, observed.status == .unknown {
                sandbox.setStatus(.error)
            }
            let outcome = try await ResourceConvergence.recordFailure(
                sandbox, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if outcome == .alreadyRecorded, changed {
                try await sandbox.save(on: db)
            }
        }
    }

    /// A sandbox the database maps to this agent is absent from its full
    /// report: either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedSandboxAbsence(
        sandbox: Sandbox,
        agentId: String,
        on db: Database
    ) async throws {
        let sandboxID = try sandbox.requireID()

        if sandbox.desiredStatus == .absent {
            // Teardown confirmed: the `agent.absent` participant. The reap
            // appends the terminal event, same as VMs.
            switch try await ResourceFinalizerService.clear(
                .agentAbsent, from: sandbox, on: db, app: app)
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
        let convergenceCleared = sandbox.recordTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil)

        // Only escalate established sandboxes: a never-confirmed row
        // (observedGeneration 0) may be mid-create on an agent that hasn't
        // received the sync yet, and non-presence-asserting states are owned
        // by the sweep.
        guard sandbox.observedGeneration > 0, sandbox.status.assertsAgentPresence else {
            if convergenceCleared {
                try await sandbox.save(on: db)
            }
            return
        }

        let previous = sandbox.status
        sandbox.setStatus(.error)
        try await sandbox.save(on: db)
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
        on db: Database
    ) async throws {
        let volumeID = try volume.requireID()
        try logSupersededFailureReport(volume, reportedGeneration: observed.failedGeneration)
        // Captured before anything mutates, for exactly the reasons the VM
        // path documents: `recordConvergence` mirrors the agent's own
        // `failedGeneration` onto the model and would otherwise satisfy the
        // idempotence guard with nothing recorded.
        let wasConverged = volume.isConverged
        let failedBefore = volume.failedGeneration

        try await recordReplicaObservation(
            volumeID: volumeID, agentId: agentId, observed: observed,
            desiredGeneration: volume.generation, on: db)
        let requiredReplicas = try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .filter(\.$state ~~ VolumeService.authoritativeReplicaStates)
            .all()
        let allReplicasSettled =
            !requiredReplicas.isEmpty
            && requiredReplicas.allSatisfy {
                $0.state == .healthy && $0.generation >= volume.generation
            }
        let generationBeforeTarget = max(0, volume.generation - 1)
        let aggregateObservedGeneration =
            requiredReplicas.map { replica in
                replica.state == .healthy
                    ? replica.generation : min(replica.generation, generationBeforeTarget)
            }.min() ?? 0
        let failedAtTarget =
            observed.lastError != nil && observed.failedGeneration == volume.generation
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
            nextError = volume.errorMessage
            nextFailedGeneration = volume.failedGeneration
        }
        var changed = volume.recordConvergence(
            phase: nextPhase,
            lastError: nextError,
            failedGeneration: nextFailedGeneration
        )

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

        if aggregateObservedGeneration > volume.observedGeneration {
            volume.observedGeneration = aggregateObservedGeneration
            changed = true
        }

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await volume.save(on: db)
            }
            return
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
        let settlesConvergence =
            volume.desiredStatus != .absent
            && ((!wasConverged && volume.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == volume.generation))
        if !settlesConvergence {
            if changed {
                try await volume.save(on: db)
            }
            return
        }

        if !wasConverged, volume.isConverged {
            _ = try await ResourceConvergence.recordSuccess(volume, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == volume.generation {
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: .volume, resourceID: volumeID, on: db
                )?.mutation ?? .create
            let outcome = try await ResourceConvergence.recordFailure(
                volume, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if outcome == .alreadyRecorded, changed {
                try await volume.save(on: db)
            }
        }
    }

    /// The rows behind one family's reported-unrecognized ids, including rows
    /// placed on *other* agents — which is the whole re-point signal.
    private func collectSnapshotPlacements<A: SnapshotArtifactResource>(
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
    /// the diff, the convergence quartet, the derived status and the
    /// absent-then-reap dance are identical across the families, and only what
    /// the captured facts *mean* differs — which each model absorbs in
    /// `applyCapturedFacts`.
    private func applyObservedSnapshots<A: SnapshotArtifactResource>(
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
        artifact: A,
        observed: ObservedSnapshotState,
        on db: Database
    ) async throws {
        let artifactID = try artifact.requireID()
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
            return
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

        let settlesConvergence =
            artifact.desiredStatus != .absent
            && ((!wasConverged && artifact.isConverged)
                || (observed.lastError != nil && observed.failedGeneration == artifact.generation))
        if !settlesConvergence {
            if changed {
                try await artifact.save(on: db)
            }
            return
        }

        if !wasConverged, artifact.isConverged {
            _ = try await ResourceConvergence.recordSuccess(artifact, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == artifact.generation {
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: A.operationResourceKind, resourceID: artifactID, on: db
                )?.mutation ?? .create
            let outcome = try await ResourceConvergence.recordFailure(
                artifact, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if outcome == .alreadyRecorded, changed {
                try await artifact.save(on: db)
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
        on artifact: A, on db: Database
    ) async throws {
        guard let scope = artifact.storageQuotaScope, artifact.desiredStatus == .present else { return }
        do {
            guard
                let violated = try await QuotaEnforcementService.storageOverCommit(
                    projectID: scope.projectID, environment: scope.environment, on: db)
            else { return }

            artifact.lastError =
                "Snapshot's actual size exceeded storage quota '\(violated)' and was deleted"
            try await artifact.save(on: db)
            _ = try await SnapshotArtifactMutation.delete(
                artifact, actor: .system, on: db, app: app)

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
        artifact: A,
        agentId: String,
        on db: Database
    ) async throws {
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
        on db: Database
    ) async throws {
        let volumeID = try volume.requireID()

        if volume.desiredStatus == .absent {
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
            if let datasetPath = observed.storagePath, existing.datasetPath != datasetPath {
                existing.datasetPath = datasetPath
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
            datasetPath: observed.storagePath,
            state: state,
            generation: observed.observedGeneration
        ).create(on: db)
    }
}

extension Application {
    /// The observed-state report applier. Stateless and cheap to construct
    /// (it holds a reference), so it is materialized per access rather than
    /// stored — the same idiom as `resourceOperationCoordinator`.
    var observedStateApplier: ObservedStateApplier {
        ObservedStateApplier(app: self)
    }
}
