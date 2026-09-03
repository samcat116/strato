import Foundation
import StratoAgentKit
import StratoShared

/// The device fragments `LibvirtService` hands to `virDomainAttachDeviceFlags`,
/// `virDomainDetachDeviceFlags` and `virDomainUpdateDeviceFlags` (STR-134).
///
/// New-device fragments come from `DomainXMLBuilder`; existing-device
/// fragments retain the identity read from libvirt. That is not tidiness:
/// libvirt matches an update or detach against the identity the fragment
/// describes, so reconstructing an existing device can stop matching the one
/// it means to act on — and libvirt's answer is either a puzzling "device not
/// found" or, worse, a match on the wrong one. Fragments live in the core
/// library for the reason the builder gives: the driver that sends them links
/// a hypervisor SDK and has no unit tests.
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
    /// The complete device must be the one read from the live domain with
    /// `DomainMemoryInventory`. libvirt adds identity to it when the domain is
    /// defined (notably `<alias>` and `<address>`); rebuilding the fragment
    /// from its sizing fields drops that identity and makes the update match
    /// nothing. This mirrors `virsh update-memory-device`: preserve the device
    /// and change only `<requested>`.
    public static func memoryDevice(
        _ device: DomainMemoryLayout.VirtioMem, requestedBytes: Int64
    ) throws -> String {
        var node = try DomainXMLNode.parse(device.deviceXML)
        guard node.name == "memory", node.attribute("model") == "virtio-mem" else {
            throw DomainInventoryError.unparseable(
                "the selected memory device is not <memory model='virtio-mem'>")
        }

        var changedRequested = false
        guard
            node.editChild(
                named: "target",
                { target in
                    changedRequested = target.editChild(named: "requested") { requested in
                        requested.setAttribute("unit", "KiB")
                        requested.setText(String(requestedBytes / 1024))
                    }
                }), changedRequested
        else {
            throw DomainInventoryError.unparseable(
                "the virtio-mem device declares no <target><requested>")
        }
        return node.render()
    }
}
