import Foundation

/// A disk realized on this host: the agent-resolved path plus attach options.
///
/// The counterpart to `ResolvedNetworkAttachment` — what a hypervisor driver
/// consumes after image materialization and volume resolution have run, so the
/// driver never has to know how the path was arrived at.
///
/// The process driver carried an identical private struct of its own; it was left
/// alone so the libvirt work stays additive, and the `LibvirtService` issue
/// collapses the two.
public struct ResolvedDisk: Sendable, Equatable {
    public let path: String
    public let format: DiskFormat
    public let readonly: Bool
    /// Firmware boot order from `VolumeSpec.bootOrder`, when the control plane
    /// set one. Nil on every disk means no boot element is emitted at all and
    /// firmware picks — which is what the QEMU command line does today, since
    /// it passes no `-boot`.
    ///
    /// Treat the value as a flag rather than an index: nothing in Strato keeps
    /// it in the range libvirt accepts, so consumers derive their own ordering
    /// from the sequence (see `DomainXMLBuilder.derivedBootOrders`).
    public let bootOrder: Int?
    /// The volume this disk realizes, when it realizes one. Nil for a boot disk
    /// materialized from an image, which no volume owns.
    ///
    /// Carried so the disk can *name* its volume in the domain document
    /// (`<serial>`, see `DomainXMLBuilder.diskNode`). That is what lets a later
    /// detach resolve exactly this disk out of a domain the agent did not keep
    /// a model of — the STR-129 rule, applied to a document instead of to a QMP
    /// device id.
    public let volumeId: String?

    public init(
        path: String, format: DiskFormat, readonly: Bool = false, bootOrder: Int? = nil,
        volumeId: String? = nil
    ) {
        self.path = path
        self.format = format
        self.readonly = readonly
        self.bootOrder = bootOrder
        self.volumeId = volumeId
    }
}
