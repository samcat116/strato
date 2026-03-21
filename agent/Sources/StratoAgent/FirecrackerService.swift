import Foundation
import Logging
import StratoShared

#if os(Linux)
import SwiftFirecracker

/// Service for managing Firecracker microVMs on Linux
/// Implements HypervisorService protocol for consistent VM lifecycle management
actor FirecrackerService: HypervisorService {
    private let logger: Logger
    private let networkService: (any NetworkServiceProtocol)?
    private let imageCacheService: ImageCacheService?
    private let vmStoragePath: String
    private let firecrackerBinaryPath: String
    private let socketDirectory: String

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .firecracker

    // Track running VMs
    private var firecrackerClient: FirecrackerClient?
    private var vmManagers: [String: FirecrackerManager] = [:]
    private var vmConfigs: [String: VmConfig] = [:]
    private var vmNetworkInfo: [String: VMNetworkInfo] = [:]

    init(
        logger: Logger,
        networkService: (any NetworkServiceProtocol)? = nil,
        imageCacheService: ImageCacheService? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        self.logger = logger
        self.networkService = networkService
        self.imageCacheService = imageCacheService
        self.vmStoragePath = vmStoragePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory

        logger.info("Firecracker service initialized", metadata: [
            "binaryPath": "\(firecrackerBinaryPath)",
            "socketDirectory": "\(socketDirectory)"
        ])
    }

    // MARK: - HypervisorService Protocol Implementation

    func createVM(vmId: String, config: VmConfig, imageInfo: ImageInfo? = nil) async throws {
        logger.info("Creating Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Validate Firecracker requirements
        guard config.payload.kernel != nil else {
            throw HypervisorServiceError.invalidConfiguration("Firecracker requires direct kernel boot - kernel path must be specified")
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

        // Handle disk image from cache if imageInfo is provided
        var effectiveConfig = config
        if let imageInfo = imageInfo, let cacheService = imageCacheService {
            logger.info("Using cached image for VM", metadata: [
                "vmId": .string(vmId),
                "imageId": .string(imageInfo.imageId.uuidString)
            ])

            do {
                let cachedImagePath = try await cacheService.getImagePath(imageInfo: imageInfo)

                // Create VM-specific disk
                let vmDiskPath = "\(vmStoragePath)/\(vmId)/rootfs.ext4"
                let vmDiskDir = (vmDiskPath as NSString).deletingLastPathComponent

                try FileManager.default.createDirectory(
                    atPath: vmDiskDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                if !FileManager.default.fileExists(atPath: vmDiskPath) {
                    try FileManager.default.copyItem(atPath: cachedImagePath, toPath: vmDiskPath)
                    logger.info("Created VM disk from cached image", metadata: [
                        "vmId": .string(vmId),
                        "diskPath": .string(vmDiskPath)
                    ])
                }

                // Update config with new disk path
                let newDisk = DiskConfig(path: vmDiskPath, readonly: false, direct: false, id: "rootfs")
                effectiveConfig = VmConfig(
                    cpus: config.cpus,
                    memory: config.memory,
                    payload: config.payload,
                    disks: [newDisk],
                    net: config.net,
                    rng: config.rng,
                    serial: config.serial,
                    console: config.console,
                    iommu: config.iommu,
                    watchdog: config.watchdog,
                    pvpanic: config.pvpanic
                )
            } catch {
                logger.error("Failed to get cached image", metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription)
                ])
            }
        }

        // Setup networking if configured
        if let networks = effectiveConfig.net, !networks.isEmpty {
            try await setupVMNetworking(vmId: vmId, networks: networks)
        }

        // Create Firecracker VM
        let manager = try await client.createVM(vmId: vmId)

        // Configure machine
        let vcpuCount = effectiveConfig.cpus?.bootVcpus ?? 1
        let memorySizeBytes: Int64 = effectiveConfig.memory?.size ?? (512 * 1024 * 1024)
        let memoryMB = Int(memorySizeBytes / (1024 * 1024))

        let machineConfig = MachineConfig(
            vcpuCount: Int(vcpuCount),
            memSizeMib: memoryMB
        )
        try await manager.configureMachine(machineConfig)

        // Configure boot source
        guard let kernelPath = effectiveConfig.payload.kernel else {
            throw HypervisorServiceError.invalidConfiguration("Kernel path is required for Firecracker")
        }

        let bootSource = BootSource(
            kernelImagePath: kernelPath,
            initrdPath: effectiveConfig.payload.initramfs,
            bootArgs: effectiveConfig.payload.cmdline ?? "console=ttyS0 reboot=k panic=1 pci=off"
        )
        try await manager.configureBootSource(bootSource)

        // Configure root drive
        if let disks = effectiveConfig.disks, let rootDisk = disks.first {
            let drive = Drive.rootDrive(
                id: rootDisk.id ?? "rootfs",
                path: rootDisk.path,
                readOnly: rootDisk.readonly ?? false
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
        vmConfigs[vmId] = effectiveConfig

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
        vmConfigs.removeValue(forKey: vmId)
        vmNetworkInfo.removeValue(forKey: vmId)

        logger.info("Firecracker VM deleted", metadata: ["vmId": .string(vmId)])
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard let manager = vmManagers[vmId],
              let config = vmConfigs[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        let instanceInfo = try await manager.getInstanceInfo()

        return VmInfo(
            config: config,
            state: instanceInfo.state.rawValue,
            memoryActualSize: config.memory?.size
        )
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        guard let manager = vmManagers[vmId] else {
            return .shutdown
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

    // MARK: - Private Methods

    private func setupVMNetworking(vmId: String, networks: [NetConfig]) async throws {
        guard let networkService = networkService else {
            logger.warning("Network service not available, skipping network setup")
            return
        }

        logger.info("Setting up VM networking", metadata: ["vmId": .string(vmId)])

        guard let firstNetwork = networks.first else {
            return
        }

        let networkConfig = VMNetworkConfig(
            networkName: firstNetwork.id ?? "default",
            macAddress: firstNetwork.mac,
            ipAddress: firstNetwork.ip,
            subnet: "192.168.1.0/24",
            gateway: "192.168.1.1"
        )

        let networkInfo = try await networkService.createVMNetwork(vmId: vmId, config: networkConfig)
        vmNetworkInfo[vmId] = networkInfo

        logger.info("VM networking setup completed", metadata: [
            "vmId": .string(vmId),
            "tapInterface": .string(networkInfo.tapInterface),
            "macAddress": .string(networkInfo.macAddress)
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
            logger.error("Failed to cleanup VM networking", metadata: [
                "vmId": .string(vmId),
                "error": .string(error.localizedDescription)
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
        imageCacheService: ImageCacheService? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        // No-op for non-Linux
    }

    func createVM(vmId: String, config: VmConfig, imageInfo: ImageInfo? = nil) async throws {
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
}
#endif
