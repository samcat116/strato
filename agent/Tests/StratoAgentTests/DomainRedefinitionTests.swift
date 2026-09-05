import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

/// The widening pass a boot runs over a stopped domain (STR-187).
///
/// Two properties are being defended here and they pull in opposite directions.
/// The pass has to *change* the two ceilings a VM would otherwise carry for
/// life — and it has to change **nothing else**, because what it produces goes
/// straight to `virDomainDefineXML` and anything it drops is hardware a VM
/// silently loses at its next power cycle. So the fidelity tests below matter as
/// much as the widening ones: `DomainXMLNode.parse` is the half of this that has
/// no equivalent anywhere else in the agent, and a document is only as safe to
/// edit as it is to read.
///
/// The fixtures are **defined** documents, not the builder's output: they carry
/// the `<address>` elements libvirt's own allocator writes at define time, which
/// is what the port arithmetic reads. `DomainXMLLibvirtTests` is where the same
/// question is put to a real daemon.
@Suite("libvirt domain redefinition")
struct DomainRedefinitionTests {

    // MARK: - Fixtures

    static let gib: Int64 = 1024 * 1024 * 1024

    static func spec(
        memoryBytes: Int64 = 2 * gib, maxMemoryBytes: Int64? = nil, maxCpus: Int = 8
    ) -> VMSpec {
        VMSpec(
            cpus: 2, maxCpus: maxCpus, memoryBytes: memoryBytes, maxMemoryBytes: maxMemoryBytes,
            boot: .disk(firmware: nil))
    }

    /// A domain as libvirt describes it once defined: PCI addresses assigned,
    /// root ports numbered, memory split across `<maxMemory>`/`<memory>`/
    /// `<currentMemory>` with a NUMA cell holding the boot size.
    ///
    /// - Parameters:
    ///   - ports: every `pcie-root-port` index the domain declares
    ///   - occupied: the ports a device sits in, in order. The domain's own five
    ///     PCI devices — boot disk, virtio-serial, NIC, memballoon and (where it
    ///     has headroom) virtio-mem — take the first five (four without it, a
    ///     domain with no headroom having no memory device); every further entry
    ///     becomes a hot-plugged data disk, which is how a VM fills its spares
    ///     up in the first place.
    ///   - headroomGiB: the virtio-mem region, or nil for a domain defined with
    ///     no memory device at all
    static func definedDomain(
        ports: [Int] = [1, 2, 3, 4, 5, 6, 7, 8, 9],
        occupied: [Int] = [1, 2, 3, 4, 5],
        bootGiB: Int64 = 2,
        headroomGiB: Int64? = 6
    ) -> String {
        let boot = bootGiB * gib / 1024
        let total = boot + (headroomGiB ?? 0) * gib / 1024
        var document = "<domain type='kvm'>\n"
        document += "  <name>vm-under-test</name>\n"
        document += "  <uuid>0f9ea1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b</uuid>\n"
        if headroomGiB != nil {
            document += "  <maxMemory slots='1' unit='KiB'>\(total)</maxMemory>\n"
        }
        document += "  <memory unit='KiB'>\(total)</memory>\n"
        document += "  <currentMemory unit='KiB'>\(boot)</currentMemory>\n"
        document += "  <vcpu placement='static' current='2'>8</vcpu>\n"
        document += "  <os>\n"
        document += "    <type arch='x86_64' machine='pc-q35-9.1'>hvm</type>\n"
        document += "    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>\n"
        document += "    <nvram format='qcow2'>/var/lib/strato/vms/vm/nvram.fd</nvram>\n"
        document += "  </os>\n"
        document += "  <features>\n    <acpi/>\n    <apic/>\n  </features>\n"
        document += "  <cpu mode='host-passthrough' check='none'>\n"
        if headroomGiB != nil {
            document += "    <numa>\n"
            document += "      <cell id='0' cpus='0-7' memory='\(boot)' unit='KiB'/>\n"
            document += "    </numa>\n"
        }
        document += "  </cpu>\n"
        document += "  <clock offset='utc'/>\n"
        document += "  <on_poweroff>destroy</on_poweroff>\n"
        document += "  <on_reboot>restart</on_reboot>\n"
        document += "  <on_crash>destroy</on_crash>\n"
        document += "  <devices>\n"
        document += "    <emulator>/usr/bin/qemu-system-x86_64</emulator>\n"
        document += "    <disk type='file' device='disk'>\n"
        document += "      <driver name='qemu' type='qcow2'/>\n"
        document += "      <source file='/var/lib/strato/vms/vm/disk.qcow2'/>\n"
        document += "      <target dev='vda' bus='virtio'/>\n"
        document += address(bus: bus(occupied, 0), indent: 6)
        document += "    </disk>\n"
        // The disks a hot-plug added, which is what puts a VM in reach of its
        // ceiling in the first place.
        for (offset, port) in occupied.dropFirst(headroomGiB == nil ? 4 : 5).enumerated() {
            document += "    <disk type='file' device='disk'>\n"
            document += "      <driver name='qemu' type='qcow2'/>\n"
            document += "      <source file='/var/lib/strato/volumes/data\(offset).qcow2'/>\n"
            document += "      <target dev='vd\(Character(UnicodeScalar(UInt8(98 + offset))))' bus='virtio'/>\n"
            document += address(bus: port, indent: 6)
            document += "    </disk>\n"
        }
        document += "    <controller type='pci' index='0' model='pcie-root'/>\n"
        for (offset, port) in ports.enumerated() {
            document += "    <controller type='pci' index='\(port)' model='pcie-root-port'>\n"
            document += "      <model name='pcie-root-port'/>\n"
            // Every root port hangs off `pcie-root` itself — bus 0x00, which is
            // never an occupied port. Getting this wrong in the fixture would
            // make the pass under test look like it counted correctly.
            document += "      <target chassis='\(port)' port='0x\(String(8 + offset, radix: 16))'/>\n"
            document += "      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' "
            document += "function='0x\(offset)'/>\n"
            document += "    </controller>\n"
        }
        document += "    <controller type='virtio-serial' index='0'>\n"
        document += address(bus: bus(occupied, 1), indent: 6)
        document += "    </controller>\n"
        document += "    <interface type='ethernet'>\n"
        document += "      <mac address='52:54:00:12:34:56'/>\n"
        document += "      <target dev='tap0f9ea1b2' managed='no'/>\n"
        document += "      <model type='virtio'/>\n"
        document += address(bus: bus(occupied, 2), indent: 6)
        document += "    </interface>\n"
        document += "    <serial type='unix'>\n"
        document += "      <source mode='bind' path='/var/lib/strato/vms/vm/serial.sock'/>\n"
        document += "      <target type='isa-serial' port='0'>\n"
        document += "        <model name='isa-serial'/>\n"
        document += "      </target>\n"
        document += "    </serial>\n"
        document += "    <video>\n      <model type='none'/>\n    </video>\n"
        document += "    <memballoon model='virtio' freePageReporting='on'>\n"
        document += address(bus: bus(occupied, 3), indent: 6)
        document += "    </memballoon>\n"
        if let headroomGiB {
            document += "    <memory model='virtio-mem'>\n"
            document += "      <target>\n"
            document += "        <size unit='KiB'>\(headroomGiB * gib / 1024)</size>\n"
            document += "        <node>0</node>\n"
            document += "        <block unit='KiB'>2048</block>\n"
            document += "        <requested unit='KiB'>0</requested>\n"
            document += "      </target>\n"
            document += address(bus: bus(occupied, 4), indent: 6)
            document += "    </memory>\n"
        }
        document += "  </devices>\n"
        document += "</domain>\n"
        return document
    }

    /// The bus the `n`th PCI device sits on, or `pcie-root` where the caller
    /// named fewer occupied ports than the domain has devices.
    private static func bus(_ occupied: [Int], _ n: Int) -> Int {
        occupied.count > n ? occupied[n] : 0
    }

    private static func address(bus: Int, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return pad + "<address type='pci' domain='0x0000' bus='0x\(hex(bus))' slot='0x00' function='0x0'/>\n"
    }

    private static func hex(_ value: Int) -> String {
        let text = String(value, radix: 16)
        return text.count == 1 ? "0" + text : text
    }

    static func widening(_ document: String, spec: VMSpec) throws -> DomainRedefinition.Widening {
        try DomainRedefinition.widening(
            forInactiveDomainXML: document, spec: spec, architecture: .x86_64)
    }

    // MARK: - Reading a document back without losing any of it

    /// The property the whole pass rests on: a document read and re-emitted is
    /// the same document. Asserted against the goldens because those are the
    /// documents the agent really defines — a fixture written for this test
    /// could only prove the parser agrees with whoever wrote the fixture.
    @Test("every golden survives a parse and a render unchanged", arguments: DomainXMLBuilderTests.scenarios)
    func goldensRoundTrip(_ scenario: DomainXMLBuilderTests.Scenario) throws {
        let original = try DomainXMLBuilder.build(scenario.input)
        let tree = try DomainXMLNode.parse(original)

        // Element count and character data compared against the *text*, not
        // against a second parse: a parser that silently dropped an element
        // would agree with itself perfectly.
        #expect(elementCount(tree) == original.components(separatedBy: "<").count - 1 - closingTags(original))
        #expect(allText(tree) == textValues(original))

        // And the render is stable: parsing it back yields the same tree, so
        // the transform's output is itself re-readable — which is what makes a
        // second widening pass over an already-widened domain a no-op rather
        // than a rewrite.
        #expect(try DomainXMLNode.parse(tree.render()) == tree)
    }

    @Test("a defined domain's document survives a parse and a render unchanged")
    func definedDomainRoundTrips() throws {
        let original = Self.definedDomain()
        let tree = try DomainXMLNode.parse(original)
        #expect(allText(tree) == textValues(original))
        #expect(try DomainXMLNode.parse(tree.render()) == tree)
    }

    @Test("character data that needs escaping comes back exactly")
    func escapingRoundTrips() throws {
        let document = """
            <domain type='kvm'>
              <name>a &amp; b</name>
              <devices>
                <disk type='file'>
                  <source file='/vol/&lt;odd&gt; &quot;name&quot;.qcow2'/>
                </disk>
              </devices>
            </domain>
            """
        let tree = try DomainXMLNode.parse(document)
        #expect(tree.child(named: "name")?.text == "a & b")
        #expect(
            tree.child(named: "devices")?.child(named: "disk")?.child(named: "source")?
                .attribute("file") == "/vol/<odd> \"name\".qcow2")
        #expect(try DomainXMLNode.parse(tree.render()) == tree)
    }

    @Test("a stopped domain replaces stale direct-I/O attributes with the reprobed fallback")
    func blockPolicyIsReprobedBeforeBoot() throws {
        let volumeId = UUID()
        let document = """
            <domain type='kvm'>
              <name>stopped-vm</name>
              <devices>
                <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2' cache='none' io='io_uring' discard='unmap' detect_zeroes='unmap' queues='8' custom='keep'/>
                  <source file='/volumes/data.qcow2'/>
                  <target dev='vdb' bus='virtio'/>
                  <iotune><total_iops_sec>500</total_iops_sec></iotune>
                  <serial>vol-\(volumeId.uuidString)</serial>
                </disk>
              </devices>
            </domain>
            """
        let fallback = AppliedBlockDevicePolicy(
            active: true, requestedMode: .direct, queueCount: 2,
            fallbackReason: "direct I/O is no longer supported")
        let volume = VolumeSpec(
            volumeId: volumeId, deviceName: .disk(0),
            attachment: .file(path: "/volumes/data.qcow2", format: .qcow2),
            ioLimits: VolumeIOLimits(iopsTotal: 500), blockMode: .direct,
            appliedBlockPolicy: fallback)

        let candidate = try DomainRedefinition.applyingBlockPolicies(
            toInactiveDomainXML: document, volumes: [volume])
        let rewritten = try #require(candidate)
        let domain = try DomainXMLNode.parse(rewritten)
        let disk = try #require(domain.child(named: "devices")?.child(named: "disk"))
        let driver = try #require(disk.child(named: "driver"))

        #expect(driver.attribute("cache") == nil)
        #expect(driver.attribute("io") == nil)
        #expect(driver.attribute("discard") == nil)
        #expect(driver.attribute("detect_zeroes") == nil)
        #expect(driver.attribute("queues") == "2")
        #expect(driver.attribute("custom") == "keep")
        #expect(disk.child(named: "iotune")?.child(named: "total_iops_sec")?.text == "500")
        #expect(
            try DomainRedefinition.applyingBlockPolicies(
                toInactiveDomainXML: rewritten, volumes: [volume]) == nil)
    }

    /// Mixed content is the one shape `render` cannot express, so reading it is
    /// refused rather than silently flattened — a redefine that dropped it would
    /// be redefining a VM's hardware.
    @Test("mixed content is refused rather than dropped")
    func mixedContentIsRefused() {
        #expect(throws: DomainInventoryError.self) {
            try DomainXMLNode.parse("<domain>text<devices/></domain>")
        }
    }

    @Test("a truncated document is refused")
    func truncatedDocumentIsRefused() {
        #expect(throws: DomainInventoryError.self) {
            try DomainXMLNode.parse("<domain type='kvm'><devices>")
        }
    }

    // MARK: - IMDS bootstrap migration

    @Test("a legacy x86 IMDS domain gains the NoCloud network hint")
    func legacyIMDSDomainGainsBootstrapHint() throws {
        let original = Self.definedDomain()
        let repaired = try #require(
            try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: original,
                metadataSource: .imds,
                architecture: .x86_64))
        let before = try DomainXMLNode.parse(original)
        let after = try DomainXMLNode.parse(repaired)

        let sysinfo = try #require(
            after.children.first { $0.name == "sysinfo" && $0.attribute("type") == "smbios" })
        let serial = try #require(
            sysinfo.child(named: "system")?.children.first {
                $0.name == "entry" && $0.attribute("name") == "serial"
            })
        #expect(serial.text == "ds=nocloud;dsmode=net")
        #expect(after.child(named: "os")?.child(named: "smbios")?.attribute("mode") == "sysinfo")

        // The migration is as narrow as the builder's new requirement. In
        // particular, every device and host-resolved path survives unchanged.
        #expect(after.child(named: "devices") == before.child(named: "devices"))
        #expect(after.child(named: "name") == before.child(named: "name"))
        #expect(after.child(named: "uuid") == before.child(named: "uuid"))
    }

    @Test("the IMDS bootstrap migration is idempotent")
    func imdsBootstrapMigrationIsIdempotent() throws {
        let first = try #require(
            try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: Self.definedDomain(),
                metadataSource: .imds,
                architecture: .x86_64))
        let second = try DomainRedefinition.addingIMDSBootstrapHint(
            toInactiveDomainXML: first,
            metadataSource: .imds,
            architecture: .x86_64)

        #expect(second == nil)
    }

    @Test("ISO and ARM domains do not receive the x86 IMDS hint")
    func unrelatedDomainsDoNotGainBootstrapHint() throws {
        let document = Self.definedDomain()
        #expect(
            try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: document,
                metadataSource: .iso,
                architecture: .x86_64) == nil)
        #expect(
            try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: document,
                metadataSource: .imds,
                architecture: .arm64) == nil)
    }

    @Test("an existing different SMBIOS identity is refused")
    func conflictingSMBIOSIsRefused() {
        let document = Self.definedDomain().replacingOccurrences(
            of: "  <os>\n",
            with: """
                  <sysinfo type='smbios'>
                    <system>
                      <entry name='serial'>operator-owned</entry>
                    </system>
                  </sysinfo>
                  <os>
                """)

        #expect(throws: DomainInventoryError.self) {
            try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: document,
                metadataSource: .imds,
                architecture: .x86_64)
        }
    }

    // MARK: - Spare root ports

    @Test("a domain whose spare ports are all taken gets four more")
    func exhaustedPortsAreToppedUp() throws {
        // Nine ports, all nine occupied — the state a VM reaches once four
        // volumes have been hot-plugged into its four spares.
        let document = Self.definedDomain(
            ports: Array(1...9), occupied: Array(1...9))
        let widening = try Self.widening(document, spec: Self.spec(maxMemoryBytes: 8 * Self.gib))

        #expect(widening.addedHotplugPorts == DomainXMLBuilder.spareHotplugPorts)
        #expect(widening.memoryCeilingBytes == nil)
        #expect(widening.refusals.isEmpty)
        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(rootPortIndexes(widened) == Array(1...13))
    }

    @Test("a domain that still has its spare ports is left alone")
    func freePortsNeedNoWidening() throws {
        let widening = try Self.widening(
            Self.definedDomain(), spec: Self.spec(maxMemoryBytes: 8 * Self.gib))

        #expect(widening.xml == nil)
        #expect(widening.addedHotplugPorts == 0)
        #expect(widening.refusals.isEmpty)
    }

    /// Only the shortfall is made up. A VM that has used two of its four spares
    /// gets two back, not four more — otherwise every boot would grow the root
    /// complex a little further.
    @Test("only the missing spares are added")
    func partialShortfallIsToppedUp() throws {
        let document = Self.definedDomain(ports: Array(1...9), occupied: Array(1...7))
        let widening = try Self.widening(document, spec: Self.spec(maxMemoryBytes: 8 * Self.gib))

        #expect(widening.addedHotplugPorts == 2)
        #expect(rootPortIndexes(try DomainXMLNode.parse(#require(widening.xml))) == Array(1...11))
    }

    /// New ports are numbered past every PCI controller index in the document,
    /// including ones that are not root ports — an index libvirt has already
    /// handed out is a document it rejects.
    @Test("new ports are numbered past every index already in use")
    func newPortsAvoidTakenIndexes() throws {
        let document = Self.definedDomain(ports: [2, 30], occupied: [2, 30, 0, 0, 0])
        let widening = try Self.widening(document, spec: Self.spec(maxMemoryBytes: 8 * Self.gib))

        // 31 and 32 fit under the start-time ceiling; the other two do not, and
        // the shortfall is reported rather than left to surface as libvirt's
        // "No more available PCI slots" on a later attach.
        #expect(widening.addedHotplugPorts == 2)
        #expect(rootPortIndexes(try DomainXMLNode.parse(#require(widening.xml))) == [2, 30, 31, 32])
        #expect(widening.refusals.count == 1)
        #expect(widening.refusals[0].contains("\(DomainXMLBuilder.rootPortIndexCeiling)"))
    }

    @Test("a domain already at the port ceiling is refused rather than rewritten")
    func portCeilingIsRefused() throws {
        let document = Self.definedDomain(
            ports: [DomainXMLBuilder.rootPortIndexCeiling],
            occupied: [DomainXMLBuilder.rootPortIndexCeiling, 0, 0, 0, 0])
        let widening = try Self.widening(document, spec: Self.spec(maxMemoryBytes: 8 * Self.gib))

        #expect(widening.xml == nil)
        #expect(widening.addedHotplugPorts == 0)
        #expect(widening.refusals.count == 1)
    }

    // MARK: - Memory headroom

    @Test("a spec asking for more headroom than the domain has raises the ceiling")
    func memoryCeilingIsRaised() throws {
        // Defined at 2 GiB boot + 6 GiB of region; the spec has since grown to
        // 16 GiB with a 32 GiB maximum.
        let document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib))

        #expect(widening.memoryCeilingBytes == 32 * Self.gib)
        #expect(widening.refusals.isEmpty)
        let widened = try DomainXMLNode.parse(#require(widening.xml))

        #expect(widened.child(named: "maxMemory")?.text == "\(32 * Self.gib / 1024)")
        #expect(widened.child(named: "memory")?.text == "\(32 * Self.gib / 1024)")
        // The boot size, in all three places libvirt reads one.
        #expect(widened.child(named: "currentMemory")?.text == "\(16 * Self.gib / 1024)")
        #expect(numaCell(widened)?.attribute("memory") == "\(16 * Self.gib / 1024)")
        #expect(virtioMem(widened)?.child(named: "size")?.text == "\(16 * Self.gib / 1024)")
        // Nothing plugged: the guest now boots at 16 GiB, and a region left
        // plugged on top of that would be the same memory handed over twice.
        #expect(virtioMem(widened)?.child(named: "requested")?.text == "0")
        // The block size is the domain's own, never recomputed.
        #expect(virtioMem(widened)?.child(named: "block")?.text == "2048")
    }

    @Test("a memory region already plugged is reset when the boot size moves up")
    func pluggedRegionIsReset() throws {
        var document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        // As `resizeMemory` leaves a VM grown from 2 GiB to 6 GiB while running.
        document = document.replacingOccurrences(
            of: "<requested unit='KiB'>0</requested>",
            with: "<requested unit='KiB'>\(4 * Self.gib / 1024)</requested>")
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 6 * Self.gib, maxMemoryBytes: 32 * Self.gib))

        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "currentMemory")?.text == "\(6 * Self.gib / 1024)")
        #expect(virtioMem(widened)?.child(named: "requested")?.text == "0")
        #expect(virtioMem(widened)?.child(named: "size")?.text == "\(26 * Self.gib / 1024)")
        #expect(widened.child(named: "memory")?.text == "\(32 * Self.gib / 1024)")
    }

    /// The one case that has to build a topology rather than edit one: libvirt
    /// requires a NUMA cell wherever memory hotplug is enabled, and a VM created
    /// with `maxMemoryBytes == memoryBytes` has neither cell nor device.
    @Test("a domain defined with no headroom gains a device, a ceiling and a cell")
    func headroomIsAddedToADomainThatHadNone() throws {
        let document = Self.definedDomain(
            ports: Array(1...9), occupied: Array(1...9), bootGiB: 4, headroomGiB: nil)
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 4 * Self.gib, maxMemoryBytes: 12 * Self.gib))

        #expect(widening.memoryCeilingBytes == 12 * Self.gib)
        #expect(widening.refusals.isEmpty)
        let widened = try DomainXMLNode.parse(#require(widening.xml))

        #expect(widened.child(named: "maxMemory")?.attribute("slots") == "1")
        #expect(widened.child(named: "maxMemory")?.text == "\(12 * Self.gib / 1024)")
        // Ahead of `<memory>`, which is where libvirt's schema puts it.
        #expect(
            try #require(widened.firstIndex(ofChildNamed: "maxMemory"))
                < #require(widened.firstIndex(ofChildNamed: "memory")))
        // The cell spans the domain's own vCPU maximum, not the spec's.
        #expect(numaCell(widened)?.attribute("cpus") == "0-7")
        #expect(numaCell(widened)?.attribute("memory") == "\(4 * Self.gib / 1024)")
        #expect(virtioMem(widened)?.child(named: "size")?.text == "\(8 * Self.gib / 1024)")
        // The new device is a PCI device and takes a port, so five are wanted
        // rather than four — without that this VM comes back one spare short of
        // every other VM on the host.
        #expect(widening.addedHotplugPorts == DomainXMLBuilder.spareHotplugPorts + 1)
    }

    /// **The stopped-resize case**, and the reason the gate is the total rather
    /// than the region. The control plane raises a stopped VM's recorded
    /// `maxMemory` to its new size, so what reaches the agent has
    /// `maxMemoryBytes == memoryBytes` and asks for no headroom at all — while
    /// the domain, defined at 2 GiB boot plus 6 GiB of region, cannot boot the
    /// 16 GiB it now names. Skipping this is skipping the restart the operator
    /// was told would work.
    @Test("a stopped VM resized past its ceiling boots at the size it was given")
    func stoppedResizePastTheCeilingIsApplied() throws {
        let document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 16 * Self.gib))

        #expect(widening.memoryCeilingBytes == 16 * Self.gib)
        #expect(widening.refusals.isEmpty)
        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "memory")?.text == "\(16 * Self.gib / 1024)")
        #expect(widened.child(named: "currentMemory")?.text == "\(16 * Self.gib / 1024)")
        // No headroom is asked for, so the region goes rather than becoming a
        // device of size zero, which libvirt will not accept.
        #expect(virtioMem(widened) == nil)
        // **And `<maxMemory>` goes with it.** Keeping it leaves memory hot-plug
        // enabled with no device, so libvirt starts QEMU with a `maxmem` equal
        // to the initial size alongside a slot count — which QEMU refuses, and
        // libvirt's own validation does not catch because the NUMA cell is
        // still there. The domain would define and then fail to start.
        #expect(widened.child(named: "maxMemory") == nil)
        // The cell stays: valid without hot-plug, and removing it would change
        // the guest's visible topology on the same boot its size moves.
        #expect(numaCell(widened)?.attribute("memory") == "\(16 * Self.gib / 1024)")
    }

    /// A domain that never had headroom and is only being given a bigger boot
    /// size must not grow a `<maxMemory>` and a NUMA topology it has no use for:
    /// that element is what turns memory hot-plug on.
    @Test("growing a no-headroom domain's boot size adds no hot-plug apparatus")
    func bootSizeGrowsWithoutEnablingHotplug() throws {
        let document = Self.definedDomain(bootGiB: 4, headroomGiB: nil)
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 12 * Self.gib, maxMemoryBytes: 12 * Self.gib))

        #expect(widening.memoryCeilingBytes == 12 * Self.gib)
        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "memory")?.text == "\(12 * Self.gib / 1024)")
        #expect(widened.child(named: "currentMemory")?.text == "\(12 * Self.gib / 1024)")
        #expect(widened.child(named: "maxMemory") == nil)
        #expect(numaCell(widened) == nil)
        #expect(virtioMem(widened) == nil)
    }

    @Test("a spec asking for no more than the domain already has changes nothing")
    func unchangedHeadroomIsLeftAlone() throws {
        let document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        // Grown to 6 GiB inside the ceiling it already has — the ordinary case,
        // which the resize path converges without any of this.
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 6 * Self.gib, maxMemoryBytes: 8 * Self.gib))

        #expect(widening.xml == nil)
        #expect(widening.memoryCeilingBytes == nil)
    }

    /// Never downward. A spec whose ceiling has *fallen* is converged by the
    /// resize path, and deciding at boot time that a guest should come back
    /// holding less is not a decision a document rewrite gets to make.
    @Test("a lowered ceiling is not applied")
    func loweredCeilingIsIgnored() throws {
        let document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 2 * Self.gib, maxMemoryBytes: 4 * Self.gib))

        #expect(widening.xml == nil)
    }

    /// Sub-block headroom cannot be realized — the same rule
    /// `QEMUMemoryReservation` applies at create time — so it is not a widening at
    /// all rather than a device the VM could never grow into.
    @Test("headroom smaller than one virtio-mem block is not a widening")
    func subBlockHeadroomIsIgnored() throws {
        let document = Self.definedDomain(bootGiB: 4, headroomGiB: nil)
        let widening = try Self.widening(
            document,
            spec: Self.spec(memoryBytes: 4 * Self.gib, maxMemoryBytes: 4 * Self.gib + 1024))

        #expect(widening.memoryCeilingBytes == nil)
    }

    // MARK: - vCPU ceiling

    @Test("a spec asking for more vCPUs than the domain's maximum raises it")
    func vcpuCeilingIsRaised() throws {
        let widening = try Self.widening(Self.definedDomain(), spec: Self.spec(maxCpus: 16))

        #expect(widening.vcpuCeiling == 16)
        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "vcpu")?.text == "16")
        // The boot count moves to the spec's, exactly as `<currentMemory>` does
        // in the memory pass: pinning it would make the operator's restart land
        // the ceiling but not the vCPUs, since the follow-up arrives as a
        // hot-add a guest may never online.
        #expect(widened.child(named: "vcpu")?.attribute("current") == "2")
        // The cell has to span every vCPU the domain can now reach, or libvirt
        // refuses the document outright.
        #expect(numaCell(widened)?.attribute("cpus") == "0-15")
    }

    /// A domain whose `<vcpu>` carries no `current` is one booting every vCPU it
    /// has, so raising the ceiling without writing one would hand the guest all
    /// sixteen — a size nobody asked for.
    @Test("raising the ceiling writes a boot count libvirt was leaving implicit")
    func impliedBootCountIsWritten() throws {
        let document = Self.definedDomain().replacingOccurrences(
            of: "<vcpu placement='static' current='2'>8</vcpu>",
            with: "<vcpu placement='static'>8</vcpu>")
        let widening = try Self.widening(document, spec: Self.spec(maxCpus: 16))

        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "vcpu")?.text == "16")
        #expect(widened.child(named: "vcpu")?.attribute("current") == "2")
    }

    /// `current` is clamped to the ceiling being written. A spec whose `cpus`
    /// exceeds its own `maxCpus` is not normalized anywhere on the way off the
    /// wire, and `current` above the maximum is a document libvirt rejects.
    @Test("a boot count above the ceiling is clamped to it")
    func bootCountIsClampedToTheCeiling() throws {
        let spec = VMSpec(
            cpus: 12, maxCpus: 10, memoryBytes: 2 * Self.gib, boot: .disk(firmware: nil))
        let widening = try Self.widening(Self.definedDomain(), spec: spec)

        let widened = try DomainXMLNode.parse(#require(widening.xml))
        #expect(widened.child(named: "vcpu")?.text == "12")
        #expect(widened.child(named: "vcpu")?.attribute("current") == "12")
    }

    @Test("a domain with a declared CPU topology is refused rather than desynchronized")
    func declaredTopologyIsRefused() throws {
        let document = Self.definedDomain().replacingOccurrences(
            of: "  <cpu mode='host-passthrough' check='none'>",
            with: "  <cpu mode='host-passthrough' check='none'>\n"
                + "    <topology sockets='1' dies='1' cores='8' threads='1'/>")
        let widening = try Self.widening(document, spec: Self.spec(maxCpus: 16))

        #expect(widening.vcpuCeiling == nil)
        #expect(widening.refusals.count == 1)
        #expect(widening.refusals[0].contains("topology"))
    }

    @Test("a spec within the domain's vCPU maximum changes nothing")
    func unchangedVCPUCeilingIsLeftAlone() throws {
        let widening = try Self.widening(
            Self.definedDomain(), spec: Self.spec(maxMemoryBytes: 8 * Self.gib, maxCpus: 8))

        #expect(widening.vcpuCeiling == nil)
        #expect(widening.xml == nil)
    }

    // MARK: - Refusals leave the domain alone

    @Test("a domain with two memory devices is refused rather than guessed at")
    func multipleMemoryDevicesAreRefused() throws {
        var document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        document = document.replacingOccurrences(
            of: "  </devices>",
            with: "    <memory model='dimm'>\n      <target>\n        <size unit='KiB'>1048576</size>\n"
                + "        <node>0</node>\n      </target>\n    </memory>\n  </devices>")
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib))

        #expect(widening.memoryCeilingBytes == nil)
        #expect(widening.refusals.count == 1)
        #expect(widening.refusals[0].contains("2 memory devices"))
    }

    /// `memoryDeviceNode` names node 0, so a device added to a domain whose only
    /// cell has another id would point at a guest NUMA node that does not exist.
    /// Only a *new* device is affected; an existing one keeps whatever `<node>`
    /// it already had.
    @Test("a lone NUMA cell that is not node 0 refuses a new memory device")
    func nonZeroNUMACellRefusesANewDevice() throws {
        let document = Self.definedDomain(bootGiB: 4, headroomGiB: nil).replacingOccurrences(
            of: "  <cpu mode='host-passthrough' check='none'>",
            with: "  <cpu mode='host-passthrough' check='none'>\n    <numa>\n"
                + "      <cell id='1' cpus='0-7' memory='4194304' unit='KiB'/>\n    </numa>")
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 4 * Self.gib, maxMemoryBytes: 12 * Self.gib))

        #expect(widening.memoryCeilingBytes == nil)
        #expect(widening.refusals.count == 1)
        #expect(widening.refusals[0].contains("node 1"))
    }

    /// `DomainXMLNode` states its text/children exclusivity with an `assert`,
    /// which is compiled out of the build hypervisor nodes run — so a container
    /// that is really a leaf has to be refused here, in every build, rather than
    /// silently losing its character data to an `append`.
    @Test("a container this pass adds to is refused when it is really a leaf")
    func leafContainersAreRefused() {
        for container in ["devices", "cpu"] {
            let document = Self.definedDomain().replacingOccurrences(
                of: container == "devices" ? "  <devices>" : "  <cpu mode='host-passthrough' check='none'>",
                with: "  <\(container)>text</\(container)>\n  <\(container)-unused>")
            #expect(throws: DomainInventoryError.self) {
                try Self.widening(document, spec: Self.spec(maxCpus: 16))
            }
        }
    }

    @Test("a domain with two NUMA cells is refused rather than divided up")
    func multipleNUMACellsAreRefused() throws {
        var document = Self.definedDomain(bootGiB: 2, headroomGiB: 6)
        document = document.replacingOccurrences(
            of: "    </numa>",
            with: "      <cell id='1' cpus='4-7' memory='1048576' unit='KiB'/>\n    </numa>")
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib))

        #expect(widening.memoryCeilingBytes == nil)
        #expect(widening.refusals.count == 1)
        #expect(widening.refusals[0].contains("NUMA cells"))
    }

    /// A refusal on one axis must not cost the other one. A domain this cannot
    /// give memory headroom to can still be given the spare ports it is short
    /// of, and vice versa.
    @Test("a refused memory widening still tops the ports up")
    func refusedMemoryStillWidensPorts() throws {
        var document = Self.definedDomain(ports: Array(1...9), occupied: Array(1...9))
        document = document.replacingOccurrences(
            of: "    </numa>",
            with: "      <cell id='1' cpus='4-7' memory='1048576' unit='KiB'/>\n    </numa>")
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib))

        #expect(widening.memoryCeilingBytes == nil)
        #expect(widening.addedHotplugPorts == DomainXMLBuilder.spareHotplugPorts)
        #expect(widening.refusals.count == 1)
    }

    // MARK: - Everything else is carried through

    /// The half of this that is easy to get wrong silently. A redefine that
    /// dropped the NIC, the varstore or the console sockets would take a VM's
    /// hardware away at its next power cycle, and libvirt would accept the
    /// document without a word.
    @Test("a widened document keeps every device and path the original had")
    func widenedDocumentKeepsEverythingElse() throws {
        let document = Self.definedDomain(ports: Array(1...9), occupied: Array(1...9))
        let widening = try Self.widening(
            document, spec: Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib))
        let original = try DomainXMLNode.parse(document)
        let widened = try DomainXMLNode.parse(#require(widening.xml))

        for element in ["name", "uuid", "vcpu", "os", "features", "clock", "on_crash"] {
            #expect(widened.child(named: element) == original.child(named: element), "<\(element)> changed")
        }
        // Every device the domain had, unchanged — the four new controllers are
        // the only addition.
        let before = try #require(original.child(named: "devices")).children
        let after = try #require(widened.child(named: "devices")).children
        #expect(after.count == before.count + DomainXMLBuilder.spareHotplugPorts)
        for device in before where device.name != "memory" {
            #expect(after.contains(device), "<\(device.name)> was not carried through")
        }
    }

    /// The pass has to converge. Feeding its own output back must find nothing
    /// left to do — otherwise every boot would redefine the domain again and
    /// grow the root complex a little further each time.
    @Test("widening an already-widened document is a no-op")
    func wideningIsIdempotent() throws {
        let spec = Self.spec(memoryBytes: 16 * Self.gib, maxMemoryBytes: 32 * Self.gib)
        let first = try Self.widening(
            Self.definedDomain(ports: Array(1...9), occupied: Array(1...9)), spec: spec)
        let second = try Self.widening(#require(first.xml), spec: spec)

        #expect(second.xml == nil)
        #expect(second.addedHotplugPorts == 0)
        #expect(second.memoryCeilingBytes == nil)
    }

    @Test("a document that is not a domain is an error, not an empty widening")
    func nonDomainDocumentThrows() {
        #expect(throws: DomainInventoryError.self) {
            try Self.widening("<domainsnapshot><name>s</name></domainsnapshot>", spec: Self.spec())
        }
        #expect(throws: DomainInventoryError.self) {
            try Self.widening("<domain type='kvm'><name>vm</name></domain>", spec: Self.spec())
        }
    }

    // MARK: - Helpers

    private func rootPortIndexes(_ domain: DomainXMLNode) -> [Int] {
        (domain.child(named: "devices")?.children ?? [])
            .filter { $0.name == "controller" && $0.attribute("model") == "pcie-root-port" }
            .compactMap { $0.attribute("index").flatMap(Int.init) }
            .sorted()
    }

    private func numaCell(_ domain: DomainXMLNode) -> DomainXMLNode? {
        domain.child(named: "cpu")?.child(named: "numa")?.child(named: "cell")
    }

    private func virtioMem(_ domain: DomainXMLNode) -> DomainXMLNode? {
        (domain.child(named: "devices")?.children ?? [])
            .first { $0.name == "memory" && $0.attribute("model") == "virtio-mem" }?
            .child(named: "target")
    }

    private func elementCount(_ node: DomainXMLNode) -> Int {
        1 + node.children.reduce(0) { $0 + elementCount($1) }
    }

    private func allText(_ node: DomainXMLNode) -> [String] {
        (node.text.map { [$0] } ?? []) + node.children.flatMap(allText)
    }

    /// Character data read off the raw document, so the tree can be compared
    /// against something that never went through the parser under test.
    private func textValues(_ document: String) -> [String] {
        var values: [String] = []
        for line in document.components(separatedBy: "\n") {
            guard let open = line.range(of: ">"), let close = line.range(of: "</") else { continue }
            guard open.upperBound <= close.lowerBound else { continue }
            let text = String(line[open.upperBound..<close.lowerBound])
            guard !text.isEmpty else { continue }
            values.append(
                text.replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&amp;", with: "&"))
        }
        return values
    }

    private func closingTags(_ document: String) -> Int {
        document.components(separatedBy: "</").count - 1
    }
}
