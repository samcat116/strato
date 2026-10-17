import Foundation
import StratoShared

/// The supported subset of VMSpec for Apple's native Linux VM backend.
/// Validation precedes filesystem writes or framework object creation.
public struct AppleVirtualizationPlan: Sendable {
    public struct Disk: Sendable {
        public let path: String
        public let readonly: Bool
    }
    public let spec: VMSpec
    public let disks: [Disk]
    public let networks: [ResolvedNetworkAttachment]

    public init(
        spec: VMSpec, networks: [ResolvedNetworkAttachment], memoryBounds: ClosedRange<Int64>? = nil
    ) throws {
        func unsupported(_ reason: String) throws -> Never {
            throw HypervisorServiceError.notSupported("Apple Virtualization: \(reason)")
        }
        guard spec.cpus > 0, spec.memoryBytes > 0 else {
            throw HypervisorServiceError.invalidConfiguration("CPU and memory must be positive")
        }
        guard spec.memoryBytes % (1 << 20) == 0,
            memoryBounds?.contains(spec.memoryBytes) != false
        else {
            throw HypervisorServiceError.invalidConfiguration(
                "Apple Virtualization memory must be MiB-aligned and within the host's framework bounds")
        }
        if spec.effectiveMachine.secureBoot || spec.effectiveMachine.tpm {
            try unsupported("Secure Boot and TPM")
        }
        if spec.guestAgentEnabled { try unsupported("guest execution") }
        if spec.console?.effectiveGraphics == .vnc { try unsupported("VNC graphics") }
        if spec.metadataSource != .iso { try unsupported("IMDS; select ISO metadata") }
        if spec.hugepages || spec.sharedMemory { try unsupported("huge pages or shared memory") }
        if spec.balloonTargetBytes != nil { try unsupported("balloon targets") }
        if spec.resourceClass?.policy.kind == .burstable { try unsupported("burstable resource classes") }
        if case .disk(let firmware) = spec.boot, firmware != nil {
            try unsupported("custom firmware; EFI is provided by macOS")
        }
        guard networks.count == spec.networks.count else {
            throw HypervisorServiceError.invalidConfiguration("every NIC needs a resolved attachment")
        }
        for network in networks {
            guard network.attachment == .userMode else { try unsupported("TAP/OVN networking") }
            if let mtu = network.mtu, mtu != 1500 { try unsupported("custom network MTU") }
        }
        var paths = Set<String>()
        var disks: [Disk] = []
        for volume in spec.volumes {
            if volume.ioLimits?.isEmpty == false { try unsupported("volume I/O limits") }
            if volume.blockMode != .conservative { try unsupported("optimized block policies") }
            guard case .file(let path, .raw)? = volume.attachment else {
                try unsupported("disks must be realized local raw images")
            }
            guard paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted else {
                throw HypervisorServiceError.invalidConfiguration("duplicate disk attachment")
            }
            disks.append(Disk(path: path, readonly: volume.readonly))
        }
        guard !disks.isEmpty else {
            throw HypervisorServiceError.invalidConfiguration("a managed boot volume is required")
        }
        self.spec = spec
        self.disks = disks
        self.networks = networks
    }
}
