import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftFirecracker

/// Service for managing Firecracker microVMs on Linux
/// Implements HypervisorService protocol for consistent VM lifecycle management
actor FirecrackerService: HypervisorService {
    private let logger: Logger
    private let storage: (any StorageBackend)?
    private let vmStoragePath: String
    private let firecrackerBinaryPath: String
    private let socketDirectory: String

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .firecracker

    // Track running VMs
    private var firecrackerClient: FirecrackerClient?
    private var vmManagers: [String: FirecrackerManager] = [:]
    private var vmSpecs: [String: VMSpec] = [:]

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        self.logger = logger
        self.storage = storage
        self.vmStoragePath = vmStoragePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory

        logger.info(
            "Firecracker service initialized",
            metadata: [
                "binaryPath": "\(firecrackerBinaryPath)",
                "socketDirectory": "\(socketDirectory)",
            ])
    }

    // MARK: - HypervisorService Protocol Implementation

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async throws {
        logger.info("Creating Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Validate Firecracker requirements
        guard case .directKernel(let kernelPath, let initramfsPath, let cmdline) = spec.boot else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker requires direct kernel boot - kernel path must be specified")
        }

        // Firecracker can only realize TAP attachments. Reject anything else up
        // front instead of silently launching the VM without its NICs.
        for nic in networkAttachments {
            guard case .tap = nic.attachment else {
                throw HypervisorServiceError.notSupported(
                    "Firecracker only supports tap network attachments; got \(nic.attachment) "
                        + "for network \(nic.network)")
            }
        }

        // Initialize client if needed
        if firecrackerClient == nil {
            firecrackerClient = FirecrackerClient(
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: socketDirectory,
                logger: logger
            )
        }

        guard let client = firecrackerClient else {
            throw HypervisorServiceError.hypervisorNotInstalled(firecrackerBinaryPath)
        }

        // Realize the root drive: materialize from the cached image when imageInfo
        // is provided, otherwise use the spec's first volume reference.
        var rootDrive: (id: String, path: String, readOnly: Bool)?
        if let imageInfo = imageInfo, let storage = storage {
            logger.info(
                "Materializing root drive from image",
                metadata: [
                    "vmId": .string(vmId),
                    "imageId": .string(imageInfo.imageId.uuidString),
                ])

            do {
                // Firecracker attaches drives as raw block devices. The storage
                // layer converts the image (e.g. a qcow2 cloud image) to raw
                // during materialization; a plain copy of a qcow2 file would
                // hand the guest an unbootable rootfs.
                let attachment = try await storage.materializeDisk(
                    at: "\(vmStoragePath)/\(vmId)/rootfs.raw",
                    from: imageInfo,
                    format: .raw
                )
                rootDrive = (id: "rootfs", path: attachment.path, readOnly: false)
            } catch {
                logger.error(
                    "Failed to materialize root drive from image",
                    metadata: [
                        "vmId": .string(vmId),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        if rootDrive == nil,
            let volume = spec.volumes.first,
            let storagePath = volume.storagePath
        {
            rootDrive = (id: volume.deviceName, path: storagePath, readOnly: volume.readonly)
        }

        // Create Firecracker VM
        let manager = try await client.createVM(vmId: vmId)

        // Configure machine
        let machineConfig = MachineConfig(
            vcpuCount: spec.cpus,
            memSizeMib: Int(spec.memoryBytes / (1024 * 1024))
        )
        try await manager.configureMachine(machineConfig)

        // Configure boot source (qualified: StratoShared also declares a BootSource)
        let bootSource = SwiftFirecracker.BootSource(
            kernelImagePath: kernelPath,
            initrdPath: initramfsPath,
            bootArgs: cmdline ?? "console=ttyS0 reboot=k panic=1 pci=off"
        )
        try await manager.configureBootSource(bootSource)

        // Configure root drive
        if let rootDrive {
            let drive = Drive.rootDrive(
                id: rootDrive.id,
                path: rootDrive.path,
                readOnly: rootDrive.readOnly
            )
            try await manager.configureDrive(drive)
        }

        // Configure networking: one interface per resolved attachment (validated
        // above to be .tap)
        for (index, nic) in networkAttachments.enumerated() {
            guard case .tap(let tapName) = nic.attachment else { continue }
            let networkInterface = NetworkInterface.tap(
                id: "eth\(index)",
                tapName: tapName,
                macAddress: nic.macAddress ?? ""
            )
            try await manager.configureNetwork(networkInterface)
        }

        // Store references
        vmManagers[vmId] = manager
        vmSpecs[vmId] = spec

        logger.info("Firecracker VM created successfully", metadata: ["vmId": .string(vmId)])
    }

    func bootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Booting Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.start()
        logger.info("Firecracker VM booted successfully", metadata: ["vmId": .string(vmId)])
    }

    func shutdownVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Shutting down Firecracker VM", metadata: ["vmId": .string(vmId)])
        // Firecracker doesn't have graceful shutdown, send Ctrl+Alt+Del or destroy
        try await manager.sendCtrlAltDel()
        logger.info("Shutdown signal sent to Firecracker VM", metadata: ["vmId": .string(vmId)])
    }

    func rebootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Rebooting Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.sendCtrlAltDel()
        logger.info("Reboot signal sent to Firecracker VM", metadata: ["vmId": .string(vmId)])
    }

    func pauseVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Pausing Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.pause()
        logger.info("Firecracker VM paused", metadata: ["vmId": .string(vmId)])
    }

    func resumeVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Resuming Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.resume()
        logger.info("Firecracker VM resumed", metadata: ["vmId": .string(vmId)])
    }

    func deleteVM(vmId: String) async throws {
        logger.info("Deleting Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Destroy the VM through the client (network attachments are torn down
        // by the agent's NetworkOrchestrator after this returns)
        if let client = firecrackerClient {
            try await client.destroyVM(vmId: vmId)
        }

        // Clean up local state
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)

        logger.info("Firecracker VM deleted", metadata: ["vmId": .string(vmId)])
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard let manager = vmManagers[vmId],
            let spec = vmSpecs[vmId]
        else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        let instanceInfo = try await manager.getInstanceInfo()

        return VmInfo(
            spec: spec,
            state: instanceInfo.state.rawValue,
            memoryActualSize: spec.memoryBytes
        )
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        // An absent entry means this service does not manage the VM at all; report
        // that honestly instead of fabricating `.shutdown` (see QEMUService).
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        let instanceInfo = try await manager.getInstanceInfo()

        switch instanceInfo.state {
        case .running:
            return .running
        case .paused:
            return .paused
        case .notStarted:
            return .created
        }
    }

    func listVMs() async -> [String] {
        return Array(vmManagers.keys)
    }

    /// Sum of vCPUs and memory (in bytes) reserved by all VMs this service is managing.
    /// Used to compute accurate available-resource figures for the scheduler.
    func reservedResources() -> (vcpus: Int, memoryBytes: Int64) {
        var vcpus = 0
        var memoryBytes: Int64 = 0
        for spec in vmSpecs.values {
            vcpus += spec.cpus
            memoryBytes += spec.memoryBytes
        }
        return (vcpus, memoryBytes)
    }

    /// Firecracker exposes the guest serial console on the firecracker process's
    /// stdio, not a Unix socket, so socket-based console access is not available yet.
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("console access for Firecracker VMs")
    }

    /// Firecracker does not support hot-plugging drives into a running microVM.
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws
    {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("disk hot-plug for Firecracker VMs")
    }

    /// Firecracker does not support hot-unplugging drives from a running microVM.
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("disk hot-unplug for Firecracker VMs")
    }

}

#else
// Stub implementation for non-Linux platforms
// Firecracker is only available on Linux

/// Stub FirecrackerService for non-Linux platforms
/// Always throws an error since Firecracker is Linux-only
actor FirecrackerService: HypervisorService {
    public let hypervisorType: HypervisorType = .firecracker

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        // No-op for non-Linux
    }

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func bootVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func shutdownVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func rebootVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func pauseVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func resumeVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func deleteVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func listVMs() async -> [String] {
        return []
    }

    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws
    {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func reservedResources() -> (vcpus: Int, memoryBytes: Int64) {
        return (0, 0)
    }
}
#endif
