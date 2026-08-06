import Foundation
import Logging
import StratoAgentCore
import StratoShared

/// Console access points a hypervisor exposes for a VM.
/// A backend may offer a serial socket, a virtio-console socket, a VNC socket,
/// any combination, or none.
///
/// The text and graphics consoles are independent, not ranked: for text,
/// consumers try `serialSocketPath` first and fall back to `consoleSocketPath`;
/// `vncSocketPath` is only ever used for a graphics session and has no
/// fallback, since serial bytes are not an RFB stream (issue #566).
public struct ConsoleEndpoint: Sendable {
    /// Unix socket path for the VM's serial console, if available
    public let serialSocketPath: String?

    /// Unix socket path for the VM's virtio-console, if available
    public let consoleSocketPath: String?

    /// Unix socket path for the VM's VNC server, present only when the VM was
    /// spawned with a graphics console. Absent means the guest is headless —
    /// which is not recoverable without recreating it, since the display device
    /// is fixed in the QEMU process's arguments.
    public let vncSocketPath: String?

    public init(serialSocketPath: String?, consoleSocketPath: String?, vncSocketPath: String? = nil) {
        self.serialSocketPath = serialSocketPath
        self.consoleSocketPath = consoleSocketPath
        self.vncSocketPath = vncSocketPath
    }

    /// True when no socket at all is available
    public var isEmpty: Bool {
        serialSocketPath == nil && consoleSocketPath == nil && vncSocketPath == nil
    }
}

/// What a completed full-VM checkpoint captured (issue #564), for the control
/// plane's snapshot record.
public struct VMCheckpointReport: Sendable {
    /// Bytes of guest RAM + device state the backend wrote, or nil when it
    /// reported no size for the checkpoint it just took. Nil is "unknown",
    /// never "empty".
    public let vmStateSizeBytes: Int64?
    /// Backend-native names of the storage the checkpoint spans, for
    /// diagnostics.
    public let deviceNodes: [String]
    /// The hypervisor build that captured the checkpoint. A restore needs a
    /// compatible one.
    public let hypervisorVersion: String?

    public init(vmStateSizeBytes: Int64?, deviceNodes: [String], hypervisorVersion: String?) {
        self.vmStateSizeBytes = vmStateSizeBytes
        self.deviceNodes = deviceNodes
        self.hypervisorVersion = hypervisorVersion
    }
}

/// Protocol defining the interface for hypervisor services
/// Both QEMUService and FirecrackerService conform to this protocol
public protocol HypervisorService: Actor, Sendable {
    /// The type of hypervisor
    var hypervisorType: HypervisorType { get }

    /// Creates a VM from a hypervisor-neutral spec. The service translates the
    /// spec into its driver-native configuration (paths, sockets, machine types).
    ///
    /// Network attachments are resolved by the agent's `NetworkOrchestrator`
    /// before this call and torn down by it after `deleteVM` — drivers only
    /// translate each `NetworkAttachment` into their native NIC configuration,
    /// throwing `HypervisorServiceError.notSupported` for kinds their backend
    /// cannot realize.
    /// - Parameters:
    ///   - vmId: Unique identifier for the VM
    ///   - spec: Hypervisor-neutral VM specification
    ///   - imageInfo: Optional image info for disk caching
    ///   - networkAttachments: Host-realized NICs, in `spec.networks` order
    ///   - metadata: What the control plane publishes about this instance, from
    ///     the desired-state sync. A driver's guest-bootstrap media renders from
    ///     it — today only the hostname, which the seed ISO must agree with
    ///     because the same value is what the VM's DNS zone is assembled from
    ///     (STR-177). Guest-provisioning *payloads* still come from the spec:
    ///     `sshAuthorizedKeys`/`userData` are duplicated here for the running
    ///     guest to re-read, not for boot. Nil when the control plane sent none
    ///     (pre-STR-51), which is not an instruction — just nothing to render.
    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?, networkAttachments: [ResolvedNetworkAttachment],
        metadata: InstanceMetadata?
    ) async throws

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

    /// Removes what the VM left on this host, for a delete that has no session
    /// to tear down (STR-179).
    ///
    /// `deleteVM` is the normal route and reclaims the same state on its way
    /// out. This is for the one path that cannot reach it: an orphan whose
    /// re-adoption reported the hypervisor process *gone*, so there is nothing
    /// to destroy — while its boot disk, cloud-init ISO and the rest of its
    /// directory are still on the host. That delete then drops the VM's
    /// manifest entry, the last thing on the host that knows the VM was ever
    /// here, so anything left behind is leaked for good.
    ///
    /// Callers must hold that evidence: this unlinks the disk a live guest
    /// would still be running from. Best-effort and non-throwing — the delete
    /// releases the manifest entry either way, so a failure here is loud in
    /// the log rather than something a caller can act on — and a backend with
    /// nothing on disk implements it as a no-op.
    /// - Parameter vmId: The VM identifier
    func reclaimVMDirectory(vmId: String) async

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

    /// Converges a running VM's vCPU count and memory size on `spec`
    /// (issue #568), within the headroom the VM was created with. Growth
    /// applies online; anything the backend cannot do without a restart is
    /// left for the next boot, which uses the spec wholesale.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   resize a running VM at all
    func resizeVM(vmId: String, spec: VMSpec) async throws

    /// Sum of vCPUs and memory (in bytes) committed to VMs this service manages.
    /// Used to compute accurate available-resource figures for the scheduler.
    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64)

    /// Re-adopts a VM whose hypervisor process survived an agent restart
    /// (reconciliation phase 2, issue #260): reconnects the control session
    /// and returns the VM's observed status. Backends without a reattachable
    /// session throw `HypervisorServiceError.notSupported`, in which case the
    /// VM stays orphaned.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus

    /// Checkpoints a VM (issue #564): guest RAM, device state, and disk
    /// contents captured at one consistent point under `snapshotId`, with the
    /// VM left running.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend has no
    ///   full-VM checkpoint mechanism, or if the VM's storage cannot hold one
    func checkpointVM(vmId: String, snapshotId: String) async throws -> VMCheckpointReport

    /// Restores a VM in place from one of its checkpoints and resumes it. Same
    /// VM, same identity — it keeps its ID, disks, NICs, and addresses.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   restore checkpoints
    func restoreVM(vmId: String, snapshotId: String) async throws

    /// Removes a checkpoint's stored state. Idempotent: a checkpoint that is
    /// already gone is a success, so a retried delete converges.
    /// - Throws: `HypervisorServiceError.notSupported` if this backend cannot
    ///   take checkpoints in the first place
    func deleteVMCheckpoint(vmId: String, snapshotId: String) async throws
}

// MARK: - Default Implementations

public extension HypervisorService {
    /// Backends must opt in to online resize; without an explicit
    /// implementation a sizing change waits for the VM's next boot.
    func resizeVM(vmId: String, spec: VMSpec) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support resizing a running VM")
    }

    /// Backends must opt in to orphan re-adoption; without an explicit
    /// implementation an orphan cannot be reattached.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support re-adopting orphaned VMs")
    }
    /// Backends must opt in to full-VM checkpoints (issue #564). Without an
    /// explicit implementation the control plane's capability gate keeps the
    /// request away in the first place; this default is the belt-and-braces
    /// answer for one that arrives anyway.
    func checkpointVM(vmId: String, snapshotId: String) async throws -> VMCheckpointReport {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support full-VM checkpoints")
    }

    func restoreVM(vmId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support restoring full-VM checkpoints")
    }

    func deleteVMCheckpoint(vmId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported(
            "\(hypervisorType.displayName) does not support full-VM checkpoints")
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

    /// An orphaned VM's hypervisor process no longer exists, so there is
    /// nothing to re-adopt. The VM's on-host state (disks) may still exist;
    /// re-creating it is the way to recover.
    case adoptionTargetGone(String)

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
        case .adoptionTargetGone(let message):
            return "Orphaned VM's process is gone: \(message)"
        }
    }
}
