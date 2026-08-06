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

    /// Apply one report, returning what the caller should do about the
    /// workloads the agent holds that no sync accounted for.
    @discardableResult
    func apply(_ report: ObservedStateReport) async throws -> UnrecognizedOutcome {
        let db = app.db

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
        let guestInfoVMIDs = dbVMs.compactMap { vm -> UUID? in
            guard let vmID = vm.id, let observed = reported[vmID] else { return nil }
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
        if guestInfoVMIDs.isEmpty {
            interfacesByVMID = [:]
        } else {
            let interfaces = try await VMNetworkInterface.query(on: db)
                .filter(\.$vm.$id ~~ guestInfoVMIDs)
                .with(\.$observedAddresses)
                .all()
            interfacesByVMID = Dictionary(grouping: interfaces, by: \.$vm.id)
        }

        for vm in dbVMs {
            guard let vmID = vm.id else { continue }
            if let observed = reported[vmID] {
                try await applyObservedVMState(
                    vm: vm,
                    observed: observed,
                    interfaces: interfacesByVMID[vmID] ?? [],
                    on: db
                )
            } else {
                try await handleReportedAbsence(vm: vm, agentId: report.agentId, on: db)
            }
        }

        for sandbox in dbSandboxes {
            guard let sandboxID = sandbox.id else { continue }
            if let observed = reportedSandboxes[sandboxID] {
                try await applyObservedSandboxState(sandbox: sandbox, observed: observed, on: db)
            } else {
                try await handleReportedSandboxAbsence(
                    sandbox: sandbox, agentId: report.agentId, on: db)
            }
        }

        return unrecognizedOutcome
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

        // New claims accumulate for one batched create at the end — see the
        // stale-delete note above for why this path can't afford a round trip
        // per workload.
        var newClaims: [AgentWorkloadClaim] = []
        for entry in report.unrecognized {
            let key = ResourceKey(kind: entry.kind.resourceKind, id: entry.workloadId)
            let placement: WorkloadPlacement? =
                entry.kind == .vm ? vmPlacements[entry.workloadId] : sandboxPlacements[entry.workloadId]
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
        var changed = vm.recordConvergence(
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
            try await ResourceConvergence.recordSuccess(vm, on: db)
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

            let recorded = try await ResourceConvergence.recordFailure(
                vm, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if !recorded, changed {
                // A repeat of an already-recorded failure: nothing was
                // persisted by the call above, so this report's own changes
                // (observed generation, status) still need writing.
                try await vm.save(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
            if recorded, enteredError {
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
        let convergenceCleared = vm.recordConvergence(
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
        let wasConverged = sandbox.isConverged
        let failedBefore = sandbox.failedGeneration

        // Convergence progress for the `conditions` block (STR-142) — same
        // contract as VMs, recorded on both paths for the same reasons.
        var changed = sandbox.recordConvergence(
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
            try await ResourceConvergence.recordSuccess(sandbox, on: db)
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
            let recorded = try await ResourceConvergence.recordFailure(
                sandbox, mutation: mutation, reason: lastError,
                telemetryReason: "convergence_failed", alreadyRecordedAt: failedBefore, on: db)
            if !recorded, changed {
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
        let convergenceCleared = sandbox.recordConvergence(
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
}

extension Application {
    /// The observed-state report applier. Stateless and cheap to construct
    /// (it holds a reference), so it is materialized per access rather than
    /// stored — the same idiom as `resourceOperationCoordinator`.
    var observedStateApplier: ObservedStateApplier {
        ObservedStateApplier(app: self)
    }
}
