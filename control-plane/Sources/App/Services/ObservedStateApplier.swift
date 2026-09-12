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

    struct ResourceKey: Hashable {
        let kind: OperationResourceKind
        let id: UUID
    }

    enum ConvergenceSettlement {
        case unchanged
        case changed
        case failed(ResourceConvergence.WriteOutcome)
    }

    /// Persists progress or records the terminal convergence verdict shared by
    /// every finalizable resource family. Callers retain only family-specific
    /// status transitions around this bookkeeping.
    func settleConvergence<R: FinalizableResource>(
        _ resource: R,
        wasConverged: Bool,
        changed: Bool,
        reportedError: String?,
        reportedFailedGeneration: Int64?,
        previousFailureGeneration: Int64?,
        defaultMutation: VMOperationKind,
        prepareFailure: (R) -> Void = { _ in },
        on db: any Database
    ) async throws -> ConvergenceSettlement {
        let settles =
            !resource.isTerminating
            && ((!wasConverged && resource.isConverged)
                || (reportedError != nil && reportedFailedGeneration == resource.generation))
        guard settles else {
            if changed { try await resource.save(on: db) }
            return .unchanged
        }

        if !wasConverged, resource.isConverged {
            _ = try await ResourceConvergence.recordSuccess(resource, on: db)
            return .changed
        }

        guard let reportedError, reportedFailedGeneration == resource.generation else {
            return .unchanged
        }
        let mutation =
            try await ResourceEvent.latest(
                .requested,
                resourceKind: R.operationResourceKind,
                resourceID: try resource.requireID(),
                on: db
            )?.mutation ?? defaultMutation
        prepareFailure(resource)
        let outcome = try await ResourceConvergence.recordFailure(
            resource,
            mutation: mutation,
            reason: reportedError,
            telemetryReason: "convergence_failed",
            context: .observedReport(
                previousFailureGeneration: previousFailureGeneration,
                hadActiveDeadline: resource.convergenceDeadline != nil),
            on: db)
        if outcome == .alreadyRecorded, changed {
            try await resource.save(on: db)
        }
        return .failed(outcome)
    }

    /// Clears the common agent-absence finalizer and emits the family-specific
    /// operator message. Returns false for a live resource so the caller can
    /// continue with missing-resource handling.
    func confirmTeardown<R: FinalizableResource>(
        _ resource: R,
        removedMessage: String,
        heldMessage: String? = nil,
        metadata: Logger.Metadata,
        on db: any Database
    ) async throws -> Bool {
        guard resource.isTerminating else { return false }
        switch try await ResourceFinalizerService.clear(
            .agentAbsent, from: resource, on: db, app: app)
        {
        case .reaped:
            app.logger.info("\(removedMessage)", metadata: metadata)
        case .held(let remaining):
            if let heldMessage {
                var heldMetadata = metadata
                heldMetadata["finalizers"] = .string(remaining.joined(separator: ","))
                app.logger.debug("\(heldMessage)", metadata: heldMetadata)
            }
        case .alreadyGone, .notTerminating:
            break
        }
        return true
    }

    /// Immutable report-level projection used to gate VM convergence without
    /// issuing one boot-volume query per VM.
    struct BootVolumeDependency {
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
            guard let attachedVMID = volume.$vm.id else {
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
    func withLockedCurrent<R: ConvergingResource, Result: Sendable>(
        _ resource: R,
        reportedBy agentId: String,
        on db: any Database,
        applying body: @escaping @Sendable (R, any Database) async throws -> Result
    ) async throws -> Result? {
        try await db.transaction { tx -> Result? in
            guard try await resource.lockAndRefresh(on: tx) else { return nil }
            let resourceID = try resource.requireID()
            let placementAgentIDs = try await resource.placementAgentIDs(on: tx)
            guard placementAgentIDs.contains(agentId) else {
                app.logger.debug(
                    "Ignoring an observed-state entry after the resource moved to another agent",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(resourceID.uuidString),
                        "strato.agent.reporting.id": .string(agentId),
                        "strato.agent.current.ids": .array(
                            placementAgentIDs.sorted().map { .string($0) }),
                    ])
                return nil
            }
            return try await body(resource, tx)
        }
    }

    func logSupersededFailureReport<R: ConvergingResource>(
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
        if let networks = report.networks {
            try await applyObservedNetworks(networks, reportedBy: report.agentId, on: db)
        }
        if let securityGroups = report.securityGroups {
            try await applyObservedSecurityGroups(
                securityGroups, reportedBy: report.agentId, on: db)
        }
        if let portMemberships = report.portMemberships {
            try await applyObservedPortMemberships(
                portMemberships, reportedBy: report.agentId, on: db)
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
                    "strato.agent.id": .string(report.agentId),
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
            interfacesByVMID = Dictionary(grouping: interfaces) { $0.$vm.id }
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
                let bootVolumes = try await Volume.query(on: db)
                    .filter(\.$vm.$id ~~ vmIDs)
                    .filter(\.$volumeType == .boot)
                    .all()
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

    func applyObservedLoadBalancers(
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

    func applyObservedNetworks(
        _ observations: [ObservedNetworkState],
        reportedBy agentId: String,
        on db: any Database
    ) async throws {
        guard let reporterID = UUID(uuidString: agentId) else { return }
        for observed in observations {
            try await db.transaction { tx in
                guard
                    case .applied = try await DesiredStateGenerationWriter.lockCurrent(
                        schema: LogicalNetwork.schema, id: observed.id, on: tx)
                else { return }
                guard
                    let network = try await LogicalNetwork.query(on: tx)
                        .filter(\.$id == observed.id)
                        .with(\.$site)
                        .first(),
                    network.site.$networkControllerAgent.id == reporterID
                else { return }
                guard observed.observedGeneration <= network.generation else { return }
                if observed.status == .active {
                    guard observed.observedGeneration >= network.observedGeneration else { return }
                } else {
                    guard
                        observed.failedGeneration == network.generation
                            || observed.observedGeneration >= network.observedGeneration
                    else { return }
                }
                applyFabricObservation(
                    observedGeneration: observed.observedGeneration,
                    status: observed.status,
                    lastError: observed.lastError,
                    failedGeneration: observed.failedGeneration,
                    failureClassification: observed.failureClassification,
                    to: network)
                try await network.save(on: tx)
            }
        }
    }

    func applyObservedSecurityGroups(
        _ observations: [ObservedSecurityGroupState],
        reportedBy agentId: String,
        on db: any Database
    ) async throws {
        guard let reporterID = UUID(uuidString: agentId) else { return }
        // Only a currently designated site topology authority can make an ACL
        // claim. Non-authority agents send nil, but this guard also closes the
        // stale/malicious-report path at persistence.
        guard
            let site = try await Site.query(on: db)
                .filter(\.$networkControllerAgent.$id == reporterID)
                .first(),
            let siteID = site.id
        else { return }

        for observed in observations {
            try await SecurityGroupSiteConvergence.apply(observed, siteID: siteID, on: db)
        }
    }

    private func applyFabricObservation<R: NetworkFabricConvergingResource>(
        observedGeneration: Int64,
        status: ObservedNetworkFabricStatus,
        lastError: String?,
        failedGeneration: Int64?,
        failureClassification: ObservedFailureClassification?,
        to resource: R
    ) {
        resource.observedGeneration = max(resource.observedGeneration, observedGeneration)
        let activeAtCurrentGeneration =
            status == .active && resource.observedGeneration >= resource.generation
        let preservesCurrentFailure =
            status != .error
            && resource.failedGeneration == resource.generation
            && resource.lastError != nil
            && !activeAtCurrentGeneration
        if preservesCurrentFailure {
            // A stale healthy/pending report is not recovery from a timeout or
            // explicit failure at the current desired generation. Keep the
            // resource degraded until this authority actually acknowledges it.
            return
        }
        let error = status == .error ? lastError : nil
        let failed = status == .error ? failedGeneration : nil
        let previousError = resource.lastError
        let previousFailed = resource.failedGeneration
        _ = resource.recordConvergence(phase: nil, lastError: error, failedGeneration: failed)
        if error == nil {
            resource.lastErrorAt = nil
            if resource.observedGeneration >= resource.generation {
                resource.convergenceDeadline = nil
            }
        } else if previousError != error || previousFailed != failed {
            resource.lastErrorAt = Date()
        }
        if error != nil,
            failureClassification != .blocked,
            failed == resource.generation
        {
            // The authority did answer; the resource is already explicitly
            // degraded rather than silently stuck, so the silence deadline has
            // served its purpose. A blocked result retains the deadline while
            // the missing dependency remains retryable. A superseded failure
            // also retains it because the authority has not answered for the
            // resource's newer generation yet.
            resource.convergenceDeadline = nil
        }
    }

    func applyObservedPortMemberships(
        _ observations: [ObservedPortMembershipState],
        reportedBy agentId: String,
        on db: any Database
    ) async throws {
        for observed in observations {
            try await db.transaction { tx in
                if let nic = try await VMNetworkInterface.query(on: tx)
                    .filter(\.$id == observed.interfaceId)
                    .with(\.$vm)
                    .first()
                {
                    guard nic.vm.hypervisorId == agentId else { return }
                    // The attach/detach handlers take this same transaction-
                    // scoped lock before changing the join rows and
                    // invalidating status. Whichever side commits last has
                    // therefore validated the membership it persists.
                    try await SecurityGroupService.lockMembership(
                        interfaceID: observed.interfaceId, on: tx)
                    let current = try await VMInterfaceSecurityGroup.query(on: tx)
                        .filter(\.$interface.$id == observed.interfaceId)
                        .all()
                        .map { $0.$securityGroup.id }
                        .sorted { $0.uuidString < $1.uuidString }
                    guard current == observed.securityGroupIds else { return }
                    recordMembership(observed, on: nic)
                    try await nic.save(on: tx)
                    return
                }
                if let nic = try await SandboxNetworkInterface.query(on: tx)
                    .filter(\.$id == observed.interfaceId)
                    .with(\.$sandbox)
                    .first()
                {
                    guard nic.sandbox.hypervisorId == agentId else { return }
                    try await SecurityGroupService.lockMembership(
                        interfaceID: observed.interfaceId, on: tx)
                    let current = try await SandboxInterfaceSecurityGroup.query(on: tx)
                        .filter(\.$interface.$id == observed.interfaceId)
                        .all()
                        .map { $0.$securityGroup.id }
                        .sorted { $0.uuidString < $1.uuidString }
                    guard current == observed.securityGroupIds else { return }
                    recordMembership(observed, on: nic)
                    try await nic.save(on: tx)
                }
            }
        }
    }

    private func recordMembership(
        _ observed: ObservedPortMembershipState,
        on nic: VMNetworkInterface
    ) {
        nic.securityGroupStatus = observed.status.rawValue
        nic.securityGroupLastError = observed.lastError
        nic.securityGroupLastErrorAt = observed.lastError == nil ? nil : Date()
    }

    private func recordMembership(
        _ observed: ObservedPortMembershipState,
        on nic: SandboxNetworkInterface
    ) {
        nic.securityGroupStatus = observed.status.rawValue
        nic.securityGroupLastError = observed.lastError
        nic.securityGroupLastErrorAt = observed.lastError == nil ? nil : Date()
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
    func applyUnrecognizedWorkloads(
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
                        "strato.agent.id": .string(report.agentId),
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
                            "strato.agent.id": .string(report.agentId),
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
                var metadata: Logger.Metadata = [
                    "strato.agent.id": .string(report.agentId),
                    "resourceKind": .string(key.kind.rawValue),
                    "resourceId": .string(key.id.uuidString),
                    "observedStatus": .string(entry.status ?? "unknown"),
                ]
                if let placementAgentID = placement.agentId {
                    metadata["strato.agent.placement.id"] = .string(placementAgentID)
                }
                app.logger.error(
                    onThisAgent
                        ? "Agent holds a workload its own desired-state sync omitted; withholding teardown (sync assembly bug)"
                        : "Agent holds a workload placed on a different agent record; withholding teardown (re-point required)",
                    metadata: metadata)
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
    struct WorkloadPlacement {
        let agentId: String?
    }

    /// Record one verdict, updating the existing claim in place so its
    /// `first_seen_at` keeps saying how long the situation has persisted.
    func upsertClaim(
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

}

extension Application {
    /// The observed-state report applier. Stateless and cheap to construct
    /// (it holds a reference), so it is materialized per access rather than
    /// stored — the same idiom as `resourceOperationCoordinator`.
    var observedStateApplier: ObservedStateApplier {
        ObservedStateApplier(app: self)
    }
}
