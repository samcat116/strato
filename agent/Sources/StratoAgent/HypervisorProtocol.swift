import Foundation
import Logging
import StratoShared

/// Protocol defining the interface for hypervisor services
/// Both QEMUService and FirecrackerService conform to this protocol
public protocol HypervisorService: Actor, Sendable {
    /// The type of hypervisor
    var hypervisorType: HypervisorType { get }

    /// Creates a VM with the given configuration
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - config: VM configuration
    ///   - imageInfo: Optional image info for disk caching
    func createVM(vmId: String, config: VmConfig, imageInfo: ImageInfo?) async throws

    /// Boots (starts) a VM
    /// - Parameter vmId: The VM identifier
    func bootVM(vmId: String) async throws

    /// Shuts down a VM gracefully
    /// - Parameter vmId: The VM identifier
    func shutdownVM(vmId: String) async throws

    /// Reboots a VM
    /// - Parameter vmId: The VM identifier
    func rebootVM(vmId: String) async throws

    /// Pauses a running VM
    /// - Parameter vmId: The VM identifier
    func pauseVM(vmId: String) async throws

    /// Resumes a paused VM
    /// - Parameter vmId: The VM identifier
    func resumeVM(vmId: String) async throws

    /// Deletes a VM and cleans up resources
    /// - Parameter vmId: The VM identifier
    func deleteVM(vmId: String) async throws

    /// Gets information about a VM
    /// - Parameter vmId: The VM identifier
    /// - Returns: VM configuration and state information
    func getVMInfo(vmId: String) async throws -> VmInfo

    /// Gets the current status of a VM
    /// - Parameter vmId: The VM identifier
    /// - Returns: The current VM status
    func getVMStatus(vmId: String) async throws -> VMStatus

    /// Lists all VM IDs managed by this service
    /// - Returns: Array of VM identifiers
    func listVMs() async -> [String]
}

// MARK: - Default Implementations

public extension HypervisorService {
    /// Creates and starts a VM in a single operation
    func createAndStartVM(vmId: String, config: VmConfig, imageInfo: ImageInfo? = nil) async throws {
        try await createVM(vmId: vmId, config: config, imageInfo: imageInfo)
        try await bootVM(vmId: vmId)
    }

    /// Stops and deletes a VM
    func stopAndDeleteVM(vmId: String) async throws {
        do {
            try await shutdownVM(vmId: vmId)
            // Wait for graceful shutdown
            try await Task.sleep(for: .seconds(2))
        } catch {
            // Continue with deletion even if shutdown fails
        }
        try await deleteVM(vmId: vmId)
    }
}

// MARK: - Hypervisor Service Error

/// Errors that can occur when interacting with a hypervisor service
public enum HypervisorServiceError: Error, LocalizedError, Sendable {
    /// The specified VM was not found
    case vmNotFound(String)

    /// The VM is already running
    case vmAlreadyRunning(String)

    /// The VM is not running
    case vmNotRunning(String)

    /// The VM is in an invalid state for the operation
    case invalidState(vmId: String, current: VMStatus, expected: [VMStatus])

    /// Invalid configuration provided
    case invalidConfiguration(String)

    /// Disk operation failed
    case diskError(String)

    /// Network operation failed
    case networkError(String)

    /// The hypervisor binary is not installed
    case hypervisorNotInstalled(String)

    /// Timeout waiting for operation
    case timeout(String)

    /// Operation not supported by this hypervisor
    case notSupported(String)

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let vmId):
            return "VM not found: \(vmId)"
        case .vmAlreadyRunning(let vmId):
            return "VM is already running: \(vmId)"
        case .vmNotRunning(let vmId):
            return "VM is not running: \(vmId)"
        case .invalidState(let vmId, let current, let expected):
            return "VM \(vmId) is in state \(current), expected one of: \(expected.map(\.rawValue).joined(separator: ", "))"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .diskError(let message):
            return "Disk error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .hypervisorNotInstalled(let path):
            return "Hypervisor not installed at: \(path)"
        case .timeout(let operation):
            return "Timeout during: \(operation)"
        case .notSupported(let operation):
            return "Operation not supported: \(operation)"
        }
    }
}
