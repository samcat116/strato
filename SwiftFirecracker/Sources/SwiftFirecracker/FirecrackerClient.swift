import Foundation
import Logging

/// Client for spawning and managing Firecracker processes
/// Handles the full lifecycle including process creation, socket management, and cleanup
public actor FirecrackerClient {
    private let firecrackerBinaryPath: String
    private let socketDirectory: String
    private let logger: Logger

    private var runningVMs: [String: RunningVM] = [:]

    /// Information about a running VM
    private struct RunningVM {
        let process: Process
        let socketPath: String
        let manager: FirecrackerManager
    }

    /// Creates a new FirecrackerClient
    /// - Parameters:
    ///   - firecrackerBinaryPath: Path to the firecracker binary
    ///   - socketDirectory: Directory where Unix sockets will be created
    ///   - logger: Logger for debug output
    public init(
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker",
        logger: Logger = Logger(label: "SwiftFirecracker.Client")
    ) {
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory
        self.logger = logger
    }

    /// Creates a new microVM with the given configuration
    /// Returns a FirecrackerManager connected to the new VM
    public func createVM(vmId: String) async throws -> FirecrackerManager {
        // Check if VM already exists
        guard runningVMs[vmId] == nil else {
            throw FirecrackerError.vmAlreadyRunning(vmId)
        }

        // Verify Firecracker binary exists
        guard FileManager.default.fileExists(atPath: firecrackerBinaryPath) else {
            throw FirecrackerError.binaryNotFound(firecrackerBinaryPath)
        }

        // Create socket directory if needed
        try FileManager.default.createDirectory(
            atPath: socketDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let socketPath = "\(socketDirectory)/\(vmId).sock"

        // Remove existing socket if present
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        // Spawn Firecracker process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: firecrackerBinaryPath)
        process.arguments = [
            "--api-sock", socketPath,
            "--id", vmId,
            "--level", "Info"
        ]

        // Capture output for logging
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        logger.info("Starting Firecracker process", metadata: [
            "vm_id": "\(vmId)",
            "socket": "\(socketPath)",
            "binary": "\(firecrackerBinaryPath)"
        ])

        do {
            try process.run()
        } catch {
            throw FirecrackerError.processSpawnFailed(error.localizedDescription)
        }

        // Wait for socket to become available
        try await waitForSocket(path: socketPath, timeout: 5.0)

        // Create manager and connect
        let manager = FirecrackerManager(socketPath: socketPath, logger: logger)
        try await manager.connect()

        // Store VM info
        runningVMs[vmId] = RunningVM(
            process: process,
            socketPath: socketPath,
            manager: manager
        )

        logger.info("VM created successfully", metadata: ["vm_id": "\(vmId)"])
        return manager
    }

    /// Gets the manager for an existing VM
    public func getManager(vmId: String) async throws -> FirecrackerManager {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }
        return vm.manager
    }

    /// Destroys a VM and cleans up resources
    public func destroyVM(vmId: String) async throws {
        guard let vm = runningVMs[vmId] else {
            throw FirecrackerError.vmNotFound(vmId)
        }

        logger.info("Destroying VM", metadata: ["vm_id": "\(vmId)"])

        // Disconnect manager
        await vm.manager.disconnect()

        // Terminate process
        if vm.process.isRunning {
            vm.process.terminate()
            vm.process.waitUntilExit()
        }

        // Remove socket
        if FileManager.default.fileExists(atPath: vm.socketPath) {
            try? FileManager.default.removeItem(atPath: vm.socketPath)
        }

        // Remove from tracking
        runningVMs.removeValue(forKey: vmId)

        logger.info("VM destroyed", metadata: ["vm_id": "\(vmId)"])
    }

    /// Lists all running VMs
    public func listVMs() -> [String] {
        return Array(runningVMs.keys)
    }

    /// Checks if a VM is running
    public func isRunning(vmId: String) -> Bool {
        guard let vm = runningVMs[vmId] else {
            return false
        }
        return vm.process.isRunning
    }

    /// Waits for a Unix socket to become available
    private func waitForSocket(path: String, timeout: TimeInterval) async throws {
        let startTime = Date()
        let checkInterval: TimeInterval = 0.1

        while Date().timeIntervalSince(startTime) < timeout {
            if FileManager.default.fileExists(atPath: path) {
                // Socket file exists, try to verify it's ready
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return
            }
            try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }

        throw FirecrackerError.timeout("Waiting for socket at \(path)")
    }

    /// Cleans up all VMs (called on shutdown)
    public func cleanup() async {
        logger.info("Cleaning up all VMs", metadata: ["count": "\(runningVMs.count)"])
        for vmId in runningVMs.keys {
            try? await destroyVM(vmId: vmId)
        }
    }
}
