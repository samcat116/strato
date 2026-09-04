import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

private actor FailingVolumeInfoBackend: StorageBackend {
    private let backend: MockStorageBackend
    private var shouldFailVolumeInfo = true

    init(backend: MockStorageBackend) {
        self.backend = backend
    }

    func createVolume(
        volumeId: String, sizeBytes: Int64, format: DiskFormat
    ) async throws -> DiskAttachment {
        try await backend.createVolume(
            volumeId: volumeId, sizeBytes: sizeBytes, format: format)
    }

    func createVolumeFromImage(
        volumeId: String, imageInfo: ImageInfo, format: DiskFormat,
        artifactKind: ArtifactKind
    ) async throws -> DiskAttachment {
        try await backend.createVolumeFromImage(
            volumeId: volumeId, imageInfo: imageInfo, format: format,
            artifactKind: artifactKind)
    }

    func materializeDisk(
        at path: String, from imageInfo: ImageInfo, format: DiskFormat,
        artifactKind: ArtifactKind
    ) async throws -> DiskAttachment {
        try await backend.materializeDisk(
            at: path, from: imageInfo, format: format, artifactKind: artifactKind)
    }

    func deleteVolume(volumeId: String) async throws {
        try await backend.deleteVolume(volumeId: volumeId)
    }

    func rejectVolume(volumeId: String) async throws {
        try await backend.rejectVolume(volumeId: volumeId)
    }

    func resizeVolume(
        attachment: DiskAttachment, newSizeBytes: Int64
    ) async throws {
        try await backend.resizeVolume(
            attachment: attachment, newSizeBytes: newSizeBytes)
    }

    func createSnapshot(
        volumeId: String, snapshotId: String, attachment: DiskAttachment
    ) async throws -> String {
        try await backend.createSnapshot(
            volumeId: volumeId, snapshotId: snapshotId, attachment: attachment)
    }

    func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        try await backend.deleteSnapshot(volumeId: volumeId, snapshotId: snapshotId)
    }

    func cloneVolume(
        sourceVolumeId: String, sourceAttachment: DiskAttachment,
        targetVolumeId: String
    ) async throws -> DiskAttachment {
        try await backend.cloneVolume(
            sourceVolumeId: sourceVolumeId, sourceAttachment: sourceAttachment,
            targetVolumeId: targetVolumeId)
    }

    func volumeInfo(attachment: DiskAttachment) async throws -> VolumeInfoResult {
        if shouldFailVolumeInfo {
            shouldFailVolumeInfo = false
            throw StorageBackendError.infoFailed("injected post-publication probe failure")
        }
        return try await backend.volumeInfo(attachment: attachment)
    }

    func listVolumes() async throws -> [String: DiskAttachment] {
        try await backend.listVolumes()
    }
}

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

    @Test("a post-publication size probe failure rejects the materialized volume")
    func failedSizeProbeRejectsMaterializedVolume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-materialization-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = Logger(label: "volume-materialization-probe-test")
        let persistedBackend = MockStorageBackend(
            logger: logger,
            volumeStoragePath: root.appendingPathComponent("volumes").path)
        let backend = FailingVolumeInfoBackend(backend: persistedBackend)
        let agent = Agent(
            agentID: "hv-03",
            webSocketURL: "ws://127.0.0.1:8080/agent",
            networkMode: nil,
            logger: logger,
            vmStoragePath: root.appendingPathComponent("vms").path,
            volumeStoragePath: root.appendingPathComponent("volumes").path,
            simulation: SimulationConfig(enabled: true, diskGB: 100))
        await agent.installStorageBackendForAdmissionTest(backend)

        let volumeId = UUID()
        let imageInfo = ImageInfo(
            imageId: UUID(),
            projectId: UUID(),
            architecture: .x86_64,
            artifacts: [
                ArtifactInfo(
                    kind: .diskImage,
                    filename: "probe-failure.qcow2",
                    checksum: String(repeating: "e", count: 64),
                    size: 40 * gib,
                    downloadURL: "https://example.invalid/probe-failure.qcow2")
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

        await #expect(throws: StorageBackendError.self) {
            try await agent.volumeReconcileCreate(item)
        }

        #expect(try await persistedBackend.listVolumes().isEmpty)
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
