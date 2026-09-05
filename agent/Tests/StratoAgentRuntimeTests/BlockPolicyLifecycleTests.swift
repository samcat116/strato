import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

private actor BlockPolicyTestStorage: CephStorageBackend {
    let attachment: DiskAttachment

    init(attachment: DiskAttachment) {
        self.attachment = attachment
    }

    func createVolume(volumeId: String, sizeBytes: Int64, format: DiskFormat) async throws
        -> DiskAttachment
    { attachment }
    func createVolumeFromImage(
        volumeId: String, imageInfo: ImageInfo, format: DiskFormat,
        artifactKind: ArtifactKind
    ) async throws -> DiskAttachment { attachment }
    func materializeDisk(
        at path: String, from imageInfo: ImageInfo, format: DiskFormat,
        artifactKind: ArtifactKind
    ) async throws -> DiskAttachment { attachment }
    func deleteVolume(volumeId: String) async throws {}
    func resizeVolume(attachment: DiskAttachment, newSizeBytes: Int64) async throws {}
    func createSnapshot(
        volumeId: String, snapshotId: String, attachment: DiskAttachment
    ) async throws -> String { "/snapshot" }
    func deleteSnapshot(volumeId: String, snapshotId: String) async throws {}
    func cloneVolume(
        sourceVolumeId: String, sourceAttachment: DiskAttachment, targetVolumeId: String
    ) async throws -> DiskAttachment { attachment }
    func volumeInfo(attachment: DiskAttachment) async throws -> VolumeInfoResult {
        VolumeInfoResult(
            actualSize: 1, virtualSize: 1, format: "qcow2", dirty: false,
            encrypted: false)
    }
    func inspectVolume(volumeId: String) async throws -> DiskAttachment? { attachment }
    func qemuBlockCapabilities(
        for attachment: DiskAttachment
    ) async -> StorageBlockDeviceCapabilities {
        StorageBlockDeviceCapabilities(discardSupported: true, directIOSupported: true)
    }
    func listVolumes() async throws -> [String: DiskAttachment] { [:] }
    func invalidateForCredentialRevocation() async {}
}

private actor BlockPolicyAttachHypervisor: HypervisorService {
    nonisolated let hypervisorType: HypervisorType = .qemu
    private var rejectAttach = true
    private var policies: [AppliedBlockDevicePolicy?] = []

    func allowAttach() { rejectAttach = false }
    func receivedPolicies() -> [AppliedBlockDevicePolicy?] { policies }

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?,
        vsockCID: UInt32?
    ) async throws {}
    func bootVM(vmId: String) async throws {}
    func shutdownVM(vmId: String) async throws {}
    func rebootVM(vmId: String) async throws {}
    func pauseVM(vmId: String) async throws {}
    func resumeVM(vmId: String) async throws {}
    func deleteVM(vmId: String) async throws {}
    func reclaimVMDirectory(vmId: String) async {}
    func getVMStatus(vmId: String) async throws -> VMStatus { .running }
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? { nil }
    func reservationInventory() async -> HypervisorReservationInventory? { nil }
    func hasLiveSession(vmId: String) async -> Bool { true }

    func attachDisk(
        vmId: String, volumeId: String, attachment: DiskAttachment,
        deviceName: String, readonly: Bool,
        blockPolicy: AppliedBlockDevicePolicy?, orderedBootVolumeIds: [String],
        ioLimits: VolumeIOLimits?
    ) async throws {
        policies.append(blockPolicy)
        if rejectAttach {
            throw HypervisorServiceError.diskError("injected attach rejection")
        }
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {}
}

extension Agent {
    fileprivate func configureBlockPolicyTest(
        vmId: String, volumeId: UUID, backend: BlockPolicyTestStorage,
        hypervisor: BlockPolicyAttachHypervisor, desired: DesiredVolumeState,
        volumeSpec: VolumeSpec
    ) {
        storageBackend = backend
        storageBackends = StorageBackendRegistry(local: backend, makeCeph: { _ in backend })
        hypervisorServices[.qemu] = hypervisor
        managedVMs[vmId] = VMManifestEntry(
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 4, memoryBytes: 1 << 30,
                boot: .disk(firmware: nil)))
        desiredVolumeStates[volumeId.uuidString] = desired
        desiredVMVolumeSpecs[vmId] = [volumeSpec]
    }

    fileprivate func recordedBlockPolicy(vmId: String, volumeId: UUID)
        -> AppliedBlockDevicePolicy?
    {
        managedVMs[vmId]?.spec.volumes.first { $0.volumeId == volumeId }?
            .appliedBlockPolicy
    }

    fileprivate func shutDownBlockPolicyTestResources() async throws {
        try await eventLoopGroup.shutdownGracefully()
    }
}

@Suite("QEMU block policy lifecycle")
struct BlockPolicyLifecycleTests {
    @Test("hot attach publishes an active policy only after the hypervisor accepts it")
    func attachPolicyCommitsAfterSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-policy-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let vmId = UUID().uuidString
        let volumeId = UUID()
        let attachment = DiskAttachment.file(
            path: directory.appendingPathComponent("volume.qcow2").path,
            format: .qcow2)
        let desiredAttachment = DesiredVolumeAttachment(
            vmId: UUID(uuidString: vmId)!, deviceName: .disk(1))
        let desired = DesiredVolumeState(
            volumeId: volumeId, desiredStatus: .present, generation: 1,
            sizeBytes: 1 << 30, format: "qcow2", attachment: desiredAttachment,
            blockMode: .direct)
        let volumeSpec = VolumeSpec(
            volumeId: volumeId, deviceName: .disk(1), blockMode: .direct)
        let item = ReconcileWorkItem(
            kind: .volume, id: volumeId.uuidString, generation: 1,
            steps: [.attach], target: .volume(desired))
        let backend = BlockPolicyTestStorage(attachment: attachment)
        let hypervisor = BlockPolicyAttachHypervisor()
        let agent = Agent(
            agentID: "test-agent", webSocketURL: "ws://127.0.0.1/agent/ws",
            networkMode: nil, logger: Logger(label: "block-policy-attach-test"),
            vmStoragePath: directory.path,
            volumeStoragePath: directory.path)
        await agent.configureBlockPolicyTest(
            vmId: vmId, volumeId: volumeId, backend: backend,
            hypervisor: hypervisor, desired: desired, volumeSpec: volumeSpec)

        await #expect(throws: HypervisorServiceError.self) {
            try await agent.volumeReconcileAttach(item)
        }
        #expect(await agent.recordedBlockPolicy(vmId: vmId, volumeId: volumeId) == nil)
        #expect(await hypervisor.receivedPolicies().compactMap { $0 }.last?.active == true)

        await hypervisor.allowAttach()
        try await agent.volumeReconcileAttach(item)

        let applied = try #require(
            await agent.recordedBlockPolicy(vmId: vmId, volumeId: volumeId))
        #expect(applied.active)
        #expect(applied.cacheMode == BlockDeviceCacheMode.none)
        #expect(applied.ioMode == .ioUring)
        #expect(await hypervisor.receivedPolicies().count == 2)

        try await agent.shutDownBlockPolicyTestResources()
    }
}
