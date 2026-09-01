import Foundation
import StratoShared

/// The device fragments `LibvirtService` hands to `virDomainAttachDeviceFlags`,
/// `virDomainDetachDeviceFlags` and `virDomainUpdateDeviceFlags` (STR-134).
///
/// Every one of them is built from `DomainXMLBuilder`'s own element functions
/// rather than interpolated here. That is not tidiness: libvirt matches an
/// update or a detach against the device's *identity* as the fragment describes
/// it, so a fragment that drifts from what the create-time document said stops
/// matching the device it means to act on — and libvirt's answer to that is
/// either a puzzling "device not found" or, worse, a match on the wrong one.
/// Fragments live in the core library for the reason the builder gives: the
/// driver that sends them links a hypervisor SDK and has no unit tests.
public enum DomainDeviceXML {

    /// The same interface fragment used at domain creation, for hot-plug.
    public static func hotplugNetwork(_ attachment: ResolvedNetworkAttachment) throws -> String {
        try DomainXMLBuilder.interfaceNode(attachment).render()
    }

    /// Libvirt identifies an interface by MAC for hot-unplug. Interface MACs
    /// allocated by the control plane are stable across manifest upgrades and
    /// are therefore safer than a host TAP name reconstructed after a restart.
    public static func detachNetwork(macAddress: String) -> String {
        DomainXMLNode(
            "interface", [("type", "ethernet")],
            children: [DomainXMLNode("mac", [("address", macAddress)])]
        ).render()
    }

    /// A `<disk>` to hot-plug, naming its volume in `<serial>` so a later
    /// detach can find exactly this disk.
    ///
    /// No `<boot order>`: a disk plugged into a running guest cannot change
    /// what that guest already booted from, and emitting one here would collide
    /// with the create-time order before the other disks could be renumbered.
    /// `LibvirtService.attachDisk` separately rewrites the complete inactive
    /// definition through `DomainRedefinition.applyingBootOrder`, atomically
    /// setting the order the next boot reads.
    ///
    /// No `<address>` either — libvirt picks a free PCIe root port, of which
    /// the create-time document reserves `DomainXMLBuilder.spareHotplugPorts`
    /// at indexes past every port the domain's own devices occupy. That
    /// numbering is what makes them free; before STR-192 the ports were declared
    /// without it, libvirt filled them with the domain's own devices, and every
    /// attach this function feeds failed with "No more available PCI slots".
    public static func hotplugDisk(
        attachment: DiskAttachment, target: String, readonly: Bool, volumeId: String
    ) -> String {
        DomainXMLBuilder.diskNode(
            attachment: attachment, target: target, readonly: readonly, bootOrder: nil,
            volumeId: volumeId
        ).render()
    }

    /// The `<disk>` identifying an already-attached disk, for a hot-unplug.
    ///
    /// libvirt resolves a disk detach by `<target dev>`, but it parses the
    /// whole fragment first — so every attribute here is **echoed back from
    /// what libvirt reported**, never asserted. Disk attachments can be files,
    /// block devices, or network-backed RBD images, and the bus may also change.
    /// Hardcoding any of those values would make libvirt match nothing, or the
    /// wrong device, rather than return a legible error. Deriving the fragment
    /// is the rule this whole type states.
    public static func detachDisk(_ disk: DomainDisk) -> String {
        var node = DomainXMLNode(
            "disk", [("type", disk.type ?? "file"), ("device", disk.device ?? "disk")])
        if let driverType = disk.driverType {
            node.append(DomainXMLNode("driver", [("name", "qemu"), ("type", driverType)]))
        }
        if let sourceFile = disk.sourceFile {
            node.append(DomainXMLNode("source", [("file", sourceFile)]))
        }
        node.append(DomainXMLNode("target", [("dev", disk.target), ("bus", disk.bus)]))
        return node.render()
    }

    /// The `<memory model='virtio-mem'>` device with a new `<requested>`, for
    /// `virDomainUpdateDeviceFlags`.
    ///
    /// `sizeBytes` and `blockBytes` must be the ones the domain already
    /// declares — read them back with `DomainMemoryInventory`, never recompute
    /// them from the desired spec. They are what makes libvirt recognise this
    /// as the device already present rather than a different one, and a spec
    /// whose headroom has changed since the domain was defined would produce a
    /// fragment that matches nothing.
    public static func memoryDevice(
        sizeBytes: Int64, blockBytes: Int64, requestedBytes: Int64
    ) -> String {
        DomainXMLBuilder.memoryDeviceNode(
            sizeBytes: sizeBytes, blockBytes: blockBytes, requestedBytes: requestedBytes
        ).render()
    }
}
