import Foundation
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftFirecracker

extension FirecrackerSandboxRuntime {
    /// One admitted plan and exact jailer path cover cold create, warm/fork
    /// snapshot load, in-place restore, adoption and paused-guest restart.
    func resourceLimitValidator(
        sandboxId: String, spec: SandboxSpec
    ) throws -> (@Sendable (Int32, String) throws -> Void)? {
        guard
            let limits = try BurstableResourceLimits.plan(
                resourceClass: spec.resourceClass, guestGrantBytes: spec.memoryBytes,
                backendOverheadBytes: WorkloadMemoryReservation.firecrackerOverheadBytes)
        else { return nil }
        try BurstableGuestGrant.verify(
            cpuCount: spec.cpus, memoryMiB: Int(spec.memoryBytes / (1024 * 1024)),
            admittedCPUs: spec.cpus, admittedBytes: spec.memoryBytes)
        let expectedPath = JailerOptions.cgroupDirectory(firecrackerBinaryPath: firecrackerBinaryPath, vmId: sandboxId)
        let pageSize = BurstableCgroupEnforcement.hostPageSizeBytes
        // Reject an unrepresentable plan before any backend action.
        _ = try limits.kernelMemoryBytes(pageSize: pageSize)
        return { pid, ownedPath in
            try BurstableCgroupEnforcement.verify(
                processID: pid, ownedPath: ownedPath, expectedPath: expectedPath,
                limits: limits, pageSize: pageSize)
        }
    }

    func resourceEnforcementEvidence(
        sandboxId: String, application: ResourceEnforcementProducer.Application,
        desired: BurstableResourceLimits
    ) async -> WorkloadResourceLimitsEvidence {
        do {
            try BurstableRuntimeGate.requireSupport(
                resourceClass: application.resourceClass, enforcement: burstableEnforcement)
            guard let managed = sandboxes[sandboxId], managed.spec.resourceClass == application.resourceClass,
                managed.spec.admittedReservation == application.reservation,
                managed.spec.memoryBytes == application.guestBytes, managed.spec.cpus == application.cpuCount
            else {
                throw ConvergenceError.blocked("Applied sandbox snapshot/grant differs from the convergence binding")
            }
            let actual = try await managed.manager.getMachineConfig()
            try BurstableGuestGrant.verify(
                cpuCount: actual.vcpuCount, memoryMiB: actual.memSizeMib,
                admittedCPUs: application.cpuCount, admittedBytes: application.guestBytes)
            let evidence = await resourceLimitsEvidence(sandboxId: sandboxId, desired: desired)
            guard sandboxes[sandboxId]?.manager === managed.manager else {
                throw ConvergenceError.blocked("Sandbox process changed during enforcement readback")
            }
            return evidence
        } catch {
            return .sample(limits: desired, ownedPath: nil, pageSize: BurstableCgroupEnforcement.hostPageSizeBytes)
        }
    }

    func resourceLimitsEvidence(sandboxId: String, desired: BurstableResourceLimits) async
        -> WorkloadResourceLimitsEvidence
    {
        let expectedPath = JailerOptions.cgroupDirectory(firecrackerBinaryPath: firecrackerBinaryPath, vmId: sandboxId)
        let pageSize = BurstableCgroupEnforcement.hostPageSizeBytes
        do {
            return try await client.readOwnedCgroup(vmId: sandboxId) { pid, path in
                try BurstableCgroupEnforcement.verifyOwnership(
                    processID: pid, ownedPath: path, expectedPath: expectedPath)
                return .sample(limits: desired, ownedPath: path, pageSize: pageSize, ownershipVerified: true)
            }
        } catch {
            return .sample(limits: desired, ownedPath: nil, pageSize: pageSize)
        }
    }

    func validateRestoredGrant(manager: FirecrackerManager, sandboxId: String, spec: SandboxSpec, resume: Bool)
        async throws
    {
        guard spec.resourceClass?.policy.kind == .burstable else { return }
        let actual = try await manager.getMachineConfig()
        try BurstableGuestGrant.verify(
            cpuCount: actual.vcpuCount, memoryMiB: actual.memSizeMib,
            admittedCPUs: spec.cpus, admittedBytes: spec.memoryBytes)
        try await validateResourceLimits(sandboxId: sandboxId, spec: spec)
        if resume { try await manager.resume() }
    }

    func validateResourceLimits(sandboxId: String, spec: SandboxSpec) async throws {
        guard let validator = try resourceLimitValidator(sandboxId: sandboxId, spec: spec) else { return }
        do {
            try await client.validateOwnedCgroup(vmId: sandboxId, validate: validator)
        } catch let error as ConvergenceError {
            throw error
        } catch {
            throw ConvergenceError.blocked(
                "Cannot acknowledge burstable jailer ownership: \(error.localizedDescription)")
        }
    }
}
#endif
