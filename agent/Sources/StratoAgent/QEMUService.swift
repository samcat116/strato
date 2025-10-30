import Foundation
import Logging
import StratoShared

#if canImport(SwiftQEMU)
import SwiftQEMU
#endif

actor QEMUService {
    private let logger: Logger
    private let networkService: (any NetworkServiceProtocol)?

    #if canImport(SwiftQEMU)
    private var activeVMs: [String: QEMUManager] = [:]
    private var vmConfigs: [String: VmConfig] = [:]
    private var vmNetworkInfo: [String: VMNetworkInfo] = [:]
    #else
    // Mock mode when SwiftQEMU is not available
    private var mockVMs: [String: MockQEMUVM] = [:]
    #endif

    init(logger: Logger, networkService: (any NetworkServiceProtocol)? = nil) {
        self.logger = logger
        self.networkService = networkService

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
    
    func createVM(config: VmConfig) async throws {
        let vmId = config.payload.kernel ?? UUID().uuidString

        #if canImport(SwiftQEMU)
        logger.info("Creating QEMU VM", metadata: ["vmId": .string(vmId)])

        let qemuManager = QEMUManager(logger: logger)

        // Set up VM networking first
        if let networks = config.net, !networks.isEmpty {
            try await setupVMNetworking(vmId: vmId, networks: networks)
        }

        // Configure and create VM
        let qemuConfig = convertToQEMUConfiguration(config, vmId: vmId)
        try await qemuManager.createVM(config: qemuConfig)

        activeVMs[vmId] = qemuManager
        vmConfigs[vmId] = config

        logger.info("QEMU VM created successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        logger.info("Creating mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
        mockVMs[vmId] = MockQEMUVM(id: vmId)
        #endif
    }
    
    func bootVM() async throws {
        #if canImport(SwiftQEMU)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUServiceError.vmNotFound("No VM available to boot")
        }

        logger.info("Booting QEMU VM")

        // Start VM execution
        try await firstVM.start()

        logger.info("QEMU VM booted successfully")
        #else
        // Mock mode
        logger.info("Booting mock QEMU VM (mock mode)")
        try await Task.sleep(for: .milliseconds(500)) // Simulate boot delay
        #endif
    }
    
    func shutdownVM() async throws {
        #if canImport(SwiftQEMU)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUServiceError.vmNotFound("No VM available to shutdown")
        }

        logger.info("Shutting down QEMU VM")

        // Graceful shutdown
        try await firstVM.shutdown()

        logger.info("QEMU VM shutdown completed")
        #else
        // Mock mode
        logger.info("Shutting down mock QEMU VM (mock mode)")
        try await Task.sleep(for: .milliseconds(200)) // Simulate shutdown delay
        #endif
    }

    func rebootVM() async throws {
        #if canImport(SwiftQEMU)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUServiceError.vmNotFound("No VM available to reboot")
        }

        logger.info("Rebooting QEMU VM")

        // System reset
        try await firstVM.reset()

        logger.info("QEMU VM reboot initiated")
        #else
        // Mock mode
        logger.info("Rebooting mock QEMU VM (mock mode)")
        try await Task.sleep(for: .milliseconds(300)) // Simulate reboot delay
        #endif
    }

    func pauseVM() async throws {
        #if canImport(SwiftQEMU)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUServiceError.vmNotFound("No VM available to pause")
        }

        logger.info("Pausing QEMU VM")

        // Pause VM
        try await firstVM.pause()

        logger.info("QEMU VM paused")
        #else
        // Mock mode
        logger.info("Pausing mock QEMU VM (mock mode)")
        #endif
    }

    func resumeVM() async throws {
        #if canImport(SwiftQEMU)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUServiceError.vmNotFound("No VM available to resume")
        }

        logger.info("Resuming QEMU VM")

        // Resume VM
        try await firstVM.start()

        logger.info("QEMU VM resumed")
        #else
        // Mock mode
        logger.info("Resuming mock QEMU VM (mock mode)")
        #endif
    }

    func deleteVM() async throws {
        #if canImport(SwiftQEMU)
        guard let (vmId, qemuManager) = activeVMs.first else {
            throw QEMUServiceError.vmNotFound("No VM available to delete")
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

        logger.info("QEMU VM deleted", metadata: ["vmId": .string(vmId)])
        #else
        // Mock mode
        if let (vmId, _) = mockVMs.first {
            logger.info("Deleting mock QEMU VM (mock mode)", metadata: ["vmId": .string(vmId)])
            mockVMs.removeValue(forKey: vmId)
        }
        #endif
    }
    
    // MARK: - VM Information
    
    func getVMInfo() async throws -> VmInfo {
        #if canImport(SwiftQEMU)
        guard let (vmId, qemuManager) = activeVMs.first,
              let config = vmConfigs[vmId] else {
            throw QEMUServiceError.vmNotFound("No VM available for info")
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

    func syncVMStatus() async throws -> StratoShared.VMStatus {
        #if canImport(SwiftQEMU)
        guard let qemuManager = activeVMs.values.first else {
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
        return mockVMs.isEmpty ? .shutdown : .running
        #endif
    }
    
    // MARK: - VM Management Helpers
    
    func createAndStartVM(config: VmConfig) async throws {
        try await createVM(config: config)
        try await bootVM()
    }
    
    func stopAndDeleteVM() async throws {
        do {
            try await shutdownVM()
            // Wait a moment for graceful shutdown
            try await Task.sleep(for: .seconds(2))
        } catch {
            logger.warning("VM shutdown failed, forcing delete: \(error)")
        }
        
        try await deleteVM()
    }
    
    // MARK: - Private Configuration Methods

    #if canImport(SwiftQEMU)
    private func convertToQEMUConfiguration(_ config: VmConfig, vmId: String) -> QEMUConfiguration {
        var qemuConfig = QEMUConfiguration()

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
                    #if os(Linux)
                    // Use TAP interface for OVN integration on Linux
                    return QEMUNetwork(
                        backend: "tap",
                        model: "virtio-net-pci",
                        macAddress: networkInfo.macAddress,
                        options: "ifname=\(networkInfo.tapInterface),script=no,downscript=no"
                    )
                    #else
                    // Use user-mode networking on macOS
                    return QEMUNetwork(
                        backend: "user",
                        model: "virtio-net-pci",
                        macAddress: networkInfo.macAddress
                    )
                    #endif
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

        // Configure kernel if provided
        let payload = config.payload
        qemuConfig.kernel = payload.kernel
        qemuConfig.initrd = payload.initramfs
        qemuConfig.kernelArgs = payload.cmdline

        // Enable hardware acceleration based on platform
        #if os(Linux)
        // Enable KVM on Linux
        qemuConfig.enableKVM = true
        logger.debug("Enabling KVM acceleration")
        #elseif os(macOS)
        // Enable Hypervisor.framework (HVF) on macOS
        qemuConfig.additionalArgs.append(contentsOf: ["-accel", "hvf"])
        logger.debug("Enabling Hypervisor.framework (HVF) acceleration")
        #endif

        qemuConfig.noGraphic = true
        qemuConfig.startPaused = true

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

enum QEMUServiceError: Error, LocalizedError {
    case vmNotFound(String)
    case vmNotCreated(String)
    case kvmNotAvailable
    case qemuNotInstalled
    case configurationError(String)
    
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
        }
    }
}