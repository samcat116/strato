import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("snapshot capacity admission")
struct SnapshotCapacityAdmissionTests {
    private let gib: Int64 = 1_073_741_824

    @Test("a local snapshot reserves its parent's materialized virtual size")
    func snapshotReservesMaterializedParentSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-capacity-admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = Logger(label: "snapshot-capacity-admission-test")
        let backend = MockStorageBackend(
            logger: logger,
            volumeStoragePath: root.appendingPathComponent("volumes").path)
        let agent = Agent(
            agentID: "hv-snapshot",
            webSocketURL: "ws://127.0.0.1:8080/agent",
            networkMode: nil,
            logger: logger,
            vmStoragePath: root.appendingPathComponent("vms").path,
            volumeStoragePath: root.appendingPathComponent("volumes").path,
            simulation: SimulationConfig(enabled: true, diskGB: 100))
        await agent.installStorageBackendForSnapshotCapacityTest(backend)

        let parentId = UUID()
        let snapshotId = UUID()
        _ = try await backend.createVolume(
            volumeId: parentId.uuidString, sizeBytes: 40 * gib, format: .qcow2)
        let parentDesired = DesiredVolumeState(
            volumeId: parentId,
            desiredStatus: .present,
            generation: 1,
            sizeBytes: 10 * gib,
            format: DiskFormat.qcow2.rawValue)
        await agent.setDesiredVolumeForSnapshotCapacityTest(parentDesired)

        let desired = DesiredSnapshotState(
            snapshotId: snapshotId,
            kind: .volumeSnapshot,
            parentId: parentId,
            desiredStatus: .present,
            generation: 1,
            volumeStorage: .local)
        let item = ReconcileWorkItem(
            kind: .volumeSnapshot,
            id: snapshotId.uuidString,
            generation: desired.generation,
            steps: [.create],
            target: .snapshot(desired))

        try await agent.snapshotReconcileCapture(item)

        let state = await agent.snapshotCapacityStateForTest(snapshotId)
        #expect(state.reservedDiskBytes == 40 * gib)
        #expect(state.provisionalDiskBytes == 0)
    }

    @Test("snapshot admission claims the materialized parent size")
    func snapshotClaimsMaterializedParentSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-capacity-claim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = Logger(label: "snapshot-capacity-claim-test")
        let backend = MockStorageBackend(
            logger: logger,
            volumeStoragePath: root.appendingPathComponent("volumes").path)
        let agent = Agent(
            agentID: "hv-snapshot-full",
            webSocketURL: "ws://127.0.0.1:8080/agent",
            networkMode: nil,
            logger: logger,
            vmStoragePath: root.appendingPathComponent("vms").path,
            volumeStoragePath: root.appendingPathComponent("volumes").path,
            simulation: SimulationConfig(enabled: true, diskGB: 70))
        await agent.installStorageBackendForSnapshotCapacityTest(backend)

        let parentId = UUID()
        let snapshotId = UUID()
        _ = try await backend.createVolume(
            volumeId: parentId.uuidString, sizeBytes: 40 * gib, format: .qcow2)
        await agent.setDesiredVolumeForSnapshotCapacityTest(
            DesiredVolumeState(
                volumeId: parentId,
                desiredStatus: .present,
                generation: 1,
                sizeBytes: 10 * gib,
                format: DiskFormat.qcow2.rawValue))

        let desired = DesiredSnapshotState(
            snapshotId: snapshotId,
            kind: .volumeSnapshot,
            parentId: parentId,
            desiredStatus: .present,
            generation: 1,
            volumeStorage: .local)
        let item = ReconcileWorkItem(
            kind: .volumeSnapshot,
            id: snapshotId.uuidString,
            generation: desired.generation,
            steps: [.create],
            target: .snapshot(desired))

        do {
            try await agent.snapshotReconcileCapture(item)
            Issue.record("expected the materialized parent size to exceed remaining capacity")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.resource == .disk)
            #expect(error.failureClassification == .blocked)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let state = await agent.snapshotCapacityStateForTest(snapshotId)
        #expect(state.reservedDiskBytes == nil)
        #expect(state.provisionalDiskBytes == 0)
    }
}

extension Agent {
    fileprivate func installStorageBackendForSnapshotCapacityTest(_ backend: any StorageBackend) {
        storageBackend = backend
        storageBackends = StorageBackendRegistry(
            local: backend,
            makeCeph: { _ in fatalError("Ceph is not used by this test") })
    }

    fileprivate func setDesiredVolumeForSnapshotCapacityTest(_ desired: DesiredVolumeState) {
        desiredVolumeStates[desired.volumeId.uuidString] = desired
    }

    fileprivate func snapshotCapacityStateForTest(
        _ snapshotId: UUID
    ) -> (reservedDiskBytes: Int64?, provisionalDiskBytes: Int64) {
        (
            snapshotRecords[snapshotId]?.reservedDiskBytes,
            capacityAdmissionLedger.provisionalReservation.diskBytes
        )
    }
}
