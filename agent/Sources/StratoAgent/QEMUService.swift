import Foundation
import Logging
import StratoShared

#if os(Linux)
import QEMUKit
#endif

class QEMUService {
    private let logger: Logger
    private weak var networkService: NetworkService?
    
    #if os(Linux)
    private var activeVMs: [String: QEMUVirtualMachine] = [:]
    private var vmConfigs: [String: VmConfig] = [:]
    private var vmNetworkInfo: [String: VMNetworkInfo] = [:]
    #else
    // Development mode on macOS - mock VM storage
    private var mockVMs: [String: MockQEMUVM] = [:]
    #endif
    
    init(logger: Logger, networkService: NetworkService? = nil) {
        self.logger = logger
        self.networkService = networkService
        
        #if os(Linux)
        logger.info("QEMU service initialized with QEMUKit support")
        #else
        logger.warning("QEMU service running in development mode - operations will be mocked")
        #endif
    }
    
    // MARK: - VM Lifecycle Operations
    
    func createVM(config: VmConfig) async throws {
        let vmId = config.payload.kernel ?? UUID().uuidString
        
        #if os(Linux)
        logger.info("Creating QEMU VM", metadata: ["vmId": .string(vmId)])
        
        let qemuVM = QEMUVirtualMachine()
        await qemuVM.setDelegate(self)
        
        // Set up VM networking first
        if let networks = config.net, !networks.isEmpty {
            try await setupVMNetworking(vmId: vmId, networks: networks)
        }
        
        // Configure VM with provided config
        try await configureQEMUVM(qemuVM, with: config)
        
        activeVMs[vmId] = qemuVM
        vmConfigs[vmId] = config
        
        logger.info("QEMU VM created successfully", metadata: ["vmId": .string(vmId)])
        #else
        // Development mode
        logger.info("Creating mock QEMU VM (development mode)", metadata: ["vmId": .string(vmId)])
        mockVMs[vmId] = MockQEMUVM(id: vmId)
        #endif
    }
    
    func bootVM() async throws {
        #if os(Linux)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUError.vmNotFound("No VM available to boot")
        }
        
        logger.info("Booting QEMU VM")
        
        // Start QEMU with launcher and interface
        try await firstVM.start(launcher: QEMULauncher(), interface: QEMUIOService())
        try await firstVM.monitor?.continueBoot()
        
        logger.info("QEMU VM booted successfully")
        #else
        // Development mode
        logger.info("Booting mock QEMU VM (development mode)")
        try await Task.sleep(for: .milliseconds(500)) // Simulate boot delay
        #endif
    }
    
    func shutdownVM() async throws {
        #if os(Linux)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUError.vmNotFound("No VM available to shutdown")
        }
        
        logger.info("Shutting down QEMU VM")
        
        // Graceful shutdown via QMP
        try await firstVM.monitor?.systemPowerdown()
        
        logger.info("QEMU VM shutdown initiated")
        #else
        // Development mode
        logger.info("Shutting down mock QEMU VM (development mode)")
        try await Task.sleep(for: .milliseconds(200)) // Simulate shutdown delay
        #endif
    }
    
    func rebootVM() async throws {
        #if os(Linux)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUError.vmNotFound("No VM available to reboot")
        }
        
        logger.info("Rebooting QEMU VM")
        
        // System reset via QMP
        try await firstVM.monitor?.systemReset()
        
        logger.info("QEMU VM reboot initiated")
        #else
        // Development mode
        logger.info("Rebooting mock QEMU VM (development mode)")
        try await Task.sleep(for: .milliseconds(300)) // Simulate reboot delay
        #endif
    }
    
    func pauseVM() async throws {
        #if os(Linux)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUError.vmNotFound("No VM available to pause")
        }
        
        logger.info("Pausing QEMU VM")
        
        // Pause VM via QMP
        try await firstVM.monitor?.stop()
        
        logger.info("QEMU VM paused")
        #else
        // Development mode
        logger.info("Pausing mock QEMU VM (development mode)")
        #endif
    }
    
    func resumeVM() async throws {
        #if os(Linux)
        guard let firstVM = activeVMs.values.first else {
            throw QEMUError.vmNotFound("No VM available to resume")
        }
        
        logger.info("Resuming QEMU VM")
        
        // Resume VM via QMP
        try await firstVM.monitor?.cont()
        
        logger.info("QEMU VM resumed")
        #else
        // Development mode
        logger.info("Resuming mock QEMU VM (development mode)")
        #endif
    }
    
    func deleteVM() async throws {
        #if os(Linux)
        guard let (vmId, qemuVM) = activeVMs.first else {
            throw QEMUError.vmNotFound("No VM available to delete")
        }
        
        logger.info("Deleting QEMU VM", metadata: ["vmId": .string(vmId)])
        
        // Stop VM if running
        do {
            try await qemuVM.monitor?.quit()
        } catch {
            // VM may already be stopped
            logger.debug("VM quit command failed, VM may already be stopped")
        }
        
        // Clean up VM networking
        try await cleanupVMNetworking(vmId: vmId)
        
        // Clean up VM resources
        activeVMs.removeValue(forKey: vmId)
        vmConfigs.removeValue(forKey: vmId)
        vmNetworkInfo.removeValue(forKey: vmId)
        
        logger.info("QEMU VM deleted", metadata: ["vmId": .string(vmId)])
        #else
        // Development mode
        if let (vmId, _) = mockVMs.first {
            logger.info("Deleting mock QEMU VM (development mode)", metadata: ["vmId": .string(vmId)])
            mockVMs.removeValue(forKey: vmId)
        }
        #endif
    }
    
    // MARK: - VM Information
    
    func getVMInfo() async throws -> VmInfo {
        #if os(Linux)
        guard let (vmId, qemuVM) = activeVMs.first,
              let config = vmConfigs[vmId] else {
            throw QEMUError.vmNotFound("No VM available for info")
        }
        
        // Query VM status via QMP
        let status = try await qemuVM.monitor?.queryStatus() ?? "unknown"
        
        return VmInfo(
            config: config,
            state: status,
            memoryActualSize: config.memory?.size
        )
        #else
        // Development mode - return mock info
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
    
    func syncVMStatus() async throws -> VMStatus {
        #if os(Linux)
        guard let qemuVM = activeVMs.values.first else {
            return .shutdown
        }
        
        do {
            if let statusInfo = try await qemuVM.monitor?.queryStatus() {
                // Map QEMU status to VMStatus
                switch statusInfo.lowercased() {
                case "running":
                    return .running
                case "paused":
                    return .paused
                case "shutdown", "poweroff":
                    return .shutdown
                default:
                    return .created
                }
            } else {
                return .shutdown
            }
        } catch {
            logger.error("Failed to query VM status: \(error)")
            return .shutdown
        }
        #else
        // Development mode - return mock status
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
    
    #if os(Linux)
    private func configureQEMUVM(_ qemuVM: QEMUVirtualMachine, with config: VmConfig) async throws {
        // Configure CPU
        if let cpuConfig = config.cpus {
            // Set CPU configuration
            logger.debug("Configuring CPU: \(cpuConfig.bootVcpus) cores")
        }
        
        // Configure Memory  
        if let memoryConfig = config.memory {
            // Set memory configuration
            logger.debug("Configuring memory: \(memoryConfig.size) bytes")
        }
        
        // Configure disks
        if let disks = config.disks {
            for disk in disks {
                logger.debug("Configuring disk: \(disk.path)")
            }
        }
        
        // Configure networking
        if let networks = config.net {
            for network in networks {
                logger.debug("Configuring network interface")
                
                // Get network info for this VM
                if let networkInfo = vmNetworkInfo[vmId] {
                    // Configure QEMU to use the TAP interface
                    logger.debug("Configuring QEMU network device", metadata: [
                        "tapInterface": .string(networkInfo.tapInterface),
                        "macAddress": .string(networkInfo.macAddress)
                    ])
                }
            }
        }
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

// MARK: - QEMU Virtual Machine Delegate

#if os(Linux)
extension QEMUService: QEMUVirtualMachineDelegate {
    func virtualMachine(_ vm: QEMUVirtualMachine, didChangeState state: QEMUVMState) {
        logger.info("QEMU VM state changed", metadata: ["state": .string(String(describing: state))])
        
        // Here you could notify the Control Plane of state changes
        // via the WebSocket connection
    }
    
    func virtualMachine(_ vm: QEMUVirtualMachine, didError error: Error) {
        logger.error("QEMU VM error: \(error)")
    }
}
#endif

// MARK: - Development Mode Mock VM

#if !os(Linux)
private class MockQEMUVM {
    let id: String
    
    init(id: String) {
        self.id = id
    }
}
#endif

// MARK: - QEMU Error Types

enum QEMUError: Error, LocalizedError {
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