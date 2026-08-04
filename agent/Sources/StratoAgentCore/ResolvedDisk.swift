import Foundation

/// A disk realized on this host: the agent-resolved path plus attach options.
///
/// The counterpart to `ResolvedNetworkAttachment` — what a hypervisor driver
/// consumes after image materialization and volume resolution have run, so the
/// driver never has to know how the path was arrived at.
///
/// `QEMUService` carries an identical private struct of its own; it is left
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

    public init(path: String, format: DiskFormat, readonly: Bool = false, bootOrder: Int? = nil) {
        self.path = path
        self.format = format
        self.readonly = readonly
        self.bootOrder = bootOrder
    }
}
