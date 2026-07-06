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
    private let networkService: (any NetworkServiceProtocol)?
    private let storage: (any StorageBackend)?
    private let imageSource: (any ImageSource)?
    private let vmStoragePath: String
    private let firecrackerBinaryPath: String
    private let socketDirectory: String

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .firecracker

    // Track running VMs
    private var firecrackerClient: FirecrackerClient?
    private var vmManagers: [String: FirecrackerManager] = [:]
    private var vmSpecs: [String: VMSpec] = [:]
    private var vmNetworkInfo: [String: VMNetworkInfo] = [:]

    init(
        logger: Logger,
        networkService: (any NetworkServiceProtocol)? = nil,
        storage: (any StorageBackend)? = nil,
        imageSource: (any ImageSource)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        self.logger = logger
        self.networkService = networkService
        self.storage = storage
        self.imageSource = imageSource
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

    func createVM(vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil) async throws {
        logger.info("Creating Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Boot parameters start from the spec's direct-kernel fields (legacy
        // pre-provisioned host paths). When the image supplies kernel/rootfs
        // artifacts, they take precedence and are resolved to agent-local cache
        // paths below — the control plane can't know host paths.
        var kernelPath: String?
        var initramfsPath: String?
        var cmdline: String?
        if case .directKernel(let specKernel, let specInitramfs, let specCmdline) = spec.boot {
            kernelPath = specKernel.isEmpty ? nil : specKernel
            initramfsPath = specInitramfs
            cmdline = specCmdline
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

        // Realize kernel/rootfs from the image's artifact set when present.
        var rootDrive: (id: String, path: String, readOnly: Bool)?
        if let imageInfo = imageInfo, let storage = storage {
            logger.info(
                "Realizing boot artifacts from image",
                metadata: [
                    "vmId": .string(vmId),
                    "imageId": .string(imageInfo.imageId.uuidString),
                ])

            do {
                // Direct-kernel boot artifacts (kernel, optional initramfs) are
                // opaque blobs fetched into the cache as-is. When the image
                // supplies its own kernel it fully owns the direct-kernel boot:
                // drop any stale spec initramfs so the image kernel is never
                // paired with a legacy/nonexistent initrd, then use the image's
                // initramfs only if it provides one.
                if imageInfo.artifact(ofKind: .kernel) != nil, let imageSource = imageSource {
                    kernelPath = try await imageSource.localImagePath(for: imageInfo, kind: .kernel)
                    if imageInfo.artifact(ofKind: .initramfs) != nil {
                        initramfsPath = try await imageSource.localImagePath(for: imageInfo, kind: .initramfs)
                    } else {
                        initramfsPath = nil
                    }
                }

                // Firecracker attaches drives as raw block devices. The storage
                // layer converts the artifact (e.g. a qcow2 rootfs) to raw during
                // materialization; a plain copy of a qcow2 file would hand the
                // guest an unbootable rootfs. Prefer a dedicated rootfs artifact,
                // falling back to the primary disk image for legacy images.
                let rootfsKind: ArtifactKind = imageInfo.artifact(ofKind: .rootfs) != nil ? .rootfs : .diskImage
                let attachment = try await storage.materializeDisk(
                    at: "\(vmStoragePath)/\(vmId)/rootfs.raw",
                    from: imageInfo,
                    format: .raw,
                    artifactKind: rootfsKind
                )
                rootDrive = (id: "rootfs", path: attachment.path, readOnly: false)
            } catch {
                // Realizing the image's boot artifacts is all-or-nothing: a
                // fetched kernel without its matching rootfs would boot the guest
                // against the wrong or no root filesystem. Fail the create rather
                // than falling through to the legacy spec-volume path.
                logger.error(
                    "Failed to realize boot artifacts from image",
                    metadata: [
                        "vmId": .string(vmId),
                        "error": .string(error.localizedDescription),
                    ])
                throw error
            }
        }

        if rootDrive == nil,
            let volume = spec.volumes.first,
            let storagePath = volume.storagePath
        {
            rootDrive = (id: volume.deviceName, path: storagePath, readOnly: volume.readonly)
        }

        // Firecracker cannot boot without a kernel — from the image or the spec.
        guard let kernelPath = kernelPath, !kernelPath.isEmpty else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker requires direct kernel boot - no kernel artifact or kernel path available")
        }

        // Setup networking if configured
        if !spec.networks.isEmpty {
            try await setupVMNetworking(vmId: vmId, networks: spec.networks)
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

        // Configure network if available
        if let networkInfo = vmNetworkInfo[vmId], networkInfo.tapInterface != "n/a" {
            let networkInterface = NetworkInterface.tap(
                id: "eth0",
                tapName: networkInfo.tapInterface,
                macAddress: networkInfo.macAddress
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

        // Cleanup networking
        try await cleanupVMNetworking(vmId: vmId)

        // Destroy the VM through the client
        if let client = firecrackerClient {
            try await client.destroyVM(vmId: vmId)
        }

        // Clean up local state
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
        vmNetworkInfo.removeValue(forKey: vmId)

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

    // MARK: - Private Methods

    private func setupVMNetworking(vmId: String, networks: [NetworkSpec]) async throws {
        guard let networkService = networkService else {
            logger.warning("Network service not available, skipping network setup")
            return
        }

        logger.info("Setting up VM networking", metadata: ["vmId": .string(vmId)])

        guard let firstNetwork = networks.first else {
            return
        }

        let networkConfig = VMNetworkConfig(
            networkName: firstNetwork.network,
            macAddress: firstNetwork.macAddress,
            ipAddress: firstNetwork.ipAddress,
            subnet: "192.168.1.0/24",
            gateway: "192.168.1.1"
        )

        let networkInfo = try await networkService.createVMNetwork(vmId: vmId, config: networkConfig)
        vmNetworkInfo[vmId] = networkInfo

        logger.info(
            "VM networking setup completed",
            metadata: [
                "vmId": .string(vmId),
                "tapInterface": .string(networkInfo.tapInterface),
                "macAddress": .string(networkInfo.macAddress),
            ])
    }

    private func cleanupVMNetworking(vmId: String) async throws {
        guard let networkService = networkService else {
            logger.debug("Network service not available, skipping network cleanup")
            return
        }

        logger.info("Cleaning up VM networking", metadata: ["vmId": .string(vmId)])

        do {
            try await networkService.detachVMFromNetwork(vmId: vmId)
            vmNetworkInfo.removeValue(forKey: vmId)
            logger.info("VM networking cleanup completed", metadata: ["vmId": .string(vmId)])
        } catch {
            logger.error(
                "Failed to cleanup VM networking",
                metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
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
        networkService: (any NetworkServiceProtocol)? = nil,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        // No-op for non-Linux
    }

    func createVM(vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil) async throws {
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
