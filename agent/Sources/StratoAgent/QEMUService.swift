import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if canImport(SwiftQEMU)
import SwiftQEMU
#endif

actor QEMUService: HypervisorService {
    private let logger: Logger
    private let networkService: (any NetworkServiceProtocol)?
    private let imageCacheService: ImageCacheService?
    private let vmStoragePath: String
    private let qemuBinaryPath: String
    private let configuredFirmwarePath: String?

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .qemu

    #if canImport(SwiftQEMU)
    private var activeVMs: [String: QEMUManager] = [:]
    private var vmConfigs: [String: VmConfig] = [:]
    private var vmNetworkInfo: [String: VMNetworkInfo] = [:]
    private var vmConsoleSocketPaths: [String: String] = [:]
    private var vmSerialSocketPaths: [String: String] = [:]
    private var pendingVMs: Set<String> = []  // Track VMs being created (to handle concurrent boot requests)
    #else
    // Mock mode when SwiftQEMU is not available
    private var mockVMs: [String: MockQEMUVM] = [:]
    private var pendingVMs: Set<String> = []  // Track VMs being created (to handle concurrent boot requests)
    #endif

    init(logger: Logger, networkService: (any NetworkServiceProtocol)? = nil, imageCacheService: ImageCacheService? = nil, vmStoragePath: String, qemuBinaryPath: String, firmwarePath: String? = nil) {
        self.logger = logger
        self.networkService = networkService
        self.imageCacheService = imageCacheService
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.configuredFirmwarePath = firmwarePath

        #if canImport(SwiftQEMU)
        #if os(Linux)
        logger.info("QEMU service initialized with KVM acceleration support")
        #elseif os(macOS)
        logger.info("QEMU service initialized with Hypervisor.framework (HVF) acceleration support")
        #else
        logger.info("QEMU service initialized with SwiftQEMU support")
        #endif
        #else
        logger.warning("QEMU service running in mock mode - SwiftQEMU not available")
        #endif
    }
    
    // MARK: - VM Lifecycle Operations

    /// Creates a VM with optional image info for disk caching
    func createVM(vmId: String, config: VmConfig, imageInfo: ImageInfo? = nil) async throws {
        // Mark VM as pending to handle concurrent boot requests
        pendingVMs.insert(vmId)
        defer { pendingVMs.remove(vmId) }

        #if canImport(SwiftQEMU)
        logger.info("Creating QEMU VM", metadata: ["vmId": .string(vmId)])

        // If imageInfo is provided, use cached image
        var effectiveConfig = config
        if let imageInfo = imageInfo, let cacheService = imageCacheService {
            logger.info("Using cached image for VM", metadata: [
                "vmId": .string(vmId),
                "imageId": .string(imageInfo.imageId.uuidString)
            ])

            do {
                let cachedImagePath = try await cacheService.getImagePath(imageInfo: imageInfo)
                logger.info("Image ready at cache path", metadata: [
                    "vmId": .string(vmId),
                    "cachedPath": .string(cachedImagePath)
                ])

                // Create a copy for this VM
                let vmDiskPath = "\(vmStoragePath)/\(vmId)/disk.qcow2"
                let vmDiskDir = (vmDiskPath as NSString).deletingLastPathComponent

                try FileManager.default.createDirectory(
                    atPath: vmDiskDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )

                // Copy the cached image to VM-specific location
                if !FileManager.default.fileExists(atPath: vmDiskPath) {
                    try FileManager.default.copyItem(atPath: cachedImagePath, toPath: vmDiskPath)
                    logger.info("Created VM disk from cached image", metadata: [
                        "vmId": .string(vmId),
                        "diskPath": .string(vmDiskPath)
                    ])
                }

                // Update config with the new disk path
                let newDisk = DiskConfig(
                    path: vmDiskPath,
                    readonly: false,
                    direct: false,
                    id: "disk0"
                )
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
                logger.error("Failed to get cached image, falling back to original config", metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription)
                ])
                // Continue with original config
            }
        }

        // Create disk images from base if they don't exist (only if not using cached image)
        if let disks = effectiveConfig.disks {
            for disk in disks {
                let diskPath = disk.path
                let fileManager = FileManager.default

                if !fileManager.fileExists(atPath: diskPath) {
                    logger.info("Disk image does not exist, creating from base", metadata: [
                        "diskPath": .string(diskPath),
                        "vmId": .string(vmId)
                    ])

                    // Determine base disk path from the disk path
                    // Disk path format: /images/<template>/UUID.qcow2
                    // Base disk: /images/<template>/disk.qcow2
                    let diskURL = URL(fileURLWithPath: diskPath)
                    let templateDir = diskURL.deletingLastPathComponent().path
                    let baseDiskPath = "\(templateDir)/disk.qcow2"

                    if fileManager.fileExists(atPath: baseDiskPath) {
                        do {
                            try fileManager.copyItem(atPath: baseDiskPath, toPath: diskPath)
                            logger.info("Disk image created successfully", metadata: [
                                "from": .string(baseDiskPath),
                                "to": .string(diskPath)
                            ])
                        } catch {
                            logger.error("Failed to create disk image: \(error)", metadata: [
                                "from": .string(baseDiskPath),
                                "to": .string(diskPath)
                            ])
                            throw QEMUServiceError.diskCreationFailed("Failed to copy base disk: \(error.localizedDescription)")
                        }
                    } else {
                        logger.error("Base disk not found", metadata: ["baseDiskPath": .string(baseDiskPath)])
                        throw QEMUServiceError.diskCreationFailed("Base disk not found at \(baseDiskPath)")
                    }
                } else {
                    logger.debug("Disk image already exists", metadata: ["diskPath": .string(diskPath)])
                }
            }
        }

        let qemuManager = QEMUManager(qemuPath: qemuBinaryPath, logger: logger)

        // Set up VM networking first
        if let networks = effectiveConfig.net, !networks.isEmpty {
            try await setupVMNetworking(vmId: vmId, networks: networks)
        }

        // Configure and create VM
        let qemuConfig = convertToQEMUConfiguration(effectiveConfig, vmId: vmId)

        // Create VM with timeout - QMP connection can hang indefinitely
        logger.info("Starting QEMU VM creation with 30 second timeout", metadata: ["vmId": .string(vmId)])
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await qemuManager.createVM(config: qemuConfig)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                    throw QEMUServiceError.configurationError("QEMU VM creation timed out after 30 seconds - QMP connection may have failed")
                }

                // Wait for the first task to complete (either success or timeout)
                try await group.next()
                group.cancelAll()
            }
        } catch {
            logger.error("QEMU VM creation failed", metadata: [
                "vmId": .string(vmId),
                "error": .string(error.localizedDescription)
            ])
            // Clean up the QEMU process if it's still running
            try? await qemuManager.destroy()
            throw error
        }

        activeVMs[vmId] = qemuManager
        vmConfigs[vmId] = effectiveConfig

        logger.info("QEMU VM created successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Creating mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        mockVMs[vmId] = MockQEMUVM(id: vmId)
        #endif
    }
    
    func bootVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        // Wait for VM to be ready - it may still be creating (downloading image, etc.)
        var retries = 0
        let maxRetries = 120  // 60 seconds total (120 * 0.5s) - creation can take a while
        var vm: QEMUManager?

        while retries < maxRetries {
            // Check if VM is ready
            if let foundVM = activeVMs[vmId] {
                vm = foundVM
                break
            }

            // If VM is being created, wait for it
            if pendingVMs.contains(vmId) {
                logger.debug("VM is being created, waiting...", metadata: ["vmId": .string(vmId), "retry": .stringConvertible(retries)])
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                retries += 1
                continue
            }

            // VM not found and not pending - fail fast
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found and not being created")
        }

        guard let vm = vm else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) creation timed out after \(maxRetries / 2) seconds")
        }

        logger.info("Booting QEMU VM", metadata: ["vmId": .string(vmId)])

        // Start VM execution
        try await vm.start()

        logger.info("QEMU VM booted successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Booting mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(500)) // Simulate boot delay
        #endif
    }
    
    func shutdownVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Shutting down QEMU VM", metadata: ["vmId": .string(vmId)])

        // Graceful shutdown
        try await vm.shutdown()

        logger.info("QEMU VM shutdown completed", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Shutting down mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(200)) // Simulate shutdown delay
        #endif
    }

    func rebootVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Rebooting QEMU VM", metadata: ["vmId": .string(vmId)])

        // System reset
        try await vm.reset()

        logger.info("QEMU VM reboot initiated", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Rebooting mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        try await Task.sleep(for: .milliseconds(300)) // Simulate reboot delay
        #endif
    }

    func pauseVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Pausing QEMU VM", metadata: ["vmId": .string(vmId)])

        // Pause VM
        try await vm.pause()

        logger.info("QEMU VM paused", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Pausing mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        #endif
    }

    func resumeVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Resuming QEMU VM", metadata: ["vmId": .string(vmId)])

        // Resume VM
        try await vm.start()

        logger.info("QEMU VM resumed", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Resuming mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        #endif
    }

    func deleteVM(vmId: String) async throws {
        #if canImport(SwiftQEMU)
        guard let qemuManager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Deleting QEMU VM", metadata: ["vmId": .string(vmId)])

        // Destroy VM
        try await qemuManager.destroy()

        // Clean up VM networking
        try await cleanupVMNetworking(vmId: vmId)

        // Clean up VM resources
        activeVMs.removeValue(forKey: vmId)
        vmConfigs.removeValue(forKey: vmId)
        vmNetworkInfo.removeValue(forKey: vmId)

        // Clean up console socket
        if let socketPath = vmConsoleSocketPaths.removeValue(forKey: vmId) {
            try? FileManager.default.removeItem(atPath: socketPath)
            logger.debug("Removed console socket: \(socketPath)")
        }

        // Clean up serial socket
        if let socketPath = vmSerialSocketPaths.removeValue(forKey: vmId) {
            try? FileManager.default.removeItem(atPath: socketPath)
            logger.debug("Removed serial socket: \(socketPath)")
        }

        logger.info("QEMU VM deleted", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Deleting mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        mockVMs.removeValue(forKey: vmId)
        #endif
    }
    
    // MARK: - VM Information

    func getVMInfo(vmId: String) async throws -> VmInfo {
        #if canImport(SwiftQEMU)
        guard let qemuManager = activeVMs[vmId],
              let config = vmConfigs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        // Query VM status
        let status = try await qemuManager.getStatus()

        return VmInfo(
            config: config,
            state: status.rawValue,
            memoryActualSize: config.memory?.size
        )
        #else
        // Mock mode - return mock info
        guard mockVMs[vmId] != nil else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }
        let mockConfig = VmConfig(
            cpus: CpusConfig(bootVcpus: 2, maxVcpus: 4),
            memory: MemoryConfig(size: 2 * 1024 * 1024 * 1024), // 2GB
            payload: PayloadConfig(kernel: "/boot/vmlinuz")
        )

        return VmInfo(
            config: mockConfig,
            state: "running",
            memoryActualSize: mockConfig.memory?.size
        )
        #endif
    }

    /// Returns the console socket path for a VM
    /// The path is computed deterministically from vmStoragePath and vmId
    /// Returns nil if the socket file doesn't exist (VM not running or not created)
    func getConsoleSocketPath(vmId: String) -> String? {
        #if canImport(SwiftQEMU)
        // First check in-memory cache for VMs created this session
        if let cachedPath = vmConsoleSocketPaths[vmId] {
            // Verify socket file exists
            if FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
        }

        // Compute the expected path deterministically
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let consoleSocketPath = (vmDir as NSString).appendingPathComponent("console.sock")

        // Check if the socket file exists (VM is running with console enabled)
        if FileManager.default.fileExists(atPath: consoleSocketPath) {
            logger.debug("Found console socket at computed path: \(consoleSocketPath)")
            return consoleSocketPath
        }

        logger.debug("Console socket not found at: \(consoleSocketPath)")
        return nil
        #else
        // Mock mode - return a mock path
        return mockVMs[vmId] != nil ? "/var/run/strato/vm-\(vmId)-console.sock" : nil
        #endif
    }

    /// Returns the serial console socket path for a VM
    /// The path is computed deterministically from vmStoragePath and vmId
    /// Returns nil if the socket file doesn't exist (VM not running or not created)
    func getSerialSocketPath(vmId: String) -> String? {
        #if canImport(SwiftQEMU)
        // First check in-memory cache for VMs created this session
        if let cachedPath = vmSerialSocketPaths[vmId] {
            // Verify socket file exists
            if FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
        }

        // Compute the expected path deterministically
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let serialSocketPath = (vmDir as NSString).appendingPathComponent("serial.sock")

        // Check if the socket file exists (VM is running with serial enabled)
        if FileManager.default.fileExists(atPath: serialSocketPath) {
            logger.debug("Found serial socket at computed path: \(serialSocketPath)")
            return serialSocketPath
        }

        logger.debug("Serial socket not found at: \(serialSocketPath)")
        return nil
        #else
        // Mock mode - return a mock path
        return mockVMs[vmId] != nil ? "/var/run/strato/vm-\(vmId)-serial.sock" : nil
        #endif
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        #if canImport(SwiftQEMU)
        guard let qemuManager = activeVMs[vmId] else {
            return .shutdown
        }

        do {
            let status = try await qemuManager.getStatus()

            // Map SwiftQEMU QEMUVMStatus to StratoShared VMStatus
            switch status {
            case .running:
                return .running
            case .paused:
                return .paused
            case .stopped, .shuttingDown:
                return .shutdown
            case .creating:
                return .created
            case .unknown:
                return .created
            }
        } catch {
            logger.error("Failed to query VM status: \(error)")
            return .shutdown
        }
        #else
        // Mock mode - return mock status
        return mockVMs[vmId] != nil ? .running : .shutdown
        #endif
    }

    func listVMs() async -> [String] {
        #if canImport(SwiftQEMU)
        return Array(activeVMs.keys)
        #else
        return Array(mockVMs.keys)
        #endif
    }

    // MARK: - Legacy Methods (for backward compatibility)

    /// Syncs VM status for the first VM (legacy method)
    func syncVMStatus() async throws -> VMStatus {
        #if canImport(SwiftQEMU)
        guard let vmId = activeVMs.keys.first else {
            return .shutdown
        }
        return try await getVMStatus(vmId: vmId)
        #else
        guard let vmId = mockVMs.keys.first else {
            return .shutdown
        }
        return try await getVMStatus(vmId: vmId)
        #endif
    }

    /// Gets VM info for the first VM (legacy method)
    func getVMInfo() async throws -> VmInfo {
        #if canImport(SwiftQEMU)
        guard let vmId = activeVMs.keys.first else {
            throw QEMUServiceError.vmNotFound("No VM available for info")
        }
        return try await getVMInfo(vmId: vmId)
        #else
        guard let vmId = mockVMs.keys.first else {
            throw QEMUServiceError.vmNotFound("No VM available for info")
        }
        return try await getVMInfo(vmId: vmId)
        #endif
    }

    // MARK: - VM Management Helpers

    func createAndStartVM(vmId: String, config: VmConfig) async throws {
        try await createVM(vmId: vmId, config: config)
        try await bootVM(vmId: vmId)
    }

    func stopAndDeleteVM(vmId: String) async throws {
        do {
            try await shutdownVM(vmId: vmId)
            // Wait a moment for graceful shutdown
            try await Task.sleep(for: .seconds(2))
        } catch {
            logger.warning("VM shutdown failed, forcing delete: \(error)")
        }

        try await deleteVM(vmId: vmId)
    }

    // MARK: - Disk Hot-Plug Operations (Volume Support)

    /// Attaches a disk to a running VM using QMP hot-plug
    /// This uses QEMU's blockdev-add and device_add commands via SwiftQEMU
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool = false) async throws {
        #if canImport(SwiftQEMU)
        guard let manager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Attaching disk to VM via QMP hot-plug", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName),
            "volumePath": .string(volumePath),
            "readonly": .stringConvertible(readonly)
        ])

        do {
            try await manager.attachDisk(path: volumePath, deviceName: deviceName, readOnly: readonly)
            logger.info("Disk attached successfully", metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName)
            ])
        } catch {
            logger.error("Failed to attach disk via QMP hot-plug", metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "error": .string(String(describing: error))
            ])
            throw QEMUServiceError.hotPlugFailed("Failed to attach disk: \(error)")
        }
        #else
        logger.info("Mock: Attaching disk to VM (mock mode)", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName)
        ])
        #endif
    }

    /// Detaches a disk from a running VM using QMP hot-unplug
    /// This uses QEMU's device_del and blockdev-del commands via SwiftQEMU
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        #if canImport(SwiftQEMU)
        guard let manager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Detaching disk from VM via QMP hot-unplug", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName)
        ])

        do {
            try await manager.detachDisk(deviceName: deviceName)
            logger.info("Disk detached successfully", metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName)
            ])
        } catch {
            logger.error("Failed to detach disk via QMP hot-unplug", metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "error": .string(String(describing: error))
            ])
            throw QEMUServiceError.hotPlugFailed("Failed to detach disk: \(error)")
        }
        #else
        logger.info("Mock: Detaching disk from VM (mock mode)", metadata: [
            "vmId": .string(vmId),
            "volumeId": .string(volumeId),
            "deviceName": .string(deviceName)
        ])
        #endif
    }

    // MARK: - Private Configuration Methods

    #if canImport(SwiftQEMU)
    /// Resolves the UEFI firmware path for the current architecture
    /// Priority: 1) Explicit per-VM firmware path, 2) Agent config file path, 3) Platform default
    /// Returns nil if no firmware is found
    private func resolveFirmwarePath(_ explicitPath: String?) -> String? {
        // 1. If explicit per-VM path provided, validate and return it
        if let path = explicitPath, !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                logger.debug("Using explicit per-VM firmware path: \(path)")
                return path
            }
            logger.warning("Specified per-VM firmware path does not exist: \(path), trying config file setting")
        }

        // 2. Check agent config file setting
        if let path = configuredFirmwarePath, !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                logger.debug("Using firmware path from config file: \(path)")
                return path
            }
            logger.warning("Config file firmware path does not exist: \(path), trying platform defaults")
        }

        // 3. Use architecture-specific platform default
        #if arch(arm64)
        let defaultPath = AgentConfig.defaultFirmwarePathARM64
        #else
        let defaultPath = AgentConfig.defaultFirmwarePathX86_64
        #endif

        guard let path = defaultPath else {
            logger.warning("No UEFI firmware found for this platform/architecture")
            return nil
        }

        logger.debug("Using platform default firmware path: \(path)")
        return path
    }

    private func convertToQEMUConfiguration(_ config: VmConfig, vmId: String) -> QEMUConfiguration {
        var qemuConfig = QEMUConfiguration()

        // Determine boot mode: direct kernel boot or UEFI firmware boot
        let payload = config.payload
        let hasKernelBoot = payload.kernel != nil && !payload.kernel!.isEmpty

        // Configure machine type based on architecture and boot mode
        #if arch(arm64)
        // For ARM64 UEFI boot, we need gic-version=3 for EDK2 firmware compatibility
        qemuConfig.machineType = hasKernelBoot ? "virt" : "virt,gic-version=3"
        qemuConfig.cpuType = "host"
        logger.debug("Configuring ARM64 machine type: \(qemuConfig.machineType)")
        #else
        qemuConfig.machineType = "q35"
        qemuConfig.cpuType = "host"
        logger.debug("Configuring x86_64 machine type: q35")
        #endif

        // Configure CPU
        if let cpuConfig = config.cpus {
            qemuConfig.cpuCount = Int(cpuConfig.bootVcpus)
            logger.debug("Configuring CPU: \(cpuConfig.bootVcpus) cores")
        }

        // Configure Memory (convert bytes to MB)
        if let memoryConfig = config.memory {
            qemuConfig.memoryMB = Int(memoryConfig.size / (1024 * 1024))
            logger.debug("Configuring memory: \(memoryConfig.size) bytes (\(qemuConfig.memoryMB) MB)")
        }

        // Configure disks
        if let disks = config.disks {
            qemuConfig.disks = disks.map { disk in
                QEMUDisk(
                    path: disk.path,
                    format: "qcow2",
                    interface: "virtio",
                    readonly: disk.readonly ?? false
                )
            }
        }

        // Configure networking
        if let networks = config.net {
            qemuConfig.networks = networks.compactMap { network in
                // Get network info for this VM if available
                if let networkInfo = vmNetworkInfo[vmId] {
                    // Check if we have a real TAP interface or using user-mode
                    if networkInfo.tapInterface != "n/a" {
                        // Use TAP interface for OVN integration
                        return QEMUNetwork(
                            backend: "tap",
                            model: "virtio-net-pci",
                            macAddress: networkInfo.macAddress,
                            options: "ifname=\(networkInfo.tapInterface),script=no,downscript=no"
                        )
                    } else {
                        // Use user-mode networking
                        return QEMUNetwork(
                            backend: "user",
                            model: "virtio-net-pci",
                            macAddress: networkInfo.macAddress
                        )
                    }
                } else {
                    // Fallback to user networking
                    return QEMUNetwork(
                        backend: "user",
                        model: "virtio-net-pci",
                        macAddress: network.mac
                    )
                }
            }
        }

        // Configure boot mode: direct kernel boot or UEFI firmware boot
        if hasKernelBoot {
            // Direct kernel boot
            qemuConfig.kernel = payload.kernel
            qemuConfig.initrd = payload.initramfs
            // Ensure serial console is in kernel args
            var cmdline = payload.cmdline ?? ""
            let consoleArgs = [
                "console=tty0",
                "console=ttyS0,115200",
                "console=ttyAMA0,115200",
                "console=hvc0"
            ]
            if cmdline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cmdline = consoleArgs.joined(separator: " ")
            } else {
                for arg in consoleArgs {
                    if !cmdline.contains(arg) {
                        cmdline.append(" \(arg)")
                    }
                }
            }
            qemuConfig.kernelArgs = cmdline
            logger.info("Direct kernel boot configured", metadata: [
                "kernel": .string(payload.kernel!),
                "cmdline": .string(cmdline)
            ])
        } else {
            // UEFI firmware boot (disk-based)
            // Resolve firmware path: explicit config > platform default
            if let firmwarePath = resolveFirmwarePath(payload.firmware) {
                qemuConfig.additionalArgs.append(contentsOf: ["-bios", firmwarePath])
                logger.info("UEFI firmware boot configured", metadata: [
                    "firmware": .string(firmwarePath),
                    "vmId": .string(vmId)
                ])
            } else {
                // No firmware found - VM may fail to boot without UEFI firmware on ARM64
                logger.warning("No UEFI firmware configured - VM may fail to boot on ARM64", metadata: [
                    "vmId": .string(vmId)
                ])
            }
        }

        // Enable hardware acceleration based on platform
        #if os(Linux)
        // Enable KVM on Linux
        qemuConfig.enableKVM = true
        logger.debug("Enabling KVM acceleration")
        #elseif os(macOS)
        // Disable KVM (not available on macOS) and enable Hypervisor.framework (HVF)
        qemuConfig.enableKVM = false
        qemuConfig.additionalArgs.append(contentsOf: ["-accel", "hvf"])
        logger.debug("Enabling Hypervisor.framework (HVF) acceleration")
        #endif

        qemuConfig.noGraphic = true
        // Start VM immediately to avoid QMP resume dependency during boot
        qemuConfig.startPaused = false

        // Configure virtio-console for VM console streaming
        // Use the VM's storage directory for the socket (user-writable)
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let consoleSocketPath = (vmDir as NSString).appendingPathComponent("console.sock")

        // Create VM directory if it doesn't exist (should already exist from disk creation)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: vmDir) {
            do {
                try fileManager.createDirectory(atPath: vmDir, withIntermediateDirectories: true, attributes: nil)
                logger.debug("Created VM directory for console socket: \(vmDir)")
            } catch {
                logger.warning("Failed to create VM directory for console socket: \(error)")
            }
        }

        // Add virtio-serial device and virtconsole
        qemuConfig.additionalArgs.append(contentsOf: [
            "-device", "virtio-serial-pci,id=virtio-serial0",
            "-chardev", "socket,id=console0,path=\(consoleSocketPath),server=on,wait=off",
            "-device", "virtconsole,chardev=console0,id=virtconsole0"
        ])

        // Store the socket path for later access
        vmConsoleSocketPaths[vmId] = consoleSocketPath
        logger.debug("Configured virtio-console socket at: \(consoleSocketPath)")

        // For disk-based boot, create cloud-init ISO to configure serial console
        // Cloud-init allows configuring the guest without modifying the disk image
        let cloudInitISOPath = (vmDir as NSString).appendingPathComponent("cloud-init.iso")
        if createCloudInitISO(at: cloudInitISOPath, vmId: vmId) {
            qemuConfig.additionalArgs.append(contentsOf: [
                "-drive", "file=\(cloudInitISOPath),format=raw,if=virtio,readonly=on"
            ])
            logger.info("Cloud-init ISO attached for serial console configuration")
        }

        // Configure serial console socket (most Linux distros output to ttyS0 by default)
        let serialSocketPath = (vmDir as NSString).appendingPathComponent("serial.sock")
        qemuConfig.additionalArgs.append(contentsOf: [
            "-serial", "unix:\(serialSocketPath),server,nowait"
        ])
        vmSerialSocketPaths[vmId] = serialSocketPath
        logger.debug("Configured serial console socket at: \(serialSocketPath)")

        return qemuConfig
    }
    
    // MARK: - VM Network Management
    
    private func setupVMNetworking(vmId: String, networks: [NetConfig]) async throws {
        guard let networkService = networkService else {
            logger.warning("Network service not available, skipping network setup")
            return
        }
        
        logger.info("Setting up VM networking", metadata: ["vmId": .string(vmId)])
        
        // For now, handle only the first network configuration
        // In production, this could be expanded to handle multiple networks
        guard let firstNetwork = networks.first else {
            return
        }
        
        // Create network configuration from NetConfig
        let networkConfig = VMNetworkConfig(
            networkName: firstNetwork.id ?? "default",
            macAddress: firstNetwork.mac,
            ipAddress: firstNetwork.ip,
            subnet: "192.168.1.0/24", // Default subnet - should be configurable
            gateway: "192.168.1.1"
        )
        
        // Create VM network through NetworkService
        let networkInfo = try await networkService.createVMNetwork(vmId: vmId, config: networkConfig)
        vmNetworkInfo[vmId] = networkInfo
        
        logger.info("VM networking setup completed", metadata: [
            "vmId": .string(vmId),
            "networkName": .string(networkInfo.networkName),
            "macAddress": .string(networkInfo.macAddress),
            "ipAddress": .string(networkInfo.ipAddress)
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
            logger.info("VM networking cleanup completed", metadata: ["vmId": .string(vmId)])
        } catch {
            logger.error("Failed to cleanup VM networking", metadata: [
                "vmId": .string(vmId),
                "error": .string(error.localizedDescription)
            ])
            // Don't throw here to avoid blocking VM deletion
        }
    }

    /// Creates a cloud-init NoCloud ISO for configuring the guest VM
    /// This enables serial console output by configuring GRUB and systemd
    private func createCloudInitISO(at isoPath: String, vmId: String) -> Bool {
        let fileManager = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("cloud-init-\(vmId)")

        // Clean up any existing temp directory
        try? fileManager.removeItem(atPath: tempDir)

        do {
            // Create temp directory structure
            try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true, attributes: nil)

            // Create meta-data file (required for NoCloud)
            let metaData = """
            instance-id: \(vmId)
            local-hostname: vm-\(vmId.prefix(8))
            """
            let metaDataPath = (tempDir as NSString).appendingPathComponent("meta-data")
            try metaData.write(toFile: metaDataPath, atomically: true, encoding: .utf8)

            // Create user-data file with serial console configuration
            let userData = """
            #cloud-config
            # Enable serial console output
            bootcmd:
              # Update GRUB to output to serial console
              - 'sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\\"console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0\\"/" /etc/default/grub || true'
              - 'update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true'

            # Enable getty on serial console
            runcmd:
              - systemctl enable --now serial-getty@ttyS0.service || true
              - systemctl enable --now serial-getty@ttyAMA0.service || true
              - systemctl enable --now serial-getty@hvc0.service || true
              # Emit a marker so we can verify console output quickly
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyS0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyAMA0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/hvc0 2>/dev/null || true'"

            # Set password for ubuntu/root user for console login (development only)
            chpasswd:
              expire: false
              users:
                - name: ubuntu
                  password: ubuntu
                  type: text

            # Ensure SSH is available
            ssh_pwauth: true
            """
            let userDataPath = (tempDir as NSString).appendingPathComponent("user-data")
            try userData.write(toFile: userDataPath, atomically: true, encoding: .utf8)

            // Create ISO using hdiutil (macOS) or genisoimage/mkisofs (Linux)
            let process = Process()
            #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = [
                "makehybrid",
                "-iso",
                "-joliet",
                "-o", isoPath,
                "-default-volume-name", "cidata",
                tempDir
            ]
            #else
            // Try genisoimage first, then mkisofs
            let genisoimagePath = "/usr/bin/genisoimage"
            let mkisofsPath = "/usr/bin/mkisofs"
            if fileManager.fileExists(atPath: genisoimagePath) {
                process.executableURL = URL(fileURLWithPath: genisoimagePath)
            } else {
                process.executableURL = URL(fileURLWithPath: mkisofsPath)
            }
            process.arguments = [
                "-output", isoPath,
                "-volid", "cidata",
                "-joliet",
                "-rock",
                tempDir
            ]
            #endif

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            // Clean up temp directory
            try? fileManager.removeItem(atPath: tempDir)

            if process.terminationStatus == 0 {
                logger.debug("Created cloud-init ISO at: \(isoPath)")
                return true
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                logger.warning("Failed to create cloud-init ISO: \(output)")
                return false
            }
        } catch {
            logger.warning("Failed to create cloud-init ISO: \(error.localizedDescription)")
            try? fileManager.removeItem(atPath: tempDir)
            return false
        }
    }
    #endif
}

// MARK: - Mock VM for when SwiftQEMU is not available

#if !canImport(SwiftQEMU)
private class MockQEMUVM {
    let id: String

    init(id: String) {
        self.id = id
    }
}
#endif

// MARK: - QEMU Service Error Types

enum QEMUServiceError: Error, LocalizedError, Sendable {
    case vmNotFound(String)
    case vmNotCreated(String)
    case kvmNotAvailable
    case qemuNotInstalled
    case configurationError(String)
    case diskCreationFailed(String)
    case hotPlugFailed(String)

    var errorDescription: String? {
        switch self {
        case .vmNotFound(let message):
            return "QEMU VM not found: \(message)"
        case .vmNotCreated(let id):
            return "QEMU VM with ID \(id) is not created yet"
        case .kvmNotAvailable:
            return "KVM hardware virtualization is not available"
        case .qemuNotInstalled:
            return "QEMU is not installed on this system"
        case .configurationError(let message):
            return "QEMU configuration error: \(message)"
        case .diskCreationFailed(let message):
            return "Disk creation failed: \(message)"
        case .hotPlugFailed(let message):
            return "Hot-plug operation failed: \(message)"
        }
    }
}
