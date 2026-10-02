#if os(Linux)
import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("burstable backend refusal")
struct BurstableBackendRefusalTests {
    @Test("QEMU refuses before daemon access even when the root memory controller exists")
    func qemuRefusesPartialSupport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LibvirtService(
            logger: Logger(label: "burstable-refusal"), vmStoragePath: root.path,
            uri: "qemu+unix:///system?socket=/nonexistent-str272-libvirt", memoryControllerAvailable: true)
        let spec = try burstableSpec()
        let id = UUID().uuidString
        await #expect(throws: ConvergenceError.self) { try await service.createVM(vmId: id, spec: spec) }
        await #expect(throws: ConvergenceError.self) { try await service.ensureMemoryCeiling(vmId: id, spec: spec) }
        await #expect(throws: ConvergenceError.self) { _ = try await service.adoptVM(vmId: id, spec: spec) }
        await #expect(throws: ConvergenceError.self) { try await service.resizeVM(vmId: id, spec: spec) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("unjailed Firecracker refuses before boot artifact or disk preparation")
    func firecrackerRefusesUnownedBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = FirecrackerService(
            logger: Logger(label: "burstable-refusal"), vmStoragePath: root.path,
            firecrackerBinaryPath: "/nonexistent-str272-firecracker",
            socketDirectory: root.appendingPathComponent("sockets").path)
        let spec = try burstableSpec()
        let id = UUID().uuidString
        await #expect(throws: ConvergenceError.self) { try await service.createVM(vmId: id, spec: spec) }
        await #expect(throws: ConvergenceError.self) { _ = try await service.adoptVM(vmId: id, spec: spec) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func burstableSpec() throws -> VMSpec {
        VMSpec(
            cpus: 1, memoryBytes: 256 * 1024 * 1024,
            boot: .directKernel(kernel: "/nonexistent-kernel", initramfs: nil, cmdline: nil),
            resourceClass: try WorkloadResourceClassSnapshot(
                classID: WorkloadResourceClassSnapshot.burstableID, siteID: UUID(), revision: 1,
                policy: .burstable))
    }
}
#endif
