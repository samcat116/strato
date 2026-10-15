#if os(macOS)
import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("Apple Virtualization runtime")
struct AppleVirtualizationRuntimeTests {
    @Test("A previous agent's VM cannot be falsely adopted")
    func adoptionAfterRestart() async throws {
        let service = await AppleVirtualizationService(
            logger: Logger(label: "apple-adoption"), vmStoragePath: FileManager.default.temporaryDirectory.path)
        do {
            _ = try await service.adoptVM(
                vmId: UUID().uuidString,
                spec: VMSpec(cpus: 1, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil)))
            Issue.record("adoption should report that the process is gone")
        } catch {
            #expect(OrphanDeleteAdoption.classify(adoptionFailure: error) == .processGone)
        }
        #expect(await service.bootstrapWorkloadIDs() == [])
    }

    @Test(
        "Native EFI VM starts, pauses, resumes, and stops",
        .enabled(
            if:
                ProcessInfo.processInfo.environment["STRATO_TEST_APPLE_VIRTUALIZATION"] == "1"))
    @MainActor
    func nativeLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["disk.raw"] {
            let path = root.appendingPathComponent(name).path
            #expect(FileManager.default.createFile(atPath: path, contents: nil))
            let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try file.truncate(atOffset: 64 * 1024 * 1024)
            try file.close()
        }
        let service = await AppleVirtualizationService(
            logger: Logger(label: "apple-native"), vmStoragePath: root.appendingPathComponent("vms").path)
        try #require(await service.support().available)
        let mac = "02:00:00:00:00:01"
        let spec = VMSpec(
            cpus: 1, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil),
            volumes: [
                VolumeSpec(
                    volumeId: UUID(), deviceName: .disk(0),
                    attachment: .file(path: root.appendingPathComponent("disk.raw").path, format: .raw))
            ],
            networks: [NetworkSpec(network: "nat", networkId: UUID(), macAddress: mac)])
        let attachments = [ResolvedNetworkAttachment(network: "nat", attachment: .userMode, macAddress: mac)]
        let id = UUID().uuidString
        try await service.createVM(
            vmId: id, spec: spec, imageInfo: nil, networkAttachments: attachments, metadata: nil, vsockCID: nil)
        #expect(try await service.getVMStatus(vmId: id) == .created)
        #expect(await service.hasLiveSession(vmId: id) == false)
        do {
            // Rebuilding before boot must retain the EFI store and realized disks.
            try await service.convergeGuestBootstrap(
                vmId: id, spec: spec, networkAttachments: attachments, metadata: nil)
            try await service.bootVM(vmId: id)
            #expect(try await service.getVMStatus(vmId: id) == .running)
            #expect(await service.hasLiveSession(vmId: id))
            try await service.pauseVM(vmId: id)
            #expect(try await service.getVMStatus(vmId: id) == .paused)
            try await service.resumeVM(vmId: id)
            #expect(try await service.getVMStatus(vmId: id) == .running)
            await #expect(throws: HypervisorServiceError.self) { try await service.resizeVM(vmId: id, spec: spec) }
        } catch {
            try await service.deleteVM(vmId: id)
            throw error
        }
        try await service.deleteVM(vmId: id)
        #expect(await service.bootstrapWorkloadIDs() == [])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("disk.raw").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("vms/\(id)").path))

    }
}
#endif
