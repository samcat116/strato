import Foundation
import StratoShared

/// Errors that can occur when interacting with a hypervisor service.
///
/// Lives in the testable core rather than beside `HypervisorService` (which is
/// in the executable target, and so unreachable from tests) because the
/// decisions taken *from* these cases — `OrphanDeleteAdoption` below, which
/// governs whether a delete may unlink a VM's disk — are worth pinning.
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

/// What re-adopting an orphan told a delete about the VM's hypervisor process
/// — which is what decides whether the delete may take the VM's files with it
/// (STR-179).
public enum OrphanDeleteAdoption: Equatable, Sendable {
    /// The session is back, so the delete runs the normal driver path and the
    /// driver reclaims everything itself.
    case adopted

    /// Adoption found no live process behind the VM's control socket, so there
    /// is nothing to tear down — and, the reason this case exists separately,
    /// nothing running from the VM's disks either.
    ///
    /// The evidence is the socket rather than the process, and both drivers
    /// raise `adoptionTargetGone` for a socket that is *missing* as well as one
    /// that is dead. A missing socket is the ordinary signature of a QEMU that
    /// exited — it unlinks its monitor socket on the way out — but it is also
    /// what a still-running VM created before deterministic sockets
    /// (#260 / #433) looks like. Only a host that has not restarted its agent
    /// since then can hold one of those, and `Agent.adoptVM` already treats the
    /// same error as "gone" and re-creates from the manifest spec, which
    /// materializes over the very same disks. So this reads the error the way
    /// the rest of the agent already does rather than inventing a second,
    /// stricter meaning for it on the delete path alone.
    case processGone

    /// Adoption failed without settling the question: no driver for the VM's
    /// backend on this host, a re-adoption handshake that timed out, a backend
    /// that cannot re-adopt at all. The VM may still be running, so its files
    /// stay put under the manual-cleanup contract.
    case indeterminate

    /// Classifies a failed re-adoption. Anything that is not positive evidence
    /// of a gone process is `.indeterminate` — the default has to be the answer
    /// that leaves a possibly-live guest's disk alone.
    public static func classify(adoptionFailure error: any Error) -> OrphanDeleteAdoption {
        guard let error = error as? HypervisorServiceError else { return .indeterminate }
        if case .adoptionTargetGone = error { return .processGone }
        return .indeterminate
    }
}
