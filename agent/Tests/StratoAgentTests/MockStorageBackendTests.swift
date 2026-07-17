import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Mock Storage Backend")
struct MockStorageBackendTests {

    private func backend(root: String) -> MockStorageBackend {
        MockStorageBackend(logger: Logger(label: "test"), volumeStoragePath: root)
    }

    private func imageInfo(size: Int64 = 4 * 1024 * 1024 * 1024) -> ImageInfo {
        ImageInfo(
            imageId: UUID(),
            projectId: UUID(),
            filename: "test.qcow2",
            checksum: "deadbeef",
            size: size,
            downloadURL: "https://example.invalid/test.qcow2"
        )
    }

    /// The whole point: a simulated agent must not write to the filesystem, even
    /// though volume placement will hand it real work.
    @Test("Creating volumes writes nothing to disk")
    func createsNoFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-storage-\(UUID().uuidString)").path
        let sut = backend(root: root)

        let attachment = try await sut.createVolume(volumeId: "vol-1", sizeBytes: 1024, format: .qcow2)
        _ = try await sut.createVolumeFromImage(volumeId: "vol-2", imageInfo: imageInfo(), format: .raw)
        _ = try await sut.createSnapshot(volumeId: "vol-1", snapshotId: "snap-1", volumePath: attachment.path)

        #expect(!FileManager.default.fileExists(atPath: attachment.path))
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test("Reported paths mirror the real backend's layout")
    func pathLayout() async throws {
        let sut = backend(root: "/var/lib/strato/volumes")
        let attachment = try await sut.createVolume(volumeId: "vol-1", sizeBytes: 1024, format: .qcow2)
        #expect(attachment.path == "/var/lib/strato/volumes/vol-1/volume.qcow2")
        #expect(attachment.format == .qcow2)

        let raw = try await sut.createVolume(volumeId: "vol-2", sizeBytes: 1024, format: .raw)
        #expect(raw.path == "/var/lib/strato/volumes/vol-2/volume.raw")
    }

    @Test("A from-image volume takes its virtual size from the image, and reports no consumption")
    func fromImageSize() async throws {
        let sut = backend(root: "/tmp/x")
        let image = imageInfo(size: 8 * 1024 * 1024 * 1024)
        let attachment = try await sut.createVolumeFromImage(volumeId: "vol-1", imageInfo: image, format: .qcow2)

        let info = try await sut.volumeInfo(volumePath: attachment.path)
        #expect(info.virtualSize == 8 * 1024 * 1024 * 1024)
        // A volume that does not exist consumes nothing; reporting otherwise
        // would fabricate host disk usage.
        #expect(info.actualSize == 0)
        #expect(info.format == "qcow2")
    }

    @Test("Unknown volumes throw, matching the real backend's contract")
    func unknownVolumesThrow() async throws {
        let sut = backend(root: "/tmp/x")
        await #expect(throws: StorageBackendError.self) {
            _ = try await sut.volumeInfo(volumePath: "/tmp/x/nope/volume.qcow2")
        }
        await #expect(throws: StorageBackendError.self) {
            try await sut.resizeVolume(volumePath: "/tmp/x/nope/volume.qcow2", newSizeBytes: 2048)
        }
        await #expect(throws: StorageBackendError.self) {
            _ = try await sut.cloneVolume(sourceVolumeId: "nope", sourcePath: "/x", targetVolumeId: "t")
        }
        await #expect(throws: StorageBackendError.self) {
            _ = try await sut.createSnapshot(volumeId: "nope", snapshotId: "s", volumePath: "/x")
        }
    }

    @Test("Resize updates the reported virtual size")
    func resize() async throws {
        let sut = backend(root: "/tmp/x")
        let attachment = try await sut.createVolume(volumeId: "vol-1", sizeBytes: 1024, format: .qcow2)
        try await sut.resizeVolume(volumePath: attachment.path, newSizeBytes: 4096)
        let info = try await sut.volumeInfo(volumePath: attachment.path)
        #expect(info.virtualSize == 4096)
    }

    @Test("Clone produces an independent volume with the source's size and format")
    func clone() async throws {
        let sut = backend(root: "/tmp/x")
        let source = try await sut.createVolume(volumeId: "src", sizeBytes: 2048, format: .raw)
        let clone = try await sut.cloneVolume(sourceVolumeId: "src", sourcePath: source.path, targetVolumeId: "dst")

        #expect(clone.path == "/tmp/x/dst/volume.raw")
        #expect(clone.format == .raw)
        let info = try await sut.volumeInfo(volumePath: clone.path)
        #expect(info.virtualSize == 2048)

        // Independent: deleting the source leaves the clone intact.
        try await sut.deleteVolume(volumeId: "src")
        let stillThere = try await sut.volumeInfo(volumePath: clone.path)
        #expect(stillThere.virtualSize == 2048)
    }

    @Test("Delete is idempotent, like the real backend")
    func deleteIsIdempotent() async throws {
        let sut = backend(root: "/tmp/x")
        _ = try await sut.createVolume(volumeId: "vol-1", sizeBytes: 1024, format: .qcow2)
        try await sut.deleteVolume(volumeId: "vol-1")
        try await sut.deleteVolume(volumeId: "vol-1")  // must not throw
        try await sut.deleteSnapshot(volumeId: "vol-1", snapshotId: "never-existed")
    }

    @Test("materializeDisk reports the requested path and format without writing it")
    func materialize() async throws {
        let sut = backend(root: "/tmp/x")
        let path = "/var/lib/strato/vms/vm-1/rootfs.raw"
        let attachment = try await sut.materializeDisk(
            at: path, from: imageInfo(), format: .raw, artifactKind: .rootfs)
        #expect(attachment.path == path)
        #expect(attachment.format == .raw)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
