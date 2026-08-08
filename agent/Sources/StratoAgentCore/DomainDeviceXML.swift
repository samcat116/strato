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

    /// A `<disk>` to hot-plug, naming its volume in `<serial>` so a later
    /// detach can find exactly this disk.
    ///
    /// No `<boot order>`: a disk plugged into a running guest cannot change
    /// what that guest booted from, and emitting one would collide with the
    /// order the create-time document already gave the boot disk.
    ///
    /// No `<address>` either — libvirt picks a free PCIe root port, of which
    /// the document reserves at least `DomainXMLBuilder.spareHotplugPorts`.
    public static func hotplugDisk(
        path: String, format: DiskFormat, target: String, readonly: Bool, volumeId: String
    ) -> String {
        DomainXMLBuilder.diskNode(
            path: path, format: format.rawValue, target: target, readonly: readonly,
            bootOrder: nil, volumeId: volumeId
        ).render()
    }

    /// The `<disk>` identifying an already-attached disk, for a hot-unplug.
    ///
    /// libvirt resolves a disk detach by `<target dev>`, but it parses the
    /// whole fragment first — so every attribute here is **echoed back from
    /// what libvirt reported**, never asserted. Every disk this driver writes is
    /// a file-backed virtio disk, so hardcoding `type='file'`, `device='disk'`
    /// and `bus='virtio'` would hold today and stop holding the moment a
    /// `type='block'` volume or another bus reaches a domain — and the failure
    /// would be libvirt matching nothing, or the wrong device, rather than a
    /// legible error. Deriving the fragment is the rule this whole type states;
    /// this is the one place it was not being followed.
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
