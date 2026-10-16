import Fluent
import StratoShared
import Vapor

/// Runs inside the sandbox row-lock transaction. Quota admission uses the
/// existing shared quota locks; row state is the canonical reservation ledger.
enum SandboxSuspensionService {
    static func admitSuspension(_ sandbox: Sandbox, on db: any Database) async throws {
        guard sandbox.hypervisorId != nil, sandbox.observedGeneration > 0,
            let estimate = sandbox.suspensionStorageEstimateBytes, estimate > 0
        else { throw Abort(.conflict, reason: "Agent has not reported a durable suspension storage estimate") }
        let (budget, overflow) = sandbox.suspensionStorageBytes.addingReportingOverflow(estimate)
        guard !overflow else { throw Abort(.conflict, reason: "Checkpoint storage estimate overflow") }
        let project = try await sandbox.project(on: db)
        try await QuotaEnforcementService.reserveSnapshotStorage(
            for: project, environment: sandbox.environment, size: estimate, on: db)
        sandbox.suspensionStorageBytes = budget
    }

    static func admitWake(_ sandbox: Sandbox, on db: any Database) async throws {
        sandbox.suspensionAfterSnapshotId = nil
        guard !sandbox.suspensionComputeReserved else { return }
        let project = try await sandbox.project(on: db)
        try await QuotaEnforcementService.reserveVMResize(
            for: project, environment: sandbox.environment,
            vcpuDelta: sandbox.cpus, memoryDelta: sandbox.memory, on: db)
        sandbox.suspensionComputeReserved = true
    }

    static func apply(_ observed: ObservedSandboxState, to sandbox: Sandbox, on db: any Database) async throws -> Bool {
        var changed = false
        if let estimate = observed.suspensionStorageEstimateBytes, estimate > 0,
            estimate != sandbox.suspensionStorageEstimateBytes
        {
            sandbox.suspensionStorageEstimateBytes = estimate
            changed = true
        }
        if observed.convergencePhase == nil, observed.failedGeneration == sandbox.generation,
            observed.status == .running, let retained = observed.suspensionStorageReservedBytes,
            retained >= 0, retained < sandbox.suspensionStorageBytes
        {
            sandbox.suspensionStorageBytes = retained
            try await sandbox.save(on: db)
            try await QuotaEnforcementService.refreshSandboxReservations(sandbox, on: db)
            changed = true
        }
        guard observed.observedGeneration == sandbox.generation,
            observed.convergencePhase == nil, observed.failedGeneration != sandbox.generation,
            let evidence = observed.suspension, evidence.verified, evidence.storageBytes > 0
        else { return changed }
        let release = evidence.permitsComputeRelease(
            for: observed, desiredGeneration: sandbox.generation,
            desiredStatus: sandbox.desiredStatus, admittedBytes: sandbox.suspensionStorageBytes)
        // Retained checkpoints continue consuming storage after wake. Unknown
        // reports never erase either a reservation or the recovery reference.
        guard release || (sandbox.suspensionComputeReserved && observed.status == .running) else { return changed }
        let quotaChanged =
            sandbox.suspensionComputeReserved == release
            || sandbox.suspensionStorageBytes != evidence.storageBytes
        if sandbox.suspensionEvidence != evidence || quotaChanged {
            sandbox.suspensionEvidence = evidence
            sandbox.suspensionStorageBytes = evidence.storageBytes
            sandbox.suspensionComputeReserved = !release
            changed = true
            // Publish ledger facts before the recount in this same transaction.
            try await sandbox.save(on: db)
            try await QuotaEnforcementService.refreshSandboxReservations(sandbox, on: db)
        }
        return changed
    }
}
