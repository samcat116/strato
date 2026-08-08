import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The sizing a domain was *defined* with, which is what an online resize has
/// to work against (STR-134).
///
/// `QEMUService` keeps the equivalent in `vmSpawnSizing`, a dictionary the
/// agent loses on every restart; here the domain document is the record. Every
/// number below is load-bearing arithmetic: a `<requested>` that is not a whole
/// number of blocks is refused outright by QEMU, and one computed from the
/// wrong base silently gives the guest the wrong amount of memory.
@Suite("libvirt domain memory inventory")
struct DomainMemoryInventoryTests {

    /// Written out as `Int64` rather than as literal arithmetic inside each
    /// `#expect`: swift-testing captures an optional comparison's operands
    /// type-erased, so `Int64?` measured against an untyped `2 * 1024 * 1024`
    /// compares an `Int64` with an `Int` and fails while printing two identical
    /// numbers.
    static let kib: Int64 = 1024
    static let mib: Int64 = 1024 * 1024
    static let gib: Int64 = 1024 * 1024 * 1024

    static func domain(_ devices: String, memoryKiB: Int = 8_388_608, currentKiB: Int = 2_097_152)
        -> String
    {
        """
        <domain type='kvm' id='7'>
          <name>vm</name>
          <maxMemory slots='1' unit='KiB'>\(memoryKiB)</maxMemory>
          <memory unit='KiB'>\(memoryKiB)</memory>
          <currentMemory unit='KiB'>\(currentKiB)</currentMemory>
          <vcpu placement='static' current='2'>8</vcpu>
          <devices>
            <disk type='file' device='disk'>
              <target dev='vda' bus='virtio'/>
            </disk>
            <memballoon model='virtio' freePageReporting='on'/>
        \(devices)
          </devices>
        </domain>
        """
    }

    static let virtioMemDevice = """
              <memory model='virtio-mem'>
                <target>
                  <size unit='KiB'>6291456</size>
                  <node>0</node>
                  <block unit='KiB'>2048</block>
                  <requested unit='KiB'>1048576</requested>
                  <current unit='KiB'>1048576</current>
                </target>
                <address type='pci' domain='0x0000' bus='0x05' slot='0x00' function='0x0'/>
              </memory>
        """

    // MARK: - Reading the document

    @Test("a domain with headroom reports its device, not its spec")
    func readsVirtioMem() throws {
        let layout = try DomainMemoryInventory.memoryLayout(
            inDomainXML: Self.domain(Self.virtioMemDevice))

        #expect(layout.bootBytes == 2 * Self.gib)
        #expect(layout.maximumBytes == 8 * Self.gib)
        #expect(layout.virtioMem?.sizeBytes == 6 * Self.gib)
        #expect(layout.virtioMem?.blockBytes == 2 * Self.mib)
        #expect(layout.virtioMem?.requestedBytes == 1 * Self.gib)
    }

    /// `<memory>` under `<domain>` is the domain's total and `<memory>` under
    /// `<devices>` is a device; reading one as the other would make a VM with
    /// no headroom look like it had 8 GiB of it.
    @Test("a domain with no headroom reports no device")
    func readsWithoutVirtioMem() throws {
        let layout = try DomainMemoryInventory.memoryLayout(
            inDomainXML: Self.domain("", memoryKiB: 2_097_152))

        #expect(layout.bootBytes == 2 * Self.gib)
        #expect(layout.maximumBytes == 2 * Self.gib)
        #expect(layout.virtioMem == nil)
    }

    /// A memory device that is not virtio-mem (a plain DIMM) is not one this
    /// resize can drive, and claiming it would send an update fragment that
    /// matches nothing.
    @Test("only a virtio-mem device counts")
    func ignoresOtherMemoryDevices() throws {
        let dimm = """
                  <memory model='dimm'>
                    <target>
                      <size unit='KiB'>1048576</size>
                      <node>0</node>
                    </target>
                  </memory>
            """
        #expect(try DomainMemoryInventory.memoryLayout(inDomainXML: Self.domain(dimm)).virtioMem == nil)
    }

    @Test("a document with no memory at all is an error")
    func missingMemoryThrows() {
        #expect(throws: DomainInventoryError.self) {
            try DomainMemoryInventory.memoryLayout(inDomainXML: "<domain><name>vm</name></domain>")
        }
        #expect(throws: DomainInventoryError.self) {
            try DomainMemoryInventory.memoryLayout(inDomainXML: "<domain><memory>")
        }
    }

    /// libvirt's own `dumpxml` always writes KiB, which is the default here —
    /// but the schema allows the rest, and a document that took another path
    /// through libvirt is still one this has to read rather than misread by a
    /// factor of 1024.
    @Test("declared units are honoured")
    func units() {
        #expect(DomainMemoryInventory.bytes("1024", unit: nil) == 1024 * Self.kib)
        #expect(DomainMemoryInventory.bytes("1024", unit: "KiB") == 1024 * Self.kib)
        #expect(DomainMemoryInventory.bytes("2048", unit: "b") == 2048)
        #expect(DomainMemoryInventory.bytes("2", unit: "GiB") == 2 * Self.gib)
        #expect(DomainMemoryInventory.bytes("2", unit: "GB") == 2_000_000_000)
        // Neither a unit this build knows nor a number: reported as absent
        // rather than as a guess, which the caller turns into a parse error.
        #expect(DomainMemoryInventory.bytes("2", unit: "parsecs") == nil)
        #expect(DomainMemoryInventory.bytes("lots", unit: "KiB") == nil)
        #expect(DomainMemoryInventory.bytes("\(Int64.max)", unit: "GiB") == nil)
    }

    // MARK: - The resize arithmetic

    /// virtio-mem can only give back what it plugged in, so the boot size is a
    /// floor; the device's own size is the ceiling; and everything between
    /// rounds **down** to a whole block, because QEMU refuses a request that is
    /// not a multiple of one rather than rounding it.
    @Test("the requested size is clamped to the floor, the ceiling and the block")
    func requestedSize() throws {
        let layout = try DomainMemoryInventory.memoryLayout(
            inDomainXML: Self.domain(Self.virtioMemDevice))
        let gib = Self.gib

        // Grow from the 2 GiB boot size to 5 GiB: three of the six available.
        #expect(layout.requestedBytes(forTotal: 5 * gib) == 3 * gib)
        // Back to the boot size is a request for nothing, not a negative one.
        #expect(layout.requestedBytes(forTotal: 2 * gib) == 0)
        #expect(layout.requestedBytes(forTotal: gib) == 0)
        // Past the device's size is the whole device — libvirt reports the
        // ceiling being exceeded, this does not pretend to.
        #expect(layout.requestedBytes(forTotal: 100 * gib) == 6 * gib)
        // A target one byte above a block boundary plugs in the boundary.
        #expect(layout.requestedBytes(forTotal: 2 * gib + 2 * Self.mib + 1) == 2 * Self.mib)
        #expect(layout.requestedBytes(forTotal: 2 * gib + 1) == 0)
    }

    @Test("a domain with no memory device can request nothing")
    func requestedSizeWithoutDevice() throws {
        let layout = try DomainMemoryInventory.memoryLayout(
            inDomainXML: Self.domain("", memoryKiB: 2_097_152))
        #expect(layout.requestedBytes(forTotal: 4 * Self.gib) == nil)
    }

    /// The fragment libvirt matches an update against. It has to reproduce the
    /// device's identity — model, node, size and block — or it describes a
    /// different device and the update finds nothing.
    @Test("the update fragment reproduces the device it means to grow")
    func memoryFragment() {
        let xml = DomainDeviceXML.memoryDevice(
            sizeBytes: 6 * Self.gib, blockBytes: 2 * Self.mib, requestedBytes: 3 * Self.gib)

        #expect(
            xml == """
                <memory model='virtio-mem'>
                  <target>
                    <size unit='KiB'>6291456</size>
                    <node>0</node>
                    <block unit='KiB'>2048</block>
                    <requested unit='KiB'>3145728</requested>
                  </target>
                </memory>

                """)
    }
}
