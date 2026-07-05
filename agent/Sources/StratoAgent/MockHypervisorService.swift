import Foundation
import Logging
import StratoShared

/// A no-op hypervisor backend used when a real driver's native library is not
/// available at build time (for example, SwiftQEMU cannot be compiled without
/// its system dependencies).
///
/// It conforms to `HypervisorService` so the agent, tests, and every backend
/// share one code path. Previously the mock behavior was interleaved through
/// `QEMUService` with `#if canImport(SwiftQEMU)` branches; pulling it into a
/// standalone service keeps the production drivers clean and gives each backend
/// the same test story.
actor MockHypervisorService: HypervisorService {
    private let logger: Logger

    /// The hypervisor type this mock stands in for. Lets the mock report the
    /// same `hypervisorType` the real driver would, so routing is unaffected.
    public let hypervisorType: HypervisorType

    /// VMs this mock is "managing". Tracked so status/info calls behave like a
    /// real backend: unknown IDs throw, known IDs report running.
    private var vmIds: Set<String> = []

    init(logger: Logger, hypervisorType: HypervisorType = .qemu) {
        self.logger = logger
        self.hypervisorType = hypervisorType
        logger.warning("Hypervisor running in mock mode - native backend unavailable", metadata: [
            "hypervisorType": .string(hypervisorType.rawValue)
        ])
    }

    func createVM(vmId: String, spec: VMSpec, imageInfo: ImageInfo?) async throws {
        logger.info("Creating mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vmIds.insert(vmId)
    }

    func bootVM(vmId: String) async throws {
        logger.info("Booting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(500)) // Simulate boot delay
    }

    func shutdownVM(vmId: String) async throws {
        logger.info("Shutting down mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(200)) // Simulate shutdown delay
    }

    func rebootVM(vmId: String) async throws {
        logger.info("Rebooting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(300)) // Simulate reboot delay
    }

    func pauseVM(vmId: String) async throws {
        logger.info("Pausing mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
    }

    func resumeVM(vmId: String) async throws {
        logger.info("Resuming mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
    }

    func deleteVM(vmId: String) async throws {
        logger.info("Deleting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vmIds.remove(vmId)
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard vmIds.contains(vmId) else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        let mockSpec = VMSpec(
            cpus: 2,
            maxCpus: 4,
            memoryBytes: 2 * 1024 * 1024 * 1024, // 2GB
            boot: .directKernel(kernel: "/boot/vmlinuz", initramfs: nil, cmdline: nil)
        )
        return VmInfo(
            spec: mockSpec,
            state: "running",
            memoryActualSize: mockSpec.memoryBytes
        )
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        guard vmIds.contains(vmId) else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        return .running
    }

    func listVMs() async -> [String] {
        Array(vmIds)
    }

    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        guard vmIds.contains(vmId) else { return nil }
        return ConsoleEndpoint(
            serialSocketPath: "/var/run/strato/vm-\(vmId)-serial.sock",
            consoleSocketPath: "/var/run/strato/vm-\(vmId)-console.sock"
        )
    }

    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws {
        logger.info("Mock: attaching disk to VM (mock mode)", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName)
        ])
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        logger.info("Mock: detaching disk from VM (mock mode)", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName)
        ])
    }

    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64) {
        (0, 0)
    }
}
