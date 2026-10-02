import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Durable suspension validation ownership")
struct SandboxValidationProofStoreTests {
    @Test func restartRetainsCapacityAndRestorePermit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let reservation = HostReservation(cpus: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024)
        let proof = SandboxValidationProof(id: UUID(), permit: UUID(), jailUID: 60_001, reservation: reservation)
        try SandboxValidationProofStore(directory: directory).save(proof)

        // A fresh store/admission pair models restart, without carrying runtime state.
        let recovered = try SandboxValidationProofStore(directory: directory).loadAll()
        #expect(recovered == [proof])
        #expect(recovered[0].reservation == reservation)
        let occupied = recovered.reduce(HostReservation()) { $0.addingSaturating($1.reservation) }
        var capacity = HostCapacityAdmissionLedger()
        let additional = HostReservation(cpus: 1, memoryBytes: 1024, diskBytes: 512)
        #expect(throws: HostCapacityAdmissionError.self) {
            try capacity.claim(
                additional, desiredWorkloadReservation: additional,
                snapshot: HostCapacitySnapshot(total: reservation, reserved: occupied), agentName: "fixture")
        }
        #expect(recovered[0].proofId == "warm-template-suspend-proof-" + proof.id.uuidString.lowercased())
        var admission = try SandboxRestoreAdmission(limit: 1)
        admission.recover(Set(recovered.map(\.permit)))
        #expect(admission.activeCount == 1)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try admission.acquire() }
        // Repeated reconciliation does not multiply ownership or lend it away.
        admission.recover(Set(recovered.map(\.permit)))
        admission.release(UUID())
        #expect(admission.activeCount == 1)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try admission.acquire() }
    }

    @Test func reducedLimitPreservesAllRecoveredOwnersUntilReleased() throws {
        let first = UUID()
        let second = UUID()
        var admission = try SandboxRestoreAdmission(limit: 1)
        admission.recover([first, second])
        #expect(admission.activeCount == 2)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try admission.acquire() }
        admission.release(first)
        #expect(admission.activeCount == 1)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try admission.acquire() }
        admission.release(second)
        let replacement = try admission.acquire()
        #expect(admission.activeCount == 1)
        #expect(replacement != first && replacement != second)
    }

    @Test func durableRemovalClearsOnlyConfirmedOwnerAcrossRestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = SandboxValidationProofStore(directory: directory)
        let reservation = HostReservation(cpus: 1, memoryBytes: 1024, diskBytes: 512)
        let first = SandboxValidationProof(id: UUID(), permit: UUID(), jailUID: 60_001, reservation: reservation)
        let second = SandboxValidationProof(id: UUID(), permit: UUID(), jailUID: 60_002, reservation: reservation)
        try store.save(first)
        try store.save(second)
        try store.remove(first.id)
        try store.remove(first.id)
        let remaining = try SandboxValidationProofStore(directory: directory).loadAll()
        #expect(remaining == [second])
        var admission = try SandboxRestoreAdmission(limit: 2)
        admission.recover(Set(remaining.map(\.permit)))
        _ = try admission.acquire()
        #expect(admission.activeCount == 2)
        #expect(throws: SandboxSuspensionGuard.GateError.busy) { try admission.acquire() }
        try store.remove(second.id)
        #expect(try SandboxValidationProofStore(directory: directory).loadAll().isEmpty)
    }

    @Test(arguments: [
        "invalid-json", "wrong-id", "zero-uid", "zero-reservation", "oversized", "invalid-filename", "duplicate-id",
        "duplicate-permit",
    ])
    func corruptInventoryFailsClosed(corruption: String) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = SandboxValidationProofStore(directory: directory)
        let good = SandboxValidationProof(
            id: UUID(uuidString: "ABCDEF01-0000-4000-8000-000000000001")!, permit: UUID(), jailUID: 60_001,
            reservation: HostReservation(cpus: 1, memoryBytes: 1024, diskBytes: 512))
        try store.save(good)
        let badID = UUID()
        var filename = badID.uuidString + ".json"
        let data: Data
        switch corruption {
        case "invalid-json": data = Data("{".utf8)
        case "oversized": data = Data(repeating: 32, count: 4097)
        case "wrong-id": data = try JSONEncoder().encode(good)
        case "duplicate-id":
            filename = good.id.uuidString.lowercased() + ".json"
            data = try JSONEncoder().encode(good)
        case "duplicate-permit":
            data = try JSONEncoder().encode(
                SandboxValidationProof(
                    id: badID, permit: good.permit, jailUID: 60_002, reservation: good.reservation))
        case "invalid-filename":
            filename = "unknown-owner.json"
            data = try JSONEncoder().encode(good)
        default:
            data = try JSONEncoder().encode(
                SandboxValidationProof(
                    id: badID, permit: UUID(), jailUID: corruption == "zero-uid" ? 0 : 60_002,
                    reservation: corruption == "zero-reservation" ? HostReservation() : good.reservation))
        }
        try data.write(to: URL(fileURLWithPath: directory + "/" + filename))
        if corruption == "duplicate-id",
            try FileManager.default.contentsOfDirectory(atPath: directory).filter({ $0.hasSuffix(".json") }).count == 1
        {
            // Case-insensitive filesystems cannot contain the two aliases.
            return
        }
        // A valid record beside a corrupt one cannot become partial/free inventory.
        #expect(throws: (any Error).self) { try store.loadAll() }
        #expect(FileManager.default.fileExists(atPath: directory + "/" + good.id.uuidString + ".json"))
    }

    private func temporaryDirectory() -> String {
        NSTemporaryDirectory() + "suspension-validation-test-" + UUID().uuidString
    }
}
