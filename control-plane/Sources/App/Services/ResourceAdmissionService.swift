import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Serializes durable growth charges and coherent report acceptance on the
/// agent row. Callers use a transaction; no expiring key is a source of truth.
enum ResourceAdmissionService {
    static func lockedState(agentID: UUID, on db: any Database) async throws -> (Agent, AgentResourceAdmission) {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("SELECT id FROM agents WHERE id = \(bind: agentID) FOR UPDATE").run()
        guard let agent = try await Agent.find(agentID, on: db) else { throw Abort(.notFound) }
        let row = try await AgentResourceAdmission.find(agentID, on: db) ?? AgentResourceAdmission(agentID: agentID)
        return (agent, row)
    }

    /// Session rotation/revocation must not leave the predecessor's coherent
    /// capacity usable. Pending commitments survive until fresh proof arrives.
    /// Legacy agents without this feature have no row and retain their path.
    static func invalidateSession(agentID: UUID, on db: any Database) async throws {
        guard try await AgentResourceAdmission.find(agentID, on: db) != nil else { return }
        let (_, row) = try await lockedState(agentID: agentID, on: db)
        row.state.inventoryComplete = false
        try await row.save(on: db)
    }

    static func capacity(agent: Agent, state: ResourceAdmissionState) -> ReservationAmounts {
        guard agent.manifestInventoryComplete != false, state.inventoryComplete != false else { return .zero }
        let raw = state.resources ?? agent.resources
        let pending = state.amounts
        let cpu = max(
            0,
            raw.availableCPUMicroUnits ?? WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: raw.availableCPU))
        return .init(
            memory: pending.memory >= raw.availableMemory ? 0 : raw.availableMemory - pending.memory,
            disk: max(0, raw.availableDisk),
            cpuMicroUnits: pending.cpuMicroUnits >= cpu ? 0 : cpu - pending.cpuMicroUnits)
    }

    /// Must run in the SAME transaction as sizing/snapshot/ledger/generation.
    static func stageGrowth(
        agentID: UUID, workloadID: UUID, generation: Int64, mutationID: UUID,
        admission: WorkloadResourceClassService.Admission, previous: WorkloadAdmittedReservation,
        backend: WorkloadResourceClassBackend, on db: any Database
    ) async throws -> (String, ReservationAmounts) {
        let (agent, row) = try await lockedState(agentID: agentID, on: db)
        let amount = admission.additionalReservation(over: previous)
        let available = capacity(agent: agent, state: row.state)
        guard generation > 0, amount.cpuMicroUnits <= available.cpuMicroUnits, amount.memory <= available.memory else {
            throw Abort(.conflict, reason: "Additional commitment does not fit durable host capacity")
        }
        let key = CoordinationService.growthReservationID(
            workloadID: workloadID, generation: generation, mutationID: mutationID)
        guard !row.state.pending.contains(where: { $0.reservationID == key }) else {
            throw Abort(.conflict, reason: "Growth mutation already staged")
        }
        row.state.pending.append(
            .init(
                reservationID: key, kind: .vm, workloadID: workloadID, generation: generation,
                resourceClass: admission.snapshot, previousReservation: previous, reservation: admission.reservation,
                backend: backend, cpuMicroUnits: amount.cpuMicroUnits, memoryBytes: amount.memory))
        try await row.save(on: db)
        return (key, available)
    }

    enum ReportOutcome: Sendable {
        case legacy
        case refused
        case accepted([String])
    }

    /// Persist net resources and remove only proven covered durable commitments
    /// atomically. Coordination keys are released by the caller AFTER commit.
    static func accept(
        _ report: ObservedStateReport, agentID: UUID, sessionID: UUID?, inventoryComplete: Bool,
        on db: any Database
    ) async throws -> ReportOutcome {
        try await db.transaction { tx in
            let (agent, row) = try await lockedState(agentID: agentID, on: tx)
            guard let snapshot = report.resourceEnforcement else {
                return row.state.bootID == nil ? .legacy : .refused
            }
            guard snapshot.sequence >= 0 else { return .refused }
            if row.state.bootID == snapshot.agentBootID {
                guard snapshot.sequence > row.state.sequence, row.state.requestID != report.requestId else {
                    return .refused
                }
            } else if row.state.bootID != nil, row.state.sessionID == sessionID {
                return .refused
            }
            var released: [String] = []
            if snapshot.inventoryComplete, inventoryComplete, accountingConsistent(report) {
                let keys = snapshot.acknowledgements.map { "\($0.kind.rawValue):\($0.workloadId)" }
                // Duplicates make the whole acknowledgement set unknown.
                if Set(keys).count == keys.count {
                    for ack in snapshot.acknowledgements {
                        guard observedMatches(ack, report: report),
                            try await matchesCommitted(ack, agent: agent, on: tx)
                        else { continue }
                        let covered = coveredClaims(ack, pending: row.state.pending)
                        released.append(contentsOf: covered)
                        row.state.pending.removeAll { covered.contains($0.reservationID) }
                    }
                }
            }
            row.state.sessionID = sessionID
            row.state.bootID = snapshot.agentBootID
            row.state.sequence = snapshot.sequence
            row.state.requestID = report.requestId
            row.state.resources = report.resources
            row.state.inventoryComplete =
                snapshot.inventoryComplete && inventoryComplete && accountingConsistent(report)
            try await row.save(on: tx)
            agent.updateAvailableResources(report.resources)
            try await agent.save(on: tx)
            return .accepted(released)
        }
    }

    /// Necessary arithmetic consistency; producer generation/ownership authority
    /// still supplies the proof that each footprint was included exactly once.
    static func accountingConsistent(_ report: ObservedStateReport) -> Bool {
        guard let snapshot = report.resourceEnforcement,
            let cpu = report.resources.availableCPUMicroUnits, cpu >= 0,
            let memory = report.resources.memoryAccounting,
            memory.physicalBytes == report.resources.totalMemory,
            memory.remainingAllocatableBytes == report.resources.availableMemory,
            memory.physicalBytes >= 0, memory.hostReservedBytes >= 0, memory.workloadEffectiveBytes >= 0,
            cpu <= WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: report.resources.totalCPU),
            report.resources.availableCPU == Int(cpu / 1_000_000)
        else { return false }
        let checked = HostMemoryAccounting(
            physicalBytes: memory.physicalBytes, hostReservedBytes: memory.hostReservedBytes,
            workloadEffectiveBytes: memory.workloadEffectiveBytes, qemuOverheadBytes: memory.qemuOverheadBytes)
        guard checked == memory else { return false }
        var acknowledgedCPU: Int64 = 0
        var acknowledgedMemory: Int64 = 0
        for ack in snapshot.acknowledgements {
            let (nextCPU, cpuOverflow) = acknowledgedCPU.addingReportingOverflow(ack.accountedReservation.cpuMicroUnits)
            let (nextMemory, memoryOverflow) = acknowledgedMemory.addingReportingOverflow(
                ack.accountedReservation.effectiveMemoryBytes)
            guard !cpuOverflow, !memoryOverflow else { return false }
            acknowledgedCPU = nextCPU
            acknowledgedMemory = nextMemory
        }
        return acknowledgedCPU <= WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: report.resources.totalCPU)
            - cpu
            && acknowledgedMemory <= memory.workloadEffectiveBytes
    }

    static func observedMatches(_ ack: WorkloadEnforcementAcknowledgement, report: ObservedStateReport) -> Bool {
        switch ack.kind {
        case .vm:
            let entries = report.vms.filter { $0.vmId == ack.workloadId }
            guard entries.count == 1, let entry = entries.first else { return false }
            return entry.observedGeneration == ack.appliedGeneration
                && entry.failedGeneration != ack.appliedGeneration && entry.lastError == nil
                && entry.convergencePhase == nil && entry.status == .running
        case .sandbox:
            let entries = report.sandboxes.filter { $0.sandboxId == ack.workloadId }
            guard entries.count == 1, let entry = entries.first else { return false }
            return entry.observedGeneration == ack.appliedGeneration
                && entry.failedGeneration != ack.appliedGeneration && entry.lastError == nil
                && entry.convergencePhase == nil && entry.status == .running
        default: return false
        }
    }

    static func covers(_ newer: WorkloadAdmittedReservation, _ older: WorkloadAdmittedReservation) -> Bool {
        newer.grantedCPUs >= older.grantedCPUs && newer.guestCommitmentBytes >= older.guestCommitmentBytes
            && newer.cpuMicroUnits >= older.cpuMicroUnits && newer.discountedGuestBytes >= older.discountedGuestBytes
            && newer.backendOverheadBytes >= older.backendOverheadBytes
    }

    /// A stored monotonic ledger chain proves cumulative coverage, rather than
    /// assuming an arbitrary newer generation includes earlier commitments.
    static func coveredClaims(
        _ ack: WorkloadEnforcementAcknowledgement, pending: [PendingResourceCommitment]
    ) -> [String] {
        let claims = pending.filter {
            $0.kind == ack.kind && $0.workloadID == ack.workloadId && $0.backend == ack.backend
                && $0.resourceClass.siteID == ack.resourceClass.siteID
                && $0.resourceClass.classID == ack.resourceClass.classID
                && $0.generation <= ack.appliedGeneration
        }.sorted { $0.generation < $1.generation }
        guard let last = claims.last,
            last.resourceClass == ack.resourceClass,
            last.reservation == ack.accountedReservation
        else { return [] }
        // Forked/same-generation attempts and gaps do not prove a chain.
        for (prior, next) in zip(claims, claims.dropFirst()) {
            guard prior.generation < next.generation, next.previousReservation == prior.reservation,
                covers(next.reservation, prior.reservation)
            else { return [] }
        }
        guard claims.allSatisfy({ covers($0.reservation, $0.previousReservation) }) else { return [] }
        return claims.map(\.reservationID)
    }

    static func matchesCommitted(
        _ ack: WorkloadEnforcementAcknowledgement, agent: Agent, on db: any Database
    ) async throws -> Bool {
        guard ack.appliedGeneration >= 0, ack.ownershipVerified, ack.cpuQuotaUnlimited,
            ack.runtimeGuestBytes > 0, ack.resourceClass.policy.kind == .burstable,
            ack.resourceClass.siteID == agent.$site.id,
            agent.resourceClassEnforcement?.filter({ $0.backend == ack.backend }).count == 1,
            agent.resourceClassEnforcement?.first(where: { $0.backend == ack.backend })?.supportsBurstable == true
        else { return false }
        let snapshot: WorkloadResourceClassSnapshot?
        let ledger: WorkloadAdmittedReservation?
        let generation: Int64
        let guest: Int64
        let owner: String?
        let backend: WorkloadResourceClassBackend?
        switch ack.kind {
        case .vm:
            guard let vm = try await VM.find(ack.workloadId, on: db), !vm.isTerminating else { return false }
            snapshot = vm.resourceClass
            ledger = vm.admittedReservation
            generation = vm.generation
            guest = vm.memory
            owner = vm.hypervisorId
            backend = vm.hypervisorType == .qemu ? .qemuVM : nil
        case .sandbox:
            guard let sandbox = try await Sandbox.find(ack.workloadId, on: db), !sandbox.isTerminating else {
                return false
            }
            snapshot = sandbox.resourceClass
            ledger = sandbox.admittedReservation
            generation = sandbox.generation
            guest = sandbox.memory
            owner = sandbox.hypervisorId
            backend = .jailedFirecrackerSandbox
        default: return false
        }
        guard snapshot == ack.resourceClass, ledger == ack.accountedReservation,
            generation == ack.appliedGeneration, guest == ack.runtimeGuestBytes,
            owner.flatMap(UUID.init(uuidString:)) == agent.id, backend == ack.backend,
            let ledger, ledger.guestCommitmentBytes >= guest,
            let desired = try? ack.resourceClass.policy.runtimeLimits(
                guestBytes: guest, backendOverheadBytes: ledger.backendOverheadBytes),
            desired == ack.desiredLimits,
            let aligned = try? desired.aligned(pageSizeBytes: ack.pageSizeBytes), aligned == ack.appliedLimits
        else { return false }
        return true
    }
}
