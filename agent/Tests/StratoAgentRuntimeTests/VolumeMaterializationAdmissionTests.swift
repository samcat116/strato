import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("volume materialization admission")
struct VolumeMaterializationAdmissionTests {
    private let gib: Int64 = 1_073_741_824

    @Test("an inherited size rejected after materialization is rolled back")
    func rejectedInheritedSizeIsRolledBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-materialization-admission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = Logger(label: "volume-materialization-admission-test")
        let backend = MockStorageBackend(
            logger: logger,
            volumeStoragePath: root.appendingPathComponent("volumes").path)
        let agent = Agent(
            agentID: "hv-03",
            webSocketURL: "ws://127.0.0.1:8080/agent",
            networkMode: nil,
            logger: logger,
            vmStoragePath: root.appendingPathComponent("vms").path,
            volumeStoragePath: root.appendingPathComponent("volumes").path,
            simulation: SimulationConfig(enabled: true, diskGB: 30))
        await agent.installStorageBackendForAdmissionTest(backend)

        let volumeId = UUID()
        let imageInfo = ImageInfo(
            imageId: UUID(),
            projectId: UUID(),
            architecture: .x86_64,
            artifacts: [
                ArtifactInfo(
                    kind: .diskImage,
                    filename: "oversized.qcow2",
                    checksum: String(repeating: "d", count: 64),
                    size: 40 * gib,
                    downloadURL: "https://example.invalid/oversized.qcow2")
            ])
        let desired = DesiredVolumeState(
            volumeId: volumeId,
            desiredStatus: .present,
            generation: 1,
            sizeBytes: 10 * gib,
            format: DiskFormat.qcow2.rawValue,
            source: DesiredVolumeSource(
                kind: DesiredVolumeSource.image,
                imageInfo: imageInfo,
                artifactKind: .diskImage))
        let item = ReconcileWorkItem(
            kind: .volume,
            id: volumeId.uuidString,
            generation: desired.generation,
            steps: [.create],
            target: .volume(desired))

        do {
            try await agent.volumeReconcileCreate(item)
            Issue.record("expected inherited virtual size to exceed host disk")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.resource == .disk)
            #expect(error.failureClassification == .permanent)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(try await backend.listVolumes().isEmpty)
        let state = await agent.volumeAdmissionStateForTest(volumeId.uuidString)
        #expect(state.virtualSize == nil)
        #expect(state.committedSize == nil)
        #expect(state.provisionalDiskBytes == 0)
    }
}

extension Agent {
    fileprivate func installStorageBackendForAdmissionTest(_ backend: any StorageBackend) {
        storageBackend = backend
        storageBackends = StorageBackendRegistry(
            local: backend,
            makeCeph: { _ in fatalError("Ceph is not used by this test") })
    }

    fileprivate func volumeAdmissionStateForTest(
        _ volumeId: String
    ) -> (virtualSize: Int64?, committedSize: Int64?, provisionalDiskBytes: Int64) {
        (
            volumeSizes[volumeId],
            volumeCommittedSizes[volumeId],
            capacityAdmissionLedger.provisionalReservation.diskBytes
        )
    }
}
