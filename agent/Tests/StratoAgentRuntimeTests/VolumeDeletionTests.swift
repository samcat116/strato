import Foundation
import Logging
import Testing
import StratoAgentCore
import StratoShared
@testable import StratoAgentRuntime

@Suite("Volume deletion safety")
struct VolumeDeletionTests {
    @Test(arguments: [false, true])
    func uncertainDetachPreservesBytesAndManifest(orphan: Bool) async throws {
        try await exercise(orphan: orphan, error: .timeout("driver unavailable"), deletes: false)
    }

    @Test func absentOrphanAllowsDeletion() async throws {
        try await exercise(orphan: true, error: .adoptionTargetGone("gone"), deletes: true)
    }

    @Test func absentManagedDomainAllowsDeletion() async throws {
        try await exercise(orphan: false, error: .vmNotFound("gone"), deletes: true)
    }

    @Test func successfulDetachAllowsDeletion() async throws {
        try await exercise(orphan: false, error: nil, deletes: true)
    }

    private func exercise(orphan: Bool, error: HypervisorServiceError?, deletes: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let logger = Logger(label: "volume-deletion-test")
        let agent = Agent(
            agentID: "test", webSocketURL: "wss://localhost/agent/ws",
            configuration: runtimeTestConfiguration(path: path), logger: logger)
        let backend = MockStorageBackend(logger: logger, volumeStoragePath: path)
        let volumeID = UUID()
        let vmID = UUID().uuidString
        let attachment = try await backend.createVolume(volumeId: volumeID.uuidString, sizeBytes: 1024, format: .raw)
        let entry = VMManifestEntry(
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil),
                volumes: [VolumeSpec(volumeId: volumeID, deviceName: .disk(0), attachment: attachment)]))
        await agent.seedVolumeDeletion(
            backend: backend, driver: DetachDriver(error: error),
            vmID: vmID, entry: entry, orphan: orphan)
        let item = ReconcileWorkItem(
            kind: .volume, id: volumeID.uuidString, generation: 1,
            steps: [.delete],
            target: .volume(
                DesiredVolumeState(
                    volumeId: volumeID, desiredStatus: .absent, generation: 1,
                    sizeBytes: 1024, format: "raw")))
        do {
            if deletes {
                try await agent.volumeReconcileDelete(item)
            } else {
                await #expect(throws: HypervisorServiceError.self) { try await agent.volumeReconcileDelete(item) }
            }
            #expect((try await backend.inspectVolume(volumeId: volumeID.uuidString) != nil) == !deletes)
            #expect((await agent.recordedVolumeAttachments()[volumeID.uuidString] != nil) == !deletes)
            try await agent.eventLoopGroup.shutdownGracefully()
        } catch {
            try? await agent.eventLoopGroup.shutdownGracefully()
            throw error
        }
    }
}

private extension Agent {
    func seedVolumeDeletion(
        backend: MockStorageBackend, driver: DetachDriver,
        vmID: String, entry: VMManifestEntry, orphan: Bool
    ) {
        storageBackends = StorageBackendRegistry(
            local: backend, makeCeph: { _ in fatalError("unexpected Ceph volume") })
        hypervisorServices[.qemu] = driver
        if orphan { orphanedVMs[vmID] = entry } else { managedVMs[vmID] = entry }
    }
}

private actor DetachDriver: HypervisorService {
    let hypervisorType: HypervisorType = .qemu
    let error: HypervisorServiceError?
    init(error: HypervisorServiceError?) { self.error = error }
    func detachDisk(vmId: String, volumeId: String, deviceName: String) throws { if let error { throw error } }
    func adoptVM(vmId: String, spec: VMSpec) throws -> VMStatus {
        if let error { throw error }
        return .running
    }
    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?, networkAttachments: [ResolvedNetworkAttachment],
        metadata: InstanceMetadata?, vsockCID: UInt32?
    ) {}
    func bootVM(vmId: String) {}
    func shutdownVM(vmId: String) {}
    func rebootVM(vmId: String) {}
    func pauseVM(vmId: String) {}
    func resumeVM(vmId: String) {}
    func deleteVM(vmId: String) {}
    func reclaimVMDirectory(vmId: String) {}
    func getVMStatus(vmId: String) -> VMStatus { .running }
    func consoleEndpoint(vmId: String) -> ConsoleEndpoint? { nil }
    func attachDisk(
        vmId: String, volumeId: String, attachment: DiskAttachment, deviceName: String, readonly: Bool,
        blockPolicy: AppliedBlockDevicePolicy?, orderedBootVolumeIds: [String], ioLimits: VolumeIOLimits?
    ) {}
    func reservationInventory() -> HypervisorReservationInventory? { nil }
}
