import Fluent
import Foundation
import StratoShared
import Vapor

extension ObservedStateApplier {
    /// Apply one settled (or failing) observation to its VM row and record the
    /// convergence transition it produces.
    func applyObservedVMState(
        vm: VM,
        observed: ObservedVMState,
        interfaces: [VMNetworkInterface],
        bootVolumes: [BootVolumeDependency]?,
        at instant: ClusterInstant,
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
            try await persistMemoryStats(vm: vm, stats: memoryStats, at: instant, on: db)
        } else if Self.guestInfoClearedByStatus.contains(observed.status) {
            try await clearMemoryStats(vm: vm, on: db)
        }

        var resourceTelemetryChanged = false
        if let telemetry = observed.resourceTelemetry, vm.resourceTelemetry != telemetry {
            vm.resourceTelemetry = telemetry
            vm.resourceTelemetryReceivedAt = instant.date
            resourceTelemetryChanged = true
        }
        if let agentID = vm.hypervisorId {
            Telemetry.recordWorkloadResourceTelemetry(
                agentID: agentID,
                workloadID: vmID.uuidString,
                kind: .vm,
                telemetry: observed.resourceTelemetry,
                balloon: observed.memoryStats)
        }

        // Mirror the report's convergence progress onto the row (STR-142) so
        // the API can project it as the VM's `conditions` block. Recorded on
        // both the converging and settled paths — the phase only exists on the
        // former, and the error pair has to be *cleared* on the latter.
        let bootVolumePhase: String?
        if let bootVolumes, observed.convergencePhase == nil, observed.lastError == nil,
            vm.desiredStatus != .absent
        {
            bootVolumePhase = pendingBootVolumePhase(for: vm, bootVolumes: bootVolumes)
        } else {
            bootVolumePhase = nil
        }
        let effectivePhase = observed.convergencePhase ?? bootVolumePhase
        var changed = vm.recordTimestampedConvergence(
            phase: effectivePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration,
            at: instant
        )
        changed = resourceTelemetryChanged || changed

        // Still converging: progress only. The status is not settled, so it
        // must not overwrite the row or complete operations.
        if effectivePhase != nil {
            if changed {
                try await vm.save(on: db)
            }
            app.logger.debug(
                "VM converging on agent",
                metadata: [
                    "strato.vm.id": .string(vmID.uuidString),
                    "phase": .string(effectivePhase ?? ""),
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
        if let appliedNetworkInterfaceIds = observed.appliedNetworkInterfaceIds {
            let applied = Set(appliedNetworkInterfaceIds)
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
            vm.setStatus(observed.status, at: instant)
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
                        "strato.vm.id": .string(vmID.uuidString),
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
        // A blocked refusal is both an actionable error and an unfinished
        // convergence attempt. The agent will re-drive it at this generation,
        // so retain desired state and the deadline while persisting the
        // degraded reason. The deadline sweep remains the backstop if the host
        // never recovers. An unclassified failure from an older agent keeps the
        // historical terminal behavior.
        //
        // With no deadline, no user mutation is outstanding. That is a
        // steady-state repair failure and follows the same retain-and-retry
        // path regardless of classification.
        if failedCurrentGeneration,
            observed.failureClassification == .blocked || vm.convergenceDeadline == nil
        {
            if changed {
                try await vm.save(on: db)
            }
            await emitVMStatusTransition(statusTransition, vm: vm, on: db)
            return
        }
        let previousStatus = vm.status
        var enteredError = false
        let settlement = try await settleConvergence(
            vm,
            wasConverged: wasConverged,
            changed: changed,
            reportedError: observed.lastError,
            reportedFailedGeneration: observed.failedGeneration,
            previousFailureGeneration: failedBefore,
            defaultMutation: .boot,
            at: instant,
            prepareFailure: { vm in
                guard failedBefore != vm.generation,
                    observed.status == .unknown,
                    vm.status != .error
                else { return }
                vm.setStatus(.error, at: instant)
                enteredError = true
                Telemetry.vmEnteredError(reason: "convergence_failed")
            },
            on: db)
        await emitVMStatusTransition(statusTransition, vm: vm, on: db)
        if case .failed(.recorded) = settlement, enteredError {
            await WebhookEvents.emitVMStateChanged(
                vm: vm, previous: previousStatus, current: .error, on: db, logger: app.logger)
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
    func pendingBootVolumePhase(
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
    func emitVMStatusTransition(
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
    func persistGuestInfo(
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
    func persistMemoryStats(
        vm: VM, stats: VMMemoryStats, at instant: ClusterInstant, on db: Database
    ) async throws {
        guard
            vm.guestMemoryTotalBytes != stats.totalBytes
                || vm.guestMemoryAvailableBytes != stats.availableBytes
                || vm.guestMemoryBalloonActualBytes != stats.balloonActualBytes
        else { return }
        vm.guestMemoryTotalBytes = stats.totalBytes
        vm.guestMemoryAvailableBytes = stats.availableBytes
        vm.guestMemoryBalloonActualBytes = stats.balloonActualBytes
        vm.guestMemoryStatsAt = instant.date
        try await vm.save(on: db)
    }

    /// Clears a VM's observed memory stats once the guest is definitively not
    /// running — a stopped guest's last-known usage is stale, and surfacing it
    /// as current would mislead the "committed vs used" view.
    func clearMemoryStats(vm: VM, on db: Database) async throws {
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
    static let guestInfoClearedByStatus: Set<VMStatus> = [.shutdown, .created, .error]

    /// Clears a VM's observed guest-agent state (hostname, availability, and all
    /// per-NIC observed addresses). Short-circuits when there's nothing recorded
    /// so it's a no-op on the steady stream of reports for a VM that never had a
    /// guest agent.
    func clearGuestInfo(
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
    func handleReportedAbsence(
        vm: VM,
        agentId: String,
        at instant: ClusterInstant,
        on db: Database
    ) async throws {
        let vmID = try vm.requireID()

        if try await confirmTeardown(
            vm,
            removedMessage: "VM deletion confirmed by agent report; record removed",
            heldMessage: "VM teardown confirmed by agent report; awaiting finalizers",
            metadata: [
                "strato.vm.id": .string(vmID.uuidString),
                "strato.agent.id": .string(agentId),
            ],
            on: db)
        {
            return
        }

        // A report lists everything the agent is converging or has failed to
        // converge, so an omitted VM has no progress to report at all — most
        // often because the agent restarted and lost its in-memory view. Drop
        // whatever it last said, rather than leave `conditions` claiming a
        // download that nothing is doing (STR-142).
        let convergenceCleared = vm.recordTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil, at: instant)

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
        vm.setStatus(.error, at: instant)
        try await vm.save(on: db)
        Telemetry.vmEnteredError(reason: "reconciliation")
        await WebhookEvents.emitVMStateChanged(
            vm: vm, previous: previous, current: .error, on: db, logger: app.logger)
        app.logger.warning(
            "VM missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "strato.vm.id": .string(vmID.uuidString),
                "strato.agent.id": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

    /// Sandbox counterpart of `applyObservedVMState`: apply one settled (or
    /// failing) observation and record the convergence transition it produces.
    func applyObservedSandboxState(
        sandbox: Sandbox,
        observed: ObservedSandboxState,
        at instant: ClusterInstant,
        on db: Database
    ) async throws {
        let sandboxID = try sandbox.requireID()
        try logSupersededFailureReport(sandbox, reportedGeneration: observed.failedGeneration)
        let wasConverged = sandbox.isConverged
        let failedBefore = sandbox.failedGeneration

        var resourceTelemetryChanged = false
        if let telemetry = observed.resourceTelemetry, sandbox.resourceTelemetry != telemetry {
            sandbox.resourceTelemetry = telemetry
            sandbox.resourceTelemetryReceivedAt = instant.date
            resourceTelemetryChanged = true
        }
        if let agentID = sandbox.hypervisorId {
            Telemetry.recordWorkloadResourceTelemetry(
                agentID: agentID,
                workloadID: sandboxID.uuidString,
                kind: .sandbox,
                telemetry: observed.resourceTelemetry)
        }

        // Convergence progress for the `conditions` block (STR-142) — same
        // contract as VMs, recorded on both paths for the same reasons.
        var changed = sandbox.recordTimestampedConvergence(
            phase: observed.convergencePhase,
            lastError: observed.lastError,
            failedGeneration: observed.failedGeneration,
            at: instant
        )
        changed = resourceTelemetryChanged || changed

        // Still converging: progress only, never a settled status.
        if observed.convergencePhase != nil {
            if changed {
                try await sandbox.save(on: db)
            }
            app.logger.debug(
                "Sandbox converging on agent",
                metadata: [
                    "strato.sandbox.id": .string(sandboxID.uuidString),
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
            sandbox.setStatus(observed.status, at: instant)
            changed = true

            // A workload finishing on its own (`.exited`) is the normal end
            // of a one-shot sandbox, not drift — only flag other unprompted
            // changes.
            if wasConverged, !previous.isTransitional, observed.status != .exited {
                app.logger.warning(
                    "Sandbox state drifted with nothing in flight",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxID.uuidString),
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
        // Blocked failures remain active mutations because the agent will
        // re-drive them at this generation. A failure with no deadline is a
        // steady-state repair and retains intent for the same reason.
        if failedCurrentGeneration,
            observed.failureClassification == .blocked || sandbox.convergenceDeadline == nil
        {
            if changed {
                try await sandbox.save(on: db)
            }
            return
        }
        _ = try await settleConvergence(
            sandbox,
            wasConverged: wasConverged,
            changed: changed,
            reportedError: observed.lastError,
            reportedFailedGeneration: observed.failedGeneration,
            previousFailureGeneration: failedBefore,
            defaultMutation: .boot,
            at: instant,
            prepareFailure: { sandbox in
                if failedBefore != sandbox.generation, observed.status == .unknown {
                    sandbox.setStatus(.error, at: instant)
                }
            },
            on: db)
    }

    /// A sandbox the database maps to this agent is absent from its full
    /// report: either a confirmed deletion (desired absent) or genuine loss.
    func handleReportedSandboxAbsence(
        sandbox: Sandbox,
        agentId: String,
        at instant: ClusterInstant,
        on db: Database
    ) async throws {
        let sandboxID = try sandbox.requireID()

        if try await confirmTeardown(
            sandbox,
            removedMessage: "Sandbox deletion confirmed by agent report; record removed",
            heldMessage: "Sandbox teardown confirmed by agent report; awaiting finalizers",
            metadata: [
                "strato.sandbox.id": .string(sandboxID.uuidString),
                "strato.agent.id": .string(agentId),
            ],
            on: db)
        {
            return
        }

        // Nothing to report means no progress to report — same rationale as
        // the VM path (STR-142).
        let convergenceCleared = sandbox.recordTimestampedConvergence(
            phase: nil, lastError: nil, failedGeneration: nil, at: instant)

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
        sandbox.setStatus(.error, at: instant)
        try await sandbox.save(on: db)
        app.logger.warning(
            "Sandbox missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "strato.sandbox.id": .string(sandboxID.uuidString),
                "strato.agent.id": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

}
