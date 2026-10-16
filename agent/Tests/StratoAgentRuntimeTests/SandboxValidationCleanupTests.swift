#if os(Linux)
import Foundation
import Logging
import StratoAgentCore
import StratoShared
import SwiftFirecracker
import Testing

@testable import StratoAgentRuntime

@Suite("suspension validation cleanup ownership")
struct SandboxValidationCleanupTests {
    enum CleanupFailure: Error, Sendable { case destroy, inventory }

    @Test(arguments: [CleanupFailure.destroy, .inventory])
    func failedCleanupRetainsCapacityAndPermitAcrossRestart(failure: CleanupFailure) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reservation = HostReservation(cpus: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024)
        let proof = SandboxValidationProof(id: UUID(), permit: UUID(), jailUID: 100000, reservation: reservation)
        let store = SandboxValidationProofStore(directory: root.path + "/suspension-validation")
        try store.save(proof)
        let runtime = try makeRuntime(root: root)
        #expect(await runtime.validationPermitCountForTest() == 1)
        #expect(try await runtime.suspensionValidationReservations()[proof.proofId] == reservation)
        await #expect(throws: CleanupFailure.self) {
            try await runtime.finishValidationProofCleanup(templateId: proof.proofId) { throw failure }
        }
        #expect(try store.loadAll() == [proof])
        #expect(await runtime.validationPermitCountForTest() == 1)
        await #expect(throws: SandboxSuspensionGuard.GateError.busy) {
            _ = try await runtime.acquireValidationPermitForTest()
        }

        // The durable record, rather than an in-memory defer, owns capacity
        // and restore admission after the failed process-death proof.
        let restarted = try makeRuntime(root: root)
        #expect(await restarted.validationPermitCountForTest() == 1)
        #expect(try await restarted.suspensionValidationReservations()[proof.proofId] == reservation)
        await #expect(throws: SandboxSuspensionGuard.GateError.busy) {
            _ = try await restarted.acquireValidationPermitForTest()
        }
        try await restarted.finishValidationProofCleanup(templateId: proof.proofId) {}
        #expect(try store.loadAll().isEmpty)
        #expect(await restarted.validationPermitCountForTest() == 0)
        #expect(try await restarted.suspensionValidationReservations().isEmpty)
        _ = try await restarted.acquireValidationPermitForTest()
        #expect(await restarted.validationPermitCountForTest() == 1)
    }

    @Test func recoverySkipsActiveValidationProof() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reservation = HostReservation(cpus: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024)
        let proof = SandboxValidationProof(id: UUID(), permit: UUID(), jailUID: 100000, reservation: reservation)
        let store = SandboxValidationProofStore(directory: root.path + "/suspension-validation")
        try store.save(proof)
        let runtime = try makeRuntime(root: root)
        await runtime.markActiveValidationProofForTest(proof.proofId)
        // Recovery must not issue teardown against a concurrently active
        // validation. The missing client binary makes accidental work fail.
        try await runtime.recoverAbandonedValidationProofs()
        #expect(try store.loadAll() == [proof])
        #expect(await runtime.validationPermitCountForTest() == 1)
        #expect(try await runtime.suspensionValidationReservations()[proof.proofId] == reservation)
        await #expect(throws: SandboxSuspensionGuard.GateError.busy) {
            _ = try await runtime.acquireValidationPermitForTest()
        }
    }

    private func makeRuntime(root: URL) throws -> FirecrackerSandboxRuntime {
        let logger = Logger(label: "validation-cleanup-test")
        let binary = root.path + "/missing-firecracker"
        let sockets = root.path + "/sockets"
        return try FirecrackerSandboxRuntime(
            logger: logger,
            client: FirecrackerClient(firecrackerBinaryPath: binary, socketDirectory: sockets, logger: logger),
            imageService: SandboxImageService(logger: logger, cacheRootPath: root.path + "/images"),
            socketDirectory: sockets, sandboxStoragePath: root.path, guestImagePath: root.path + "/missing-kernel",
            firecrackerBinaryPath: binary,
            jailer: SandboxJailerConfig(
                jailerBinaryPath: root.path + "/missing-jailer", chrootBaseDir: root.path + "/jails", uidBase: 100000),
            jailUIDAllocator: SandboxJailUIDAllocator(uidBase: 100000), legacyJailerUIDBase: 100000,
            jailNewSandboxes: true, warmStartEnabled: false, suspensionRestoreLimit: 1)
    }
}

extension FirecrackerSandboxRuntime {
    fileprivate func markActiveValidationProofForTest(_ id: String) {
        activeValidationProofs.insert(id)
        validationProofRecoveryPending = true
    }
    fileprivate func validationPermitCountForTest() -> Int { restoreAdmission.activeCount }
    fileprivate func acquireValidationPermitForTest() throws -> UUID { try restoreAdmission.acquire() }
}
#endif
