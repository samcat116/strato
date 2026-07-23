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

    func apply(_ report: ObservedStateReport) async throws {
        // Every reported VM or sandbox is accounted for in the agent's
        // resource figures, so any placement reservation still held for one
        // would double-count. Reservations are keyed by resource id, so both
        // kinds release through the same call.
        await app.coordination.releaseReservations(
            agentId: report.agentId,
            vmIds: report.vms.map { $0.vmId.uuidString } + report.sandboxes.map { $0.sandboxId.uuidString })

        let db = app.db
        let reported = Dictionary(
            report.vms.map { ($0.vmId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let dbVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId == report.agentId)
            .all()

        for vm in dbVMs {
            guard let vmID = vm.id else { continue }
            if let observed = reported[vmID] {
                try await applyObservedVMState(vm: vm, observed: observed, on: db)
            } else {
                try await handleReportedAbsence(vm: vm, agentId: report.agentId, on: db)
            }
        }

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

        for sandbox in dbSandboxes {
            guard let sandboxID = sandbox.id else { continue }
            if let observed = reportedSandboxes[sandboxID] {
                try await applyObservedSandboxState(sandbox: sandbox, observed: observed, on: db)
            } else {
                try await handleReportedSandboxAbsence(sandbox: sandbox, agentId: report.agentId, on: db)
            }
        }
    }

    /// Apply one settled (or failing) observation to its VM row and resolve
    /// any pending operation it satisfies.
    private func applyObservedVMState(vm: VM, observed: ObservedVMState, on db: Database) async throws {
        let vmID = try vm.requireID()

        // The guest-agent view (issue #563) is orthogonal to convergence and
        // operation completion, so record it up front — before the converging
        // early-return below. A present `guestInfo` is persisted; a nil one on a
        // VM the agent observes definitively *not running* clears the stale view
        // (a stopped VM also drops out of the agent's poll cache and reports
        // nil, so without this its "guest agent connected" state would persist
        // forever). A nil on a running/paused/transitional/unknown VM is left
        // alone — that's a transient probe miss, and nil-preserves-last-known.
        if let guestInfo = observed.guestInfo {
            try await persistGuestInfo(vm: vm, guestInfo: guestInfo, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            try await clearGuestInfo(vm: vm, on: db)
        }

        // Balloon memory stats (issue #567) follow the same contract as
        // guestInfo, independently: a guest can report balloon stats without
        // qga (and vice versa), so their presence is tracked separately.
        if let memoryStats = observed.memoryStats {
            try await persistMemoryStats(vm: vm, stats: memoryStats, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            try await clearMemoryStats(vm: vm, on: db)
        }

        // Still converging: progress only. The status is not settled, so it
        // must not overwrite the row or complete operations.
        if observed.convergencePhase != nil {
            app.logger.debug(
                "VM converging on agent",
                metadata: [
                    "vmId": .string(vmID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(vm.generation),
                ])
            return
        }

        let pendingOperation = try await ResourceOperation.query(on: db)
            .filter(\.$resourceKind == .virtualMachine)
            .filter(\.$resourceID == vmID)
            .filter(\.$status == .pending)
            .first()

        var changed = false
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

            // Drift telemetry: an out-of-band change (no operation in flight
            // asked for anything) means agent reality moved on its own — e.g.
            // a guest powered itself off, or someone paused it over QMP.
            if pendingOperation == nil, !previous.isTransitional {
                app.logger.warning(
                    "VM state drifted without a pending operation",
                    metadata: [
                        "vmId": .string(vmID.uuidString),
                        "previousStatus": .string(previous.rawValue),
                        "observedStatus": .string(observed.status.rawValue),
                    ])
                Telemetry.vmDriftDetected()
            }
        }
        if changed {
            try await vm.save(on: db)
        }
        if let transition = statusTransition {
            await WebhookEvents.emitVMStateChanged(
                vm: vm, previous: transition.previous, current: transition.current,
                on: db, logger: app.logger)
        }

        guard let operation = pendingOperation else { return }

        // Deletions complete by absence from the report, never by a status.
        if operation.kind == .delete || vm.desiredStatus == .absent {
            return
        }

        if observed.observedGeneration >= vm.generation, vm.desiredStatus.isSatisfied(by: observed.status) {
            // The agent converged to the current generation and the observed
            // status satisfies the desired one: the operation reached its goal.
            _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == vm.generation {
            // The agent tried to converge to *this* generation and failed —
            // the failedGeneration match is what distinguishes that from a
            // stale error still carried on heartbeats while a newer operation
            // waits for its first attempt. Fail the operation with the real
            // reason instead of waiting out its completion budget.
            if try await operation.completeIfPending(as: .failed, error: lastError, on: db) {
                var failedChanged = false
                var enteredError = false
                if observed.status == .unknown {
                    // The VM has no settled presence on the agent (e.g. the
                    // create never got off the ground) — surface it as error
                    // rather than leaving a healthy-looking resting state.
                    vm.setStatus(.error)
                    failedChanged = true
                    enteredError = true
                    Telemetry.vmEnteredError(reason: "convergence_failed")
                }
                // The intent was not achieved and the user has been told: stop
                // pursuing it. Realigning desired with observed keeps a failed
                // operation from leaving latent divergence that a later sync
                // (or the reconciler's next generation) would replay.
                if vm.revertDesiredToObserved() {
                    failedChanged = true
                }
                if failedChanged {
                    try await vm.save(on: db)
                }
                if enteredError {
                    await WebhookEvents.emitVMStateChanged(
                        vm: vm, previous: observed.status, current: .error,
                        on: db, logger: app.logger)
                }
            }
        }
    }

    /// Persists a VM's observed guest-agent view (issue #563): the VM-level
    /// hostname/availability flags and, per NIC (matched by MAC), the addresses
    /// the guest actually configured. Best-effort and additive — it never
    /// clears data on a nil report, so a momentary probe miss doesn't wipe the
    /// last-known view; a NIC's rows are reconciled wholesale only when the
    /// guest's set actually differs from what's stored, so unchanged reports do
    /// no writes.
    private func persistGuestInfo(vm: VM, guestInfo: GuestInfo, on db: Database) async throws {
        let vmID = try vm.requireID()

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

        let interfaces = try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vmID)
            .with(\.$observedAddresses)
            .all()

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
    private func clearGuestInfo(vm: VM, on db: Database) async throws {
        guard vm.qgaAvailable != nil || vm.observedHostname != nil else { return }
        vm.qgaAvailable = nil
        vm.observedHostname = nil
        try await vm.save(on: db)

        let nicIDs = try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vm.requireID())
            .all(\.$id)
        if !nicIDs.isEmpty {
            try await VMInterfaceObservedAddress.query(on: db)
                .filter(\.$interface.$id ~~ nicIDs)
                .delete()
        }
    }

    /// A VM the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedAbsence(vm: VM, agentId: String, on db: Database) async throws {
        let vmID = try vm.requireID()

        if vm.desiredStatus == .absent {
            // Deletion confirmed. Complete the operation first, then remove
            // the row: if we crash in between, the next report retries the
            // (idempotent) removal, whereas removing first would leave a
            // pending operation with nothing to resolve it but the sweep.
            if let operation = try await ResourceOperation.query(on: db)
                .filter(\.$resourceKind == .virtualMachine)
                .filter(\.$resourceID == vmID)
                .filter(\.$status == .pending)
                .first()
            {
                _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
            }

            try await db.transaction { db in
                try await vm.delete(on: db)
                try await QuotaEnforcementService.release(for: vm, on: db)
            }
            await app.coordination.releaseReservation(agentId: agentId, vmId: vmID.uuidString)

            app.logger.info(
                "VM deletion confirmed by agent report; record removed",
                metadata: ["vmId": .string(vmID.uuidString), "agentId": .string(agentId)])
            return
        }

        // Same established-state rule as the heartbeat reconciliation: only
        // states that assert live agent presence are safe to escalate on
        // absence. (`.created` may be mid-create on an agent that hasn't
        // received the sync yet.) The reconcile loop will re-create the VM on
        // its next sync; if it succeeds, a later report restores the status.
        guard vm.status.assertsAgentPresence else { return }

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
    /// failing) observation and resolve any pending operation it satisfies.
    private func applyObservedSandboxState(
        sandbox: Sandbox, observed: ObservedSandboxState, on db: Database
    ) async throws {
        let sandboxID = try sandbox.requireID()

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            app.logger.debug(
                "Sandbox converging on agent",
                metadata: [
                    "sandboxId": .string(sandboxID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(sandbox.generation),
                ])
            return
        }

        let pendingOperation = try await ResourceOperation.query(on: db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sandboxID)
            .filter(\.$status == .pending)
            .first()

        var changed = false
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
            if pendingOperation == nil, !previous.isTransitional, observed.status != .exited {
                app.logger.warning(
                    "Sandbox state drifted without a pending operation",
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
        if changed {
            try await sandbox.save(on: db)
        }

        guard let operation = pendingOperation else { return }

        // Deletions complete by absence from the report, never by a status.
        if operation.kind == .delete || sandbox.desiredStatus == .absent {
            return
        }

        if observed.observedGeneration >= sandbox.generation,
            sandbox.desiredStatus.isSatisfied(by: observed.status)
        {
            _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == sandbox.generation {
            // The agent tried to converge to *this* generation and failed —
            // fail the operation with the real reason instead of waiting out
            // its completion budget (same contract as VMs).
            if try await operation.completeIfPending(as: .failed, error: lastError, on: db) {
                var failedChanged = false
                if observed.status == .unknown {
                    sandbox.setStatus(.error)
                    failedChanged = true
                }
                if sandbox.revertDesiredToObserved() {
                    failedChanged = true
                }
                if failedChanged {
                    try await sandbox.save(on: db)
                }
            }
        }
    }

    /// A sandbox the database maps to this agent is absent from its full
    /// report: either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedSandboxAbsence(sandbox: Sandbox, agentId: String, on db: Database) async throws {
        let sandboxID = try sandbox.requireID()

        if sandbox.desiredStatus == .absent {
            // Deletion confirmed. Complete the operation first, then remove
            // the row (same crash-ordering rationale as VMs).
            if let operation = try await ResourceOperation.query(on: db)
                .filter(\.$resourceKind == .sandbox)
                .filter(\.$resourceID == sandboxID)
                .filter(\.$status == .pending)
                .first()
            {
                _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
            }

            // Exported snapshot objects first: the snapshot rows cascade with
            // the sandbox row below (issue #428).
            await SandboxController.cleanUpExportedSnapshotObjects(for: sandboxID, app: app)

            try await db.transaction { db in
                try await sandbox.delete(on: db)
                try await QuotaEnforcementService.release(for: sandbox, on: db)
            }
            await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxID.uuidString)

            app.logger.info(
                "Sandbox deletion confirmed by agent report; record removed",
                metadata: ["sandboxId": .string(sandboxID.uuidString), "agentId": .string(agentId)])
            return
        }

        // Only escalate established sandboxes: a never-confirmed row
        // (observedGeneration 0) may be mid-create on an agent that hasn't
        // received the sync yet, and non-presence-asserting states are owned
        // by the sweep.
        guard sandbox.observedGeneration > 0, sandbox.status.assertsAgentPresence else { return }

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
