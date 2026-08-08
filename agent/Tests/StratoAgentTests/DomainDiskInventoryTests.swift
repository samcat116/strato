import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reading a running domain's disks back, and the fragments sent to change them
/// (STR-134).
///
/// `LibvirtService` keeps no model of a domain, so hot-plug decides everything
/// from the document libvirtd hands back — which target names are taken, and
/// which disk carries a given volume. Both answers are unverifiable at runtime:
/// a wrong target silently shadows an existing disk, and a wrong serial match
/// unplugs a live disk out from under a guest. That is what these assert.
///
/// The fixture is shaped like real `virsh dumpxml` output rather than like the
/// builder's own: libvirtd echoes a domain back with `<alias>`, `<address>` and
/// controllers the builder never wrote, and a parser that only ever saw its own
/// output would not have to cope with any of it.
@Suite("libvirt domain disk inventory")
struct DomainDiskInventoryTests {

    static let dataVolumeId = "6b1c0a5e-7d2f-4a83-9e10-5c4b3a2d1f00"

    static let runningDomain = """
        <domain type='kvm' id='7'>
          <name>0f9ea1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b</name>
          <uuid>0f9ea1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b</uuid>
          <memory unit='KiB'>2097152</memory>
          <currentMemory unit='KiB'>2097152</currentMemory>
          <vcpu placement='static'>2</vcpu>
          <os>
            <type arch='x86_64' machine='pc-q35-9.0'>hvm</type>
            <nvram format='qcow2'>/var/lib/strato/vms/vm/nvram.fd</nvram>
          </os>
          <devices>
            <emulator>/usr/bin/qemu-system-x86_64</emulator>
            <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2'/>
              <source file='/var/lib/strato/vms/vm/disk.qcow2' index='3'/>
              <backingStore/>
              <target dev='vda' bus='virtio'/>
              <boot order='1'/>
              <alias name='virtio-disk0'/>
              <address type='pci' domain='0x0000' bus='0x04' slot='0x00' function='0x0'/>
            </disk>
            <disk type='file' device='disk'>
              <driver name='qemu' type='raw'/>
              <source file='/var/lib/strato/vms/vm/cloud-init.iso' index='2'/>
              <target dev='vdb' bus='virtio'/>
              <readonly/>
              <alias name='virtio-disk1'/>
            </disk>
            <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2'/>
              <source file='/var/lib/strato/volumes/data.qcow2' index='1'/>
              <target dev='vdd' bus='virtio'/>
              <serial>vol-\(dataVolumeId)</serial>
              <alias name='virtio-disk3'/>
            </disk>
            <controller type='pci' index='0' model='pcie-root'/>
            <controller type='pci' index='1' model='pcie-root-port'/>
            <memballoon model='virtio' freePageReporting='on'/>
          </devices>
        </domain>
        """

    // MARK: - Reading the document

    @Test("every disk is read, with the identity a detach resolves by")
    func readsDisks() throws {
        let disks = try DomainDiskInventory.disks(inDomainXML: Self.runningDomain)

        #expect(disks.map(\.target) == ["vda", "vdb", "vdd"])
        #expect(disks.map(\.driverType) == ["qcow2", "raw", "qcow2"])
        #expect(disks[0].sourceFile == "/var/lib/strato/vms/vm/disk.qcow2")
        // Only the volume-backed disk carries one; the boot disk and the seed
        // ISO belong to no volume.
        #expect(disks.map(\.serial) == [nil, nil, "vol-\(Self.dataVolumeId)"])
    }

    /// The whole point of the serial: `deviceName` is a per-VM label two
    /// volumes can share, and unplugging "whichever answers to it" pulls a live
    /// disk out from under a guest (STR-129).
    @Test("a volume resolves to exactly its own disk")
    func findsVolume() throws {
        let disks = try DomainDiskInventory.disks(inDomainXML: Self.runningDomain)

        #expect(DomainDiskInventory.disk(forVolume: Self.dataVolumeId, in: disks)?.target == "vdd")
        // Uppercase reaches here from an API that echoed a UUID back; the
        // identity is minted lowercased on both sides.
        #expect(
            DomainDiskInventory.disk(forVolume: Self.dataVolumeId.uppercased(), in: disks)?.target
                == "vdd")
        // A volume this domain does not have is nil, never a near miss.
        #expect(
            DomainDiskInventory.disk(
                forVolume: "11111111-2222-3333-4444-555555555555", in: disks) == nil)
    }

    /// A document that cannot be read must not read as "this domain has no
    /// disks": that answer would let a hot-plug pick `vda` on a VM whose boot
    /// disk is already there.
    ///
    /// The truncated case is the one worth pinning. `XMLParser.parse()` answers
    /// **true** for a document that simply stops early — reporting it only
    /// through `parserError` — so a return-value check alone would let half a
    /// reply through as a complete answer.
    @Test(
        "an unreadable document is an error, not an empty domain",
        arguments: ["<domain><devices><disk>", "<domain", "not xml at all", "", "<domain><a></b></domain>"])
    func unparseableThrows(_ xml: String) {
        #expect(throws: DomainInventoryError.self) {
            try DomainDiskInventory.disks(inDomainXML: xml)
        }
    }

    /// `<domainsnapshot>` carries a `<disks><disk name='vda'/>` list of its own,
    /// where a `<disk>` means something else entirely and has no target at all.
    @Test("only disks under <devices> count")
    func ignoresForeignDisks() throws {
        let xml = """
            <domain type='kvm'>
              <name>vm</name>
              <disks>
                <disk name='vda' snapshot='internal'/>
              </disks>
              <devices>
                <disk type='file' device='disk'>
                  <source file='/disk.qcow2'/>
                  <target dev='vda' bus='virtio'/>
                </disk>
              </devices>
            </domain>
            """
        #expect(try DomainDiskInventory.disks(inDomainXML: xml).map(\.target) == ["vda"])
    }

    // MARK: - Choosing a target name

    /// Lowest-free rather than next-after-highest, so a VM that has had volumes
    /// come and go does not walk its names off toward `vdz` — the fixture's gap
    /// at `vdc` is exactly that history.
    @Test("the next target name fills the lowest gap")
    func nextTarget() throws {
        let disks = try DomainDiskInventory.disks(inDomainXML: Self.runningDomain)
        #expect(DomainDiskInventory.nextTargetDevice(after: disks) == "vdc")

        #expect(DomainDiskInventory.nextTargetDevice(after: []) == "vda")
        #expect(
            DomainDiskInventory.nextTargetDevice(after: [DomainDisk(target: "vda")]) == "vdb")
        // Past the single-letter names, where the sequence stops being an
        // alphabet and becomes bijective base-26.
        let full = (0..<26).map { DomainDisk(target: DomainXMLBuilder.targetDeviceName(index: $0)) }
        #expect(DomainDiskInventory.nextTargetDevice(after: full) == "vdaa")
    }

    // MARK: - Fragments

    @Test("a hot-plugged disk is described exactly as a create-time one")
    func hotplugFragment() {
        let xml = DomainDeviceXML.hotplugDisk(
            path: "/var/lib/strato/volumes/data.qcow2", format: .qcow2, target: "vdc",
            readonly: false, volumeId: Self.dataVolumeId)

        #expect(
            xml == """
                <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2'/>
                  <source file='/var/lib/strato/volumes/data.qcow2'/>
                  <target dev='vdc' bus='virtio'/>
                  <serial>vol-\(Self.dataVolumeId)</serial>
                </disk>

                """)
        // A disk plugged into a running guest cannot change what that guest
        // booted from, and an order here would collide with the boot disk's.
        #expect(!xml.contains("<boot"))
        // libvirt picks a free root port; pinning one would collide with the
        // addresses it already assigned.
        #expect(!xml.contains("<address"))
    }

    @Test("a read-only volume stays read-only when hot-plugged")
    func readonlyHotplugFragment() {
        let xml = DomainDeviceXML.hotplugDisk(
            path: "/volumes/reference.raw", format: .raw, target: "vdz", readonly: true,
            volumeId: Self.dataVolumeId)
        #expect(xml.contains("<driver name='qemu' type='raw'/>"))
        #expect(xml.contains("<readonly/>"))
    }

    /// libvirt resolves a disk detach by `<target dev>`; the source and driver
    /// are echoed back so the fragment parses as the same kind of disk rather
    /// than as a bare stub.
    @Test("a detach names the disk libvirt already has")
    func detachFragment() throws {
        let disks = try DomainDiskInventory.disks(inDomainXML: Self.runningDomain)
        let disk = try #require(DomainDiskInventory.disk(forVolume: Self.dataVolumeId, in: disks))

        #expect(
            DomainDeviceXML.detachDisk(disk) == """
                <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2'/>
                  <source file='/var/lib/strato/volumes/data.qcow2'/>
                  <target dev='vdd' bus='virtio'/>
                </disk>

                """)
    }

    /// Every attribute of a detach fragment is echoed from what libvirt
    /// reported, never asserted. Strato writes only file-backed virtio disks,
    /// so asserting `type='file'`/`device='disk'`/`bus='virtio'` holds today —
    /// and stops holding the moment a disk of another shape reaches a domain,
    /// with libvirt matching nothing (or the wrong device) rather than failing
    /// legibly.
    @Test("a detach describes the disk's real shape, not the common one")
    func detachFragmentIsDerived() throws {
        let xml = """
            <domain type='kvm'>
              <name>vm</name>
              <devices>
                <disk type='block' device='lun'>
                  <driver name='qemu' type='raw'/>
                  <source dev='/dev/sdb'/>
                  <target dev='sda' bus='scsi'/>
                  <serial>vol-\(Self.dataVolumeId)</serial>
                </disk>
              </devices>
            </domain>
            """
        let disks = try DomainDiskInventory.disks(inDomainXML: xml)
        let disk = try #require(DomainDiskInventory.disk(forVolume: Self.dataVolumeId, in: disks))

        #expect(disk.type == "block")
        #expect(disk.device == "lun")
        #expect(disk.bus == "scsi")
        #expect(
            DomainDeviceXML.detachDisk(disk) == """
                <disk type='block' device='lun'>
                  <driver name='qemu' type='raw'/>
                  <target dev='sda' bus='scsi'/>
                </disk>

                """)
    }

    /// Paths reach here from the control plane, and this is the first place one
    /// lands somewhere `&` is structural.
    @Test("a hostile path still produces a parseable fragment")
    func fragmentEscaping() {
        let xml = DomainDeviceXML.hotplugDisk(
            path: "/volumes/a & b/<disk>.qcow2", format: .qcow2, target: "vdc", readonly: false,
            volumeId: Self.dataVolumeId)
        #expect(xml.contains("/volumes/a &amp; b/&lt;disk&gt;.qcow2"))
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse() && parser.parserError == nil)
    }
}
