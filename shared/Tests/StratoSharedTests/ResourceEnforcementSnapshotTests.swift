import Foundation
import Testing
@testable import StratoShared

@Suite("Resource enforcement wire67 contract")
struct ResourceEnforcementSnapshotTests {
    @Test func snapshotRoundTripPreservesAppliedIdentityAndAccounting() throws {
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: UUID(), revision: 3, policy: .burstable)
        let ledger = WorkloadAdmittedReservation(
            cpus: 2, memory: .init(guestBytes: 16384, backendOverheadBytes: 4096), policy: snapshot.policy)
        let limits = try snapshot.policy.runtimeLimits(guestBytes: 16384, backendOverheadBytes: 4096)
        let ack = WorkloadEnforcementAcknowledgement(
            kind: .vm, workloadId: UUID(), appliedGeneration: 7, resourceClass: snapshot, backend: .qemuVM,
            accountedReservation: ledger, runtimeGuestBytes: 16384, pageSizeBytes: 4096,
            desiredLimits: limits, appliedLimits: try limits.aligned(pageSizeBytes: 4096),
            cpuQuotaUnlimited: true, ownershipVerified: true)
        let report = ResourceEnforcementSnapshot(
            agentBootID: UUID(), sequence: 12, sampledAt: Date(), inventoryComplete: true, acknowledgements: [ack])
        let decoded = try JSONDecoder().decode(
            ResourceEnforcementSnapshot.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(WireProtocol.currentVersion == 67)
    }
}
