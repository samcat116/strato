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
    case rbd(pool: String, image: String, user: String, monHosts: [String])
}
