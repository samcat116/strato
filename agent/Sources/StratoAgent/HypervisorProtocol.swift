import Foundation
import Logging
import StratoShared

/// Console access points a hypervisor exposes for a VM.
/// A backend may offer a serial socket, a virtio-console socket, both, or neither.
/// Consumers should try `serialSocketPath` first and fall back to `consoleSocketPath`.
public struct ConsoleEndpoint: Sendable {
    /// Unix socket path for the VM's serial console, if available
    public let serialSocketPath: String?

    /// Unix socket path for the VM's virtio-console, if available
    public let consoleSocketPath: String?

    public init(serialSocketPath: String?, consoleSocketPath: String?) {
        self.serialSocketPath = serialSocketPath
        self.consoleSocketPath = consoleSocketPath
    }

    /// True when neither socket is available
    public var isEmpty: Bool {
        serialSocketPath == nil && consoleSocketPath == nil
    }
}

/// Protocol defining the interface for hypervisor services
/// Both QEMUService and FirecrackerService conform to this protocol
public protocol HypervisorService: Actor, Sendable {
    /// The type of hypervisor
    var hypervisorType: HypervisorType { get }

    /// Creates a VM from a hypervisor-neutral spec. The service translates the
    /// spec into its driver-native configuration (paths, sockets, machine types).
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - spec: Hypervisor-neutral VM specification
    ///   - imageInfo: Optional image info for disk caching
    func createVM(vmId: String, spec: VMSpec, imageInfo: ImageInfo?) async throws

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

    /// Returns the console access points for a VM, or nil if none exist yet
    /// (e.g. the VM is not running).
    /// - Parameter vmId: The VM identifier
    /// - Throws: `HypervisorServiceError.notSupported` if this backend has no
    ///   console mechanism at all
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint?

    /// Attaches a disk to a running VM (hot-plug)
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   hot-plug disks
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws

    /// Detaches a disk from a running VM (hot-unplug)
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   hot-unplug disks
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws

    /// Sum of vCPUs and memory (in bytes) committed to VMs this service manages.
    /// Used to compute accurate available-resource figures for the scheduler.
    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64)
}

// MARK: - Default Implementations

public extension HypervisorService {
    /// Creates and starts a VM in a single operation
    func createAndStartVM(vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil) async throws {
        try await createVM(vmId: vmId, spec: spec, imageInfo: imageInfo)
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
            return
                "VM \(vmId) is in state \(current), expected one of: \(expected.map(\.rawValue).joined(separator: ", "))"
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
