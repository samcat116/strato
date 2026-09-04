import Foundation

/// On-disk image formats a file-backed storage layer can produce.
///
/// This is part of the wire contract only for `.file` attachments. Block
/// devices and native network storage do not acquire a file format merely
/// because a hypervisor needs to choose a driver for them.
public enum DiskFormat: String, Codable, Sendable, CaseIterable {
    case qcow2
    case raw

    /// File extension used by the filesystem backend's path layout.
    public var fileExtension: String { rawValue }

    /// Best-effort inference for historical file attachments that carried only
    /// a path. Unknown extensions preserve the former qcow2 assumption.
    public init(volumePath: String) {
        self = DiskFormat(rawValue: (volumePath as NSString).pathExtension) ?? .qcow2
    }
}

/// The host-cache policy requested for a QEMU volume attachment.
///
/// Neither optimized mode is the default until representative benchmarks have
/// compared them. `conservative` preserves the historical libvirt/QEMU
/// defaults; `direct` asks the agent to use direct I/O only when its live
/// capability probe succeeds; and `cachedShared` explicitly retains the host
/// page cache for read-mostly images whose backing pages can be shared.
public enum VolumeBlockMode: String, Codable, Sendable, CaseIterable {
    case conservative
    case direct
    case cachedShared
}

/// A QEMU cache value that an agent has actually selected.
public enum BlockDeviceCacheMode: String, Codable, Sendable {
    case none
    case writeback
}

/// A QEMU asynchronous-I/O engine that an agent has actually selected.
public enum BlockDeviceIOMode: String, Codable, Sendable {
    case ioUring = "io_uring"
}

/// The complete block-device policy an agent selected for one attachment.
///
/// This is applied state, not a capability claim. Optional driver values mean
/// the corresponding libvirt XML attribute was deliberately omitted. An
/// inactive value is the explicit current-agent report for a detached volume;
/// absence of the whole structure means an older agent did not report policy.
public struct AppliedBlockDevicePolicy: Codable, Equatable, Sendable {
    public let active: Bool
    public let requestedMode: VolumeBlockMode
    public let cacheMode: BlockDeviceCacheMode?
    public let ioMode: BlockDeviceIOMode?
    public let discard: Bool
    public let nonRotational: Bool
    public let queueCount: Int?
    public let fallbackReason: String?

    public init(
        active: Bool,
        requestedMode: VolumeBlockMode,
        cacheMode: BlockDeviceCacheMode? = nil,
        ioMode: BlockDeviceIOMode? = nil,
        discard: Bool = false,
        nonRotational: Bool = false,
        queueCount: Int? = nil,
        fallbackReason: String? = nil
    ) {
        self.active = active
        self.requestedMode = requestedMode
        self.cacheMode = cacheMode
        self.ioMode = ioMode
        self.discard = discard
        self.nonRotational = nonRotational
        self.queueCount = queueCount
        self.fallbackReason = fallbackReason
    }

    public static func inactive(requestedMode: VolumeBlockMode) -> Self {
        Self(active: false, requestedMode: requestedMode)
    }
}

/// A storage-backend-owned disk reference that a hypervisor can realize.
///
/// The cases are intentionally exhaustive rather than a path plus optional
/// network coordinates. A caller must choose the correct realization instead
/// of interpreting one string differently according to pool configuration.
public enum DiskAttachment: Codable, Equatable, Sendable {
    /// A regular host file whose image format must be declared to the
    /// hypervisor.
    case file(path: String, format: DiskFormat)
    /// A host block device, such as a krbd or LVM mapping.
    case blockDevice(path: String)
    /// A native RADOS Block Device opened by a network-capable hypervisor.
    ///
    /// These are canonical, non-secret coordinates. `clusterId` distinguishes
    /// clusters that happen to use the same pool and image names;
    /// `credentialId` is also the deterministic libvirt secret UUID; and
    /// `configPath` points at the durable client configuration materialized on
    /// every eligible agent. The keyring itself never travels in an attachment.
    case rbd(
        pool: String,
        image: String,
        namespace: String,
        user: String,
        monEndpoints: [String],
        clusterId: UUID,
        credentialId: UUID,
        configPath: String
    )
}
