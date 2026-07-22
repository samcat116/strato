import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// A no-op hypervisor backend that behaves like a real driver without ever
/// touching a hypervisor. It serves two purposes:
///
/// 1. A build fallback when a real driver's native library is unavailable (for
///    example, SwiftQEMU cannot be compiled without its system dependencies).
/// 2. The backend behind the agent's simulation mode (`simulation_mode` in the
///    config), which lets a fleet of dummy agents be scale-tested against a
///    control plane without the compute to run real VMs.
///
/// It conforms to `HypervisorService` so the agent, tests, and every backend
/// share one code path.
///
/// Unlike a trivial stub, it tracks each VM's spec and status so it stays
/// faithful to the two behaviors the scheduler and reconciler depend on:
/// `reservedResources()` reports the real committed CPU/memory (so placement
/// actually depletes host capacity), and `getVMStatus()` reflects the last
/// lifecycle transition (so the reconciler converges instead of looping).
actor MockHypervisorService: HypervisorService {
    private let logger: Logger

    /// The hypervisor type this mock stands in for. Lets the mock report the
    /// same `hypervisorType` the real driver would, so routing is unaffected.
    public let hypervisorType: HypervisorType

    /// Optional artificial delays so a simulated fleet exhibits boot/shutdown
    /// latency the control plane's operation tracking has to wait out. Defaults
    /// mirror the historical mock values.
    private let bootDelay: Duration
    private let shutdownDelay: Duration

    /// VMs this mock is "managing", with the spec they were created from and
    /// their current lifecycle status. The spec drives reservation accounting;
    /// the status drives reconciliation convergence.
    private struct MockVM {
        var spec: VMSpec
        var status: VMStatus
    }
    private var vms: [String: MockVM] = [:]

    init(
        logger: Logger,
        hypervisorType: HypervisorType = .qemu,
        bootDelay: Duration = .milliseconds(500),
        shutdownDelay: Duration = .milliseconds(200)
    ) {
        self.logger = logger
        self.hypervisorType = hypervisorType
        self.bootDelay = bootDelay
        self.shutdownDelay = shutdownDelay
        logger.warning(
            "Hypervisor running in mock mode - no real VMs will be created",
            metadata: [
                "hypervisorType": .string(hypervisorType.rawValue)
            ])
    }

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?, networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        logger.info("Creating mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vms[vmId] = MockVM(spec: spec, status: .created)
    }

    func bootVM(vmId: String) async throws {
        logger.info("Booting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: bootDelay)  // Simulate boot delay
        vms[vmId]?.status = .running
    }

    func shutdownVM(vmId: String) async throws {
        logger.info("Shutting down mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: shutdownDelay)  // Simulate shutdown delay
        vms[vmId]?.status = .shutdown
    }

    func rebootVM(vmId: String) async throws {
        logger.info("Rebooting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: bootDelay)  // Simulate reboot delay
        vms[vmId]?.status = .running
    }

    func pauseVM(vmId: String) async throws {
        logger.info("Pausing mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vms[vmId]?.status = .paused
    }

    func resumeVM(vmId: String) async throws {
        logger.info("Resuming mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vms[vmId]?.status = .running
    }

    func deleteVM(vmId: String) async throws {
        logger.info("Deleting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vms.removeValue(forKey: vmId)
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        guard let vm = vms[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        return vm.status
    }

    func listVMs() async -> [String] {
        Array(vms.keys)
    }

    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        guard vms[vmId] != nil else { return nil }
        return ConsoleEndpoint(
            serialSocketPath: "/var/run/strato/vm-\(vmId)-serial.sock",
            consoleSocketPath: "/var/run/strato/vm-\(vmId)-console.sock"
        )
    }

    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws
    {
        logger.info(
            "Mock: attaching disk to VM (mock mode)",
            metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName),
            ])
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        logger.info(
            "Mock: detaching disk from VM (mock mode)",
            metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName),
            ])
    }

    /// Applies a sizing change to a tracked VM, so a simulated fleet's
    /// reported reservations follow resizes exactly as a real agent's do.
    func resizeVM(vmId: String, spec: VMSpec) async throws {
        guard var vm = vms[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        vm.spec = spec
        vms[vmId] = vm
        logger.info(
            "Mock: resized VM (mock mode)",
            metadata: [
                "vmId": .string(vmId),
                "cpus": .stringConvertible(spec.cpus),
                "memoryBytes": .stringConvertible(spec.memoryBytes),
            ])
    }

    /// Re-adopts a VM across an agent restart. Unlike real drivers there is no
    /// process to reattach — the mock simply resumes tracking the spec so the
    /// re-adopted VM keeps reserving capacity and reports as running. This lets
    /// a simulated agent restart converge exactly like a real one.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        logger.info("Re-adopting mock VM (mock mode)", metadata: ["vmId": .string(vmId)])
        vms[vmId] = MockVM(spec: spec, status: .running)
        return .running
    }

    /// Real committed CPU/memory across every tracked VM, so the agent reports
    /// depleting capacity to the scheduler as placements land — the whole point
    /// of simulation-mode scale testing.
    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64) {
        var vcpus = 0
        var memoryBytes: Int64 = 0
        for vm in vms.values {
            vcpus += vm.spec.cpus
            memoryBytes += vm.spec.memoryBytes
        }
        return (vcpus, memoryBytes)
    }
}
