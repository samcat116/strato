import Foundation
import Logging

/// High-level QEMU VM manager combining process and QMP management
public actor QEMUManager {
    private let logger: Logger
    private let process: QEMUProcess
    private let qmpClient: QMPClient
    private var isConnected = false
    
    /// Current VM status
    public private(set) var status: QEMUVMStatus = .stopped
    
    public init(
        qemuPath: String = "/usr/bin/qemu-system-x86_64",
        logger: Logger = Logger(label: "SwiftQEMU.QEMUManager")
    ) {
        self.logger = logger
        self.process = QEMUProcess(qemuPath: qemuPath, logger: logger)
        self.qmpClient = QMPClient(logger: logger)
    }
    
    // MARK: - VM Lifecycle
    
    /// Create and start a VM with the given configuration
    public func createVM(config: QEMUConfiguration) async throws {
        guard !process.isRunning else {
            throw QMPError.processAlreadyRunning
        }
        
        logger.info("Creating QEMU VM")
        
        // Start QEMU process
        try await process.start(with: config)
        
        // Connect to QMP
        let socketPath = process.getQMPSocketPath()
        try await qmpClient.connectUnix(path: socketPath)
        isConnected = true
        
        // Update status
        await updateStatus()
        
        logger.info("QEMU VM created successfully")
    }
    
    /// Start/resume VM execution
    public func start() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Starting VM")
        
        try await qmpClient.cont()
        status = .running
        
        logger.info("VM started")
    }
    
    /// Pause VM execution
    public func pause() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Pausing VM")
        
        try await qmpClient.stop()
        status = .paused
        
        logger.info("VM paused")
    }
    
    /// Reset the VM
    public func reset() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Resetting VM")
        
        try await qmpClient.systemReset()
        await updateStatus()
        
        logger.info("VM reset")
    }
    
    /// Shutdown the VM gracefully
    public func shutdown() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Shutting down VM")
        
        try await qmpClient.systemPowerdown()
        status = .shuttingDown
        
        // Wait for shutdown with timeout
        // Wait for shutdown with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
            
            group.addTask {
                try await self.process.waitUntilExit()
            }
            
            // Wait for first task to complete (either timeout or shutdown)
            _ = try await group.next()
            group.cancelAll()
        }
        
        if process.isRunning {
            logger.warning("VM did not shut down gracefully, forcing termination")
            try await destroy()
        } else {
            status = .stopped
            isConnected = false
        }
        
        logger.info("VM shutdown complete")
    }
    
    /// Force quit the VM
    public func destroy() async throws {
        logger.info("Destroying VM")
        
        if isConnected {
            do {
                try await qmpClient.quit()
            } catch {
                logger.debug("QMP quit failed, process may already be terminating")
            }
            
            try await qmpClient.disconnect()
            isConnected = false
        }
        
        process.stop()
        status = .stopped
        
        logger.info("VM destroyed")
    }
    
    /// Get current VM status
    public func getStatus() async throws -> QEMUVMStatus {
        guard isConnected else {
            return .stopped
        }
        
        await updateStatus()
        return status
    }
    
    /// Update status from QMP
    private func updateStatus() async {
        do {
            let qmpStatus = try await qmpClient.queryStatus()
            
            switch qmpStatus.status.lowercased() {
            case "running":
                status = qmpStatus.running ? .running : .paused
            case "paused", "suspended":
                status = .paused
            case "shutdown", "poweroff":
                status = .stopped
            case "inmigrate", "prelaunch":
                status = .creating
            default:
                logger.warning("Unknown QMP status: \(qmpStatus.status)")
                status = .unknown
            }
        } catch {
            logger.error("Failed to query VM status: \(error)")
            status = .unknown
        }
    }
}

// MARK: - VM Status

public enum QEMUVMStatus: String, Codable, Sendable {
    case stopped
    case creating
    case running
    case paused
    case shuttingDown
    case unknown
}

