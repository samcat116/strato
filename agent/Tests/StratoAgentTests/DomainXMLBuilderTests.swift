import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

#if canImport(FoundationXML)
import FoundationXML
#endif

/// The domain document is assembled where libvirt's own validation cannot be
/// reached: a domain libvirtd rejects fails the create with a message that
/// routinely names neither the element at fault nor the feature that pulled it
/// in. These assertions stand in for that validation.
///
/// The goldens were hand-written from the rules the spike recorded, not dumped
/// from the builder — a generated expectation only proves the code agrees with
/// itself.
///
/// Every golden here has been checked against real libvirt, not just against
/// this builder:
///
/// - all nine validate against the RELAX-NG schema of libvirt 11.5.0 (the
///   version floor), 12.0.0 and 12.6.0 — re-checked after STR-134 added
///   `<serial>` and the spare `pcie-root-port`s, together with the hot-plug and
///   detach fragments `DomainDeviceXML` sends (asserted in
///   `DomainDiskInventoryTests`, validated by splicing them into this
///   scenario's `<devices>`);
/// - all nine are accepted by `virsh define --validate` on libvirt 11.6.0,
///   which runs libvirt's own parser and the QEMU driver's checks on top of the
///   schema — that is what caught `<acpi/>` being invalid on aarch64 without
///   UEFI (`acpiRequiresUEFIOnArm64`);
/// - three were started for real under `virtqemud`, which created `serial.sock`,
///   `console.sock`, `qga.sock` and `vnc.sock` at exactly these paths, seeded
///   the varstore from the autoselected Secure Boot firmware, and reported
///   through the balloon.
///
/// The schema is not the last word, and `DomainXMLLibvirtTests` beside this file
/// is where the rest of it lives: the document that left every VM with zero free
/// PCIe root ports validated cleanly for as long as it shipped (STR-192). What a
/// *defined* domain looks like is a question only a running libvirt answers, so
/// those tests define these same scenarios and count.
///
/// Two gaps remain, both environmental: the validating host had no `/dev/kvm`,
/// so `type='kvm'`/`mode='host-passthrough'` were substituted for their TCG
/// equivalents; and an arm64 Secure Boot domain can only be defined where an
/// AAVMF `.secboot` build is installed, which no golden therefore pins.
///
/// To rewrite the goldens after an intentional change:
///
///     STRATO_UPDATE_GOLDENS=1 swift test --package-path agent --filter DomainXMLBuilderTests
///
/// Update mode still fails the run, so a stray export can never quietly turn a
/// regression into the new expectation.
@Suite("libvirt domain XML builder")
struct DomainXMLBuilderTests {

    // MARK: - Fixtures

    static let vmId = "0f9ea1b2-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
    static let vmDirectory = "/var/lib/strato/vms/\(vmId)"
    static let bootDisk = ResolvedDisk(path: "\(vmDirectory)/disk.qcow2", format: .qcow2)
    static let cloudInitISO = "\(vmDirectory)/cloud-init.iso"
    static let dataVolumeId = "6b1c0a5e-7d2f-4a83-9e10-5c4b3a2d1f00"
    static let referenceVolumeId = "9f3d7c21-4b6a-4e05-8d92-1a0b7c5e3d44"

    static let primaryNIC = ResolvedNetworkAttachment(
        network: "default", attachment: .tap(interface: "tap0f9ea1b23c4d"),
        macAddress: "52:54:00:12:34:56")
    static let jumboNIC = ResolvedNetworkAttachment(
        network: "storage", attachment: .tap(interface: "tap0f9ea1b23c4e"),
        macAddress: "52:54:00:ab:cd:ef", mtu: 9000)
    /// A NIC the control plane allocated no MAC for; libvirt generates and
    /// persists one, as QEMU does today.
    static let unaddressedNIC = ResolvedNetworkAttachment(
        network: "mgmt", attachment: .tap(interface: "tap0f9ea1b23c4f"))

    static func spec(
        cpus: Int = 2,
        maxCpus: Int? = nil,
        memoryBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxMemoryBytes: Int64? = nil,
        boot: BootSource = .disk(firmware: nil),
        machine: MachineProfile? = nil,
        graphics: GraphicsMode? = nil
    ) -> VMSpec {
        VMSpec(
            cpus: cpus, maxCpus: maxCpus, memoryBytes: memoryBytes, maxMemoryBytes: maxMemoryBytes,
            boot: boot, machine: machine,
            console: ConsoleSpec(graphics: graphics))
    }

    static func input(
        spec: VMSpec,
        disks: [ResolvedDisk] = [bootDisk],
        cloudInitISOPath: String? = cloudInitISO,
        networks: [ResolvedNetworkAttachment] = [primaryNIC],
        architecture: CPUArchitecture = .x86_64,
        accelerator: DomainAccelerator = .kvm,
        firmware: FirmwareSet? = nil,
        emulatorPath: String? = nil
    ) -> DomainXMLInput {
        DomainXMLInput(
            vmId: vmId, vmDirectory: vmDirectory, spec: spec, disks: disks,
            cloudInitISOPath: cloudInitISOPath, networks: networks, architecture: architecture,
            accelerator: accelerator, firmware: firmware, emulatorPath: emulatorPath)
    }

    // MARK: - Scenarios

    /// One golden document. The name is also the golden's filename stem, which
    /// `noOrphanedGoldens` relies on.
    struct Scenario: Sendable, CustomStringConvertible {
        let name: String
        let input: DomainXMLInput
        var description: String { name }
    }

    static let scenarios: [Scenario] = [
        // The baseline every other scenario is a delta from.
        Scenario(name: "x86_64-uefi-headless-minimal", input: input(spec: spec())),
        // Secure Boot pulls in the firmware features and SMM; the graphics
        // console pulls in the xHCI controller, video model and input devices.
        Scenario(
            name: "x86_64-uefi-secureboot-tpm-vnc",
            input: input(
                spec: spec(
                    cpus: 4, memoryBytes: 4 * 1024 * 1024 * 1024,
                    machine: MachineProfile(secureBoot: true, tpm: true), graphics: .vnc),
                networks: [jumboNIC, unaddressedNIC])),
        // Hot-add headroom, which is the one shape that grows a NUMA topology.
        Scenario(
            name: "x86_64-uefi-headroom",
            input: input(
                spec: spec(maxCpus: 8, maxMemoryBytes: 8 * 1024 * 1024 * 1024),
                cloudInitISOPath: nil)),
        // Direct kernel boot: no firmware of any kind, and the console
        // arguments appended to a command line that already names one of them.
        Scenario(
            name: "x86_64-directkernel-multidisk",
            input: input(
                spec: spec(
                    cpus: 1, memoryBytes: 512 * 1024 * 1024,
                    boot: .directKernel(
                        kernel: "/var/lib/strato/images/vmlinuz",
                        initramfs: "/var/lib/strato/images/initrd.img",
                        cmdline: "root=/dev/vda1 ro console=ttyS0,115200")),
                disks: [
                    // Stored 0-based, as `MigrateVMDisksToVolumes` writes it;
                    // the golden shows the 1-based renumbering libvirt needs.
                    // No volume id: this is the disk materialized from the VM's
                    // image, which no volume owns and which therefore carries
                    // no serial.
                    ResolvedDisk(path: "\(vmDirectory)/disk.qcow2", format: .qcow2, bootOrder: 0),
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/data.qcow2", format: .qcow2, bootOrder: 1,
                        volumeId: dataVolumeId),
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/reference.raw", format: .raw, readonly: true,
                        volumeId: referenceVolumeId),
                ],
                cloudInitISOPath: nil,
                networks: [])),
        // **The document a stock hypervisor node actually gets** (STR-188):
        // the resolver names the pair every Debian and Ubuntu host ships, and
        // the nvram element carries a format but no template, because the agent
        // has already written the varstore. The autoselect scenarios above are
        // the *fallback* — what a host whose EDK2 build this resolver cannot
        // find falls back to — not the norm.
        Scenario(
            name: "x86_64-uefi-resolved-pair",
            input: input(
                spec: spec(),
                firmware: .pflash(
                    code: "/usr/share/OVMF/OVMF_CODE_4M.fd",
                    varsTemplate: "/usr/share/OVMF/OVMF_VARS_4M.fd"))),
        // An operator-configured firmware pair, which is the same shape with
        // Secure Boot's `secure='yes'` loader and SMM on top.
        Scenario(
            name: "x86_64-override-pflash",
            input: input(
                spec: spec(machine: MachineProfile(secureBoot: true)),
                cloudInitISOPath: nil,
                firmware: .pflash(
                    code: "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd",
                    varsTemplate: "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"))),
        // The legacy single-blob firmware, which has no writable varstore.
        Scenario(
            name: "x86_64-monolithic-firmware",
            input: input(
                spec: spec(), cloudInitISOPath: nil,
                firmware: .monolithic(path: "/usr/share/qemu/edk2-x86_64-code.fd"),
                emulatorPath: "/usr/bin/qemu-system-x86_64")),
        // The most PCI devices this builder can put in one document: three
        // disks and a cloud-init ISO, three NICs, the graphics console's xHCI
        // controller and framebuffer, and a virtio-mem device. The spare root
        // ports are numbered from that count, so this is the scenario where a
        // base derived wrong shows up first (STR-192).
        Scenario(
            name: "x86_64-max-devices",
            input: input(
                spec: spec(
                    cpus: 8, maxCpus: 16, memoryBytes: 8 * 1024 * 1024 * 1024,
                    maxMemoryBytes: 16 * 1024 * 1024 * 1024,
                    machine: MachineProfile(secureBoot: true, tpm: true), graphics: .vnc),
                disks: [
                    ResolvedDisk(path: "\(vmDirectory)/disk.qcow2", format: .qcow2, bootOrder: 0),
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/data.qcow2", format: .qcow2,
                        volumeId: dataVolumeId),
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/reference.raw", format: .raw, readonly: true,
                        volumeId: referenceVolumeId),
                ],
                networks: [primaryNIC, jumboNIC, unaddressedNIC])),
        // arm64 UEFI: GIC instead of APIC, never SMM, and virtio rather than
        // VGA for the framebuffer. Secure Boot is deliberately off — an
        // aarch64 Secure Boot domain can only be defined on a host carrying an
        // AAVMF `.secboot` build, so pinning one here would make the golden
        // unvalidatable on most hosts. `secureBootOnArm64OmitsSMM` covers that
        // combination instead.
        Scenario(
            name: "arm64-uefi-vnc-tpm",
            input: input(
                spec: spec(
                    cpus: 4, memoryBytes: 4 * 1024 * 1024 * 1024,
                    machine: MachineProfile(tpm: true), graphics: .vnc),
                architecture: .arm64)),
        // arm64 direct kernel: bare `virt` with no GIC element, TCG rather than
        // an accelerator, an absent initramfs and a blank command line, and
        // virtio-mem at the larger arm64 block size. It also carries no
        // `<features>` at all, since ACPI needs UEFI on this architecture.
        Scenario(
            name: "arm64-directkernel-headroom",
            input: input(
                spec: spec(
                    maxCpus: 4, memoryBytes: 1024 * 1024 * 1024,
                    maxMemoryBytes: 2 * 1024 * 1024 * 1024,
                    boot: .directKernel(
                        kernel: "/var/lib/strato/images/Image", initramfs: nil, cmdline: nil)),
                cloudInitISOPath: nil,
                architecture: .arm64, accelerator: .tcg)),
    ]

    // MARK: - Golden comparison

    private static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Goldens")
        .appendingPathComponent("DomainXML")

    private static func goldenURL(_ name: String) -> URL {
        goldenDirectory.appendingPathComponent("\(name).xml")
    }

    @Test("the document matches its golden", arguments: scenarios)
    func matchesGolden(_ scenario: Scenario) throws {
        let actual = try DomainXMLBuilder.build(scenario.input)
        let url = Self.goldenURL(scenario.name)

        if ProcessInfo.processInfo.environment["STRATO_UPDATE_GOLDENS"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
            Issue.record(
                "rewrote golden '\(scenario.name)'; re-run without STRATO_UPDATE_GOLDENS to verify")
            return
        }

        let expected = try String(contentsOf: url, encoding: .utf8)
        guard actual != expected else { return }
        Issue.record("\(Self.diff(expected: expected, actual: actual, name: scenario.name))")
    }

    /// A raw `#expect(actual == expected)` on a multi-kilobyte document prints
    /// both in full and leaves you to find the difference by eye.
    private static func diff(expected: String, actual: String, name: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        let firstDifference =
            (0..<max(expectedLines.count, actualLines.count)).first {
                expectedLines[safe: $0] != actualLines[safe: $0]
            } ?? 0
        let context = max(0, firstDifference - 3)

        func window(_ lines: [String]) -> String {
            let lower = min(context, lines.count)
            let upper = max(lower, min(lines.count, firstDifference + 4))
            return lines[lower..<upper]
                .enumerated()
                .map { offset, line in
                    let number = lower + offset
                    return "\(number == firstDifference ? " > " : "   ")\(number + 1)| \(line)"
                }
                .joined(separator: "\n")
        }

        return """
            golden '\(name)' does not match, first difference at line \(firstDifference + 1)

            expected:
            \(window(expectedLines))

            actual:
            \(window(actualLines))

            If the change is intended, rewrite the goldens with:
              STRATO_UPDATE_GOLDENS=1 swift test --package-path agent --filter DomainXMLBuilderTests
            """
    }

    /// Renaming a scenario without renaming its file leaves a golden nothing
    /// reads, which then rots into a plausible-looking lie.
    @Test("every golden on disk belongs to a scenario")
    func noOrphanedGoldens() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.goldenDirectory, includingPropertiesForKeys: nil)
        let onDisk = Set(
            files.filter { $0.pathExtension == "xml" }.map {
                $0.deletingPathExtension().lastPathComponent
            })
        #expect(onDisk == Set(Self.scenarios.map(\.name)))
    }

    // MARK: - Validation against libvirt itself

    private static let virtXMLValidatePath: String? = {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return searchPath.components(separatedBy: ":")
            .map { ($0 as NSString).appendingPathComponent("virt-xml-validate") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Keeps the goldens honest against the schema rather than only against
    /// this builder, on any machine that has libvirt installed — a dev box, or
    /// the manual `Full Test Suite` workflow. It is skipped rather than failed
    /// where the tool is absent, which includes CI: PR validation is a compile
    /// check that never runs tests at all.
    ///
    /// This is the check that would have caught `<boot order='0'/>`, which the
    /// schema rejects outright.
    @Test(
        "goldens validate against libvirt's own schema",
        .enabled(if: virtXMLValidatePath != nil, "virt-xml-validate is not installed"),
        arguments: scenarios)
    func validatesAgainstLibvirtSchema(_ scenario: Scenario) throws {
        let tool = try #require(Self.virtXMLValidatePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [Self.goldenURL(scenario.name).path, "domain"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting: a full pipe buffer would otherwise deadlock the
        // child against a parent that never drains it.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(
            process.terminationStatus == 0,
            "\(scenario.name) failed libvirt's schema:\n\(output)")
    }

    // MARK: - Properties no golden can assert

    /// A golden records whatever the builder produced, including a document no
    /// parser would accept. This is the assertion that an escaping bug cannot
    /// survive.
    @Test("the document is well-formed XML", arguments: scenarios)
    func isWellFormed(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        #expect(Self.parses(xml))
    }

    private static func parses(_ xml: String) -> Bool {
        let parser = XMLParser(data: Data(xml.utf8))
        return parser.parse() && parser.parserError == nil
    }

    /// Invariants that hold for every document this builder can produce, so a
    /// new scenario cannot quietly reintroduce one of them.
    @Test("structural invariants hold", arguments: scenarios)
    func invariants(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)

        #expect(xml.hasPrefix("<domain type='"))
        #expect(xml.hasSuffix("</domain>\n"))
        #expect(xml.components(separatedBy: "<domain ").count == 2)

        // Suppressing security labelling breaks libvirt's own swtpm and NVRAM
        // setup; hypervisor nodes point the DAC driver at the agent's account
        // instead, which needs no element here.
        #expect(!xml.contains("<seclabel"))
        // A qemu: namespace would mean the document no longer validates against
        // libvirt's schema.
        #expect(!xml.contains("qemu:"))
        // The VNC console is a Unix socket in the VM's directory and carries no
        // RFB password; a TCP listener would expose it unauthenticated.
        #expect(!xml.contains("<graphics type='vnc' port"))
        #expect(!xml.contains("listen type='address'"))

        // Exactly one balloon, and free-page *reporting* rather than the QEMU
        // path's free-page hinting — see the builder's note. Reporting needs no
        // iothread, which is what let the hand-built device (and the argv
        // builder around it) go away with the process driver.
        #expect(xml.components(separatedBy: "<memballoon ").count == 2)
        #expect(xml.contains("<memballoon model='virtio' freePageReporting='on'/>"))
    }

    /// The graphics console's device reasoning (issue #566), which used to be
    /// asserted against a QEMU command line before the process driver was
    /// deleted (STR-136). The goldens record the whole document; these are the
    /// four choices that are wrong-looking-but-deliberate, so a future edit has
    /// to argue with them rather than just re-record a golden.
    @Test("the graphics console's device choices", arguments: CPUArchitecture.allCases)
    func graphicsDevices(_ architecture: CPUArchitecture) throws {
        let xml = try DomainXMLBuilder.build(
            Self.input(spec: Self.spec(graphics: .vnc), architecture: architecture))

        // Standard VGA on x86, virtio on arm64: this console exists for
        // pre-driver output — UEFI, GRUB, Windows Setup, a panic screen — which
        // a virtio adapter cannot show without a guest driver. The arm64 `virt`
        // machine has no VGA device at all, and EDK2 drives virtio-gpu at
        // firmware time through `VirtioGpuDxe`.
        let model = architecture == .x86_64 ? "vga" : "virtio"
        #expect(xml.contains("<model type='\(model)' heads='1'/>"))

        // An absolute-positioning tablet, or the guest cursor drifts away from
        // the browser's and a graphical installer becomes unclickable.
        #expect(xml.contains("<input type='tablet' bus='usb'/>"))
        // A USB keyboard on *every* architecture, and arm64 is why: `virt` has
        // no PS/2 controller and creates no input devices, so a guest there
        // would render and accept clicks while dropping every keystroke. x86
        // would type without it (q35 keeps the default i8042), so testing only
        // that architecture would hide the bug entirely.
        #expect(xml.contains("<input type='keyboard' bus='usb'/>"))
        // Both need a controller to sit on: q35 starts with USB off and `virt`
        // has none at all. xHCI is the one model present on both machines.
        #expect(xml.contains("<controller type='usb' index='0' model='qemu-xhci'/>"))
    }

    /// A headless VM states `<video><model type='none'/>`, rather than omitting
    /// the element, so no libvirt version auto-adds a framebuffer to a VM whose
    /// console is the serial port.
    @Test("a headless VM declares no display rather than leaving it open")
    func headlessDeclaresNoVideo() throws {
        let xml = try DomainXMLBuilder.build(Self.input(spec: Self.spec()))
        #expect(xml.contains("<model type='none'/>"))
        #expect(!xml.contains("<graphics"))
        #expect(!xml.contains("<input"))
        #expect(!xml.contains("qemu-xhci"))
    }

    @Test("user-mode networking is refused rather than guessed at")
    func userModeThrows() throws {
        let input = Self.input(
            spec: Self.spec(),
            networks: [ResolvedNetworkAttachment(network: "slirp", attachment: .userMode)])
        #expect(throws: DomainXMLBuilderError.unsupportedNetworkAttachment(network: "slirp")) {
            try DomainXMLBuilder.build(input)
        }
    }

    @Test("a domain name libvirt cannot hold is refused", arguments: ["", "vms/abc"])
    func invalidNameThrows(_ name: String) throws {
        var input = Self.input(spec: Self.spec())
        input.vmId = name
        #expect(throws: DomainXMLBuilderError.invalidDomainName(name)) {
            try DomainXMLBuilder.build(input)
        }
    }

    /// Nothing normalizes a decoded `VMSpec`, and both of these reach libvirt
    /// as an error naming the element rather than the spec behind it.
    @Test("sizing libvirt would reject is refused with its own name")
    func invalidSizingThrows() throws {
        #expect(throws: DomainXMLBuilderError.invalidCPUCount(0)) {
            try DomainXMLBuilder.build(Self.input(spec: Self.spec(cpus: 0)))
        }
        #expect(throws: DomainXMLBuilderError.invalidMemorySize(0)) {
            try DomainXMLBuilder.build(Self.input(spec: Self.spec(memoryBytes: 0)))
        }
    }

    /// libvirt types the attribute as `positiveInteger` and rejects a repeat
    /// ("boot order '1' used for more than one device"), while Strato stores an
    /// unvalidated `Int?` whose first value is 0 — which is what
    /// `MigrateVMDisksToVolumes` has already written to every migrated boot
    /// volume. The stored number is a flag; the position is the order.
    @Test("boot order is renumbered from position, never copied through")
    func bootOrderIsDerived() throws {
        func orders(_ stored: [Int?]) -> [Int?] {
            DomainXMLBuilder.derivedBootOrders(
                stored.map { ResolvedDisk(path: "/d.qcow2", format: .qcow2, bootOrder: $0) })
        }
        // Strato's 0-based values become libvirt's 1-based ones.
        #expect(orders([0, 1, 2]) == [1, 2, 3])
        // Duplicates and negatives, both reachable through the volume API,
        // still come out unique and positive.
        #expect(orders([0, 0, 0]) == [1, 2, 3])
        #expect(orders([-1, 5]) == [1, 2])
        // Disks with no stated order get no boot element, and do not consume a
        // number that would leave a gap.
        #expect(orders([nil, 3, nil, 7]) == [nil, 1, nil, 2])
        #expect(orders([nil, nil]) == [nil, nil])
    }

    /// The serial is how a hot-unplug finds the disk again on a domain the
    /// agent keeps no model of (STR-134). A disk with no volume behind it must
    /// not get one, or a boot disk would answer to a volume's identity.
    @Test("a volume-backed disk names its volume, and an image-backed one does not")
    func volumeSerials() throws {
        let volumeId = "6b1c0a5e-7d2f-4a83-9e10-5c4b3a2d1f00"
        let xml = try DomainXMLBuilder.build(
            Self.input(
                spec: Self.spec(),
                disks: [
                    Self.bootDisk,
                    ResolvedDisk(path: "/volumes/data.qcow2", format: .qcow2, volumeId: volumeId),
                ]))

        #expect(xml.contains("<serial>vol-\(volumeId)</serial>"))
        // Exactly one, so the boot disk and the cloud-init ISO carry none.
        #expect(xml.components(separatedBy: "<serial>").count == 2)
        // And it is the same identity the QEMU driver names its QMP device
        // with, so one volume has one identity whichever driver realizes it.
        #expect(xml.contains(QEMUDiskIdentity.deviceID(volumeId: volumeId)))
    }

    /// libvirt allocates a `pcie-root-port` per PCI device the document
    /// declares, so a domain that reserves none has nowhere to hot-plug a disk —
    /// and a domain document is written once, so a VM defined without spares can
    /// never gain them.
    ///
    /// The **indexes** are the mechanism rather than decoration (STR-192): an
    /// un-indexed spare is numbered by libvirt out of the very range it was
    /// going to allocate for the devices above it, and then filled with one of
    /// them. That form left every VM with zero free ports while claiming four,
    /// so the assertion this test used to make — that no port carries an index —
    /// was the bug, written down as an expectation.
    @Test(
        "every domain reserves empty PCIe root ports past the devices it declares",
        arguments: scenarios)
    func reservesHotplugPorts(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        let indexes = Self.spareIndexes(scenario.input)

        #expect(indexes.count == DomainXMLBuilder.spareHotplugPorts)
        // Strictly past every port the defined domain will occupy — index 0
        // being the root complex, the first port is 1, so a first spare above
        // the device count is a spare no device can be given.
        #expect(indexes.lowerBound > Self.declaredPCIDevices(scenario.input))
        for index in indexes {
            #expect(xml.contains("<controller type='pci' index='\(index)' model='pcie-root-port'/>"))
        }
        // And nothing un-indexed, which is the form that reserves nothing.
        #expect(!xml.contains("<controller type='pci' model='pcie-root-port'/>"))
        #expect(
            xml.components(separatedBy: "model='pcie-root-port'").count
                == DomainXMLBuilder.spareHotplugPorts + 1)
    }

    /// Each root port reserves guest I/O and MMIO windows, and a domain with
    /// enough of them stops starting rather than failing to define — libvirt
    /// 12.0.0 defines a domain declaring index 240 happily and then cannot boot
    /// it. A VM whose own devices reach that far therefore loses its spare
    /// ports rather than its boot.
    @Test("spare ports stop at the root-port ceiling rather than crowding it")
    func spareHotplugPortsAreCapped() {
        func spares(disks: Int) -> Int {
            Self.spareIndexes(
                Self.input(
                    spec: Self.spec(),
                    disks: (0..<disks).map { ResolvedDisk(path: "/d\($0).qcow2", format: .qcow2) })
            ).count
        }
        // Four devices besides the disks (cloud-init ISO, NIC, virtio-serial,
        // memballoon) plus the allowance, so 22 disks put the last spare exactly
        // on the ceiling and every further disk costs one.
        #expect(spares(disks: 22) == DomainXMLBuilder.spareHotplugPorts)
        #expect(spares(disks: 24) == 2)
        #expect(spares(disks: 26) == 0)
    }

    /// libvirt numbers un-indexed controllers from 0, and both machine types
    /// the builder emits reserve PCI index 0 for the root complex — so a
    /// document that declares ports without declaring the complex has its
    /// first port land on 0 and is rejected outright (STR-189).
    @Test("the PCI root complex is declared ahead of its ports", arguments: scenarios)
    func declaresRootComplexBeforePorts(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        let root = try #require(
            xml.range(of: "<controller type='pci' index='0' model='pcie-root'/>"))
        let firstPort = try #require(xml.range(of: "model='pcie-root-port'"))
        #expect(root.lowerBound < firstPort.lowerBound)
    }

    /// Both derivations need the aligned headroom the builder computes, which
    /// no caller of theirs has to hand.
    static func spareIndexes(_ input: DomainXMLInput) -> Range<Int> {
        DomainXMLBuilder.spareHotplugPortIndexes(input, hotplugBytes: hotplugBytes(input))
    }

    static func declaredPCIDevices(_ input: DomainXMLInput) -> Int {
        DomainXMLBuilder.declaredPCIDeviceCount(input, hotplugBytes: hotplugBytes(input))
    }

    private static func hotplugBytes(_ input: DomainXMLInput) -> Int64 {
        MemoryHotplugPlan.alignedHotplugBytes(
            spec: input.spec, architecture: input.architecture)
    }

    /// The varstore is qcow2 on every firmware path, and that is load-bearing
    /// rather than cosmetic: libvirt refuses an internal snapshot of a pflash
    /// guest whose varstore is raw, so a raw one silently costs `checkpointVM`
    /// — the capability the libvirt >= 11.5 floor exists for. This is the half
    /// of STR-188 that must survive its fix: the format was never the thing to
    /// give up.
    @Test("the varstore is qcow2 on every firmware path", arguments: scenarios)
    func varstoreIsAlwaysQcow2(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        guard let nvram = xml.range(of: "<nvram") else { return }  // direct kernel / monolithic
        // Match inside the element rather than on a prefix. `format=` appears
        // nowhere else — disks spell it `type=`.
        let element = xml[nvram.lowerBound...].prefix(while: { $0 != ">" })
        #expect(element.contains("format='qcow2'"))
    }

    /// The other half of STR-188, and the one that only shows up on a *start*.
    ///
    /// A named `template` asks libvirt to seed the varstore from the distro's
    /// VARS file, and libvirt will not change its format on the way:
    /// "conversion of the nvram template to another target format is not
    /// supported". Since the varstore above is qcow2 and every EDK2 descriptor
    /// Debian and Ubuntu ship declares a raw template, a document naming both
    /// defines cleanly and then refuses to start — which is worse than failing
    /// the define, because the create reports success.
    ///
    /// So the resolved-pair document names a file and nothing else, and
    /// `UEFIVarstore` is what guarantees the file is there. An existing nvram
    /// is never seeded, so it is never converted.
    @Test("a named varstore is never given a template to seed from", arguments: scenarios)
    func varstoreIsNeverSeededFromATemplate(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        guard let nvram = xml.range(of: "<nvram") else { return }  // direct kernel / monolithic
        let element = xml[nvram.lowerBound...].prefix(while: { $0 != ">" })
        #expect(!element.contains("template="))
    }

    /// Secure Boot's `secure='yes'` marks the varstore pflash SMM-only, and ARM
    /// has no SMM — libvirt rejects the pairing rather than ignoring it.
    @Test("the loader is only marked secure on x86")
    func secureLoaderIsX86Only() throws {
        let firmware = FirmwareSet.pflash(
            code: "/usr/share/AAVMF/AAVMF_CODE.secboot.fd",
            varsTemplate: "/usr/share/AAVMF/AAVMF_VARS.ms.fd")
        let xml = try DomainXMLBuilder.build(
            Self.input(
                spec: Self.spec(machine: MachineProfile(secureBoot: true)),
                architecture: .arm64, firmware: firmware))
        #expect(xml.contains("<loader readonly='yes' type='pflash'>"))
        #expect(!xml.contains("secure='yes'"))
        #expect(!xml.contains("<smm"))
    }

    /// The autoselect counterpart of `secureLoaderIsX86Only`: the firmware
    /// features still ask for Secure Boot, but SMM is x86-only machinery and
    /// libvirt rejects a domain that asks for it on `virt`.
    @Test("Secure Boot on arm64 asks for the firmware but not for SMM")
    func secureBootOnArm64OmitsSMM() throws {
        let xml = try DomainXMLBuilder.build(
            Self.input(
                spec: Self.spec(machine: MachineProfile(secureBoot: true)), architecture: .arm64))
        #expect(xml.contains("<feature enabled='yes' name='secure-boot'/>"))
        #expect(xml.contains("<feature enabled='yes' name='enrolled-keys'/>"))
        #expect(!xml.contains("<smm"))
        #expect(xml.contains("<gic version='3'/>"))
    }

    /// libvirt refuses a domain that pairs ACPI with a non-UEFI boot on
    /// aarch64 ("ACPI requires UEFI on this architecture"), and an arm64
    /// direct-kernel VM then has no features left to declare at all.
    @Test("ACPI is only claimed where libvirt accepts it")
    func acpiRequiresUEFIOnArm64() throws {
        let directKernel = BootSource.directKernel(
            kernel: "/images/Image", initramfs: nil, cmdline: nil)

        let arm = try DomainXMLBuilder.build(
            Self.input(spec: Self.spec(boot: directKernel), architecture: .arm64))
        #expect(!arm.contains("<acpi/>"))
        #expect(!arm.contains("<features"))

        // x86 is unaffected, and arm64 keeps ACPI when it boots via firmware.
        let x86 = try DomainXMLBuilder.build(Self.input(spec: Self.spec(boot: directKernel)))
        #expect(x86.contains("<acpi/>"))
        let armUEFI = try DomainXMLBuilder.build(
            Self.input(spec: Self.spec(), architecture: .arm64))
        #expect(armUEFI.contains("<acpi/>"))
    }

    // MARK: - Escaping

    @Test("XML metacharacters are escaped")
    func escapesMetacharacters() {
        #expect(DomainXMLNode.escaped("a & b") == "a &amp; b")
        // `&` must be replaced first, or the replacements are re-escaped.
        #expect(DomainXMLNode.escaped("&amp;") == "&amp;amp;")
        #expect(DomainXMLNode.escaped("<tag>") == "&lt;tag&gt;")
        #expect(DomainXMLNode.escaped("\"quoted\"") == "&quot;quoted&quot;")
        #expect(DomainXMLNode.escaped("it's") == "it&apos;s")
    }

    /// There is no entity for a control character — `&#0;` is exactly as
    /// illegal as a literal NUL — so the only options are dropping it or
    /// emitting a document libvirt cannot parse.
    @Test("characters XML forbids are dropped, and the ones it allows are kept")
    func dropsIllegalControlCharacters() {
        #expect(DomainXMLNode.escaped("a\u{0}b") == "ab")
        #expect(DomainXMLNode.escaped("a\u{1}b\u{1F}c") == "abc")
        #expect(DomainXMLNode.escaped("a\u{FFFE}b\u{FFFF}c") == "abc")
        #expect(DomainXMLNode.escaped("a\tb\nc\rd") == "a\tb\nc\rd")
    }

    /// Paths, network names and kernel command lines are API-sourced, and this
    /// is the first place any of them lands somewhere `&` is structural.
    @Test("hostile strings still produce a parseable document")
    func escapesUserSuppliedStrings() throws {
        let input = Self.input(
            spec: Self.spec(
                boot: .directKernel(
                    kernel: "/images/vm & test/vmlinuz", initramfs: nil,
                    cmdline: "root=/dev/vda1 flag=\"a<b\" other='c&d'")),
            disks: [ResolvedDisk(path: "/volumes/a & b/<disk>.qcow2", format: .qcow2)],
            cloudInitISOPath: nil,
            networks: [
                ResolvedNetworkAttachment(
                    network: "net<&>", attachment: .tap(interface: "tap<0>"),
                    macAddress: "52:54:00:12:34:56")
            ])
        let xml = try DomainXMLBuilder.build(input)

        #expect(Self.parses(xml))
        #expect(xml.contains("/volumes/a &amp; b/&lt;disk&gt;.qcow2"))
        #expect(xml.contains("tap&lt;0&gt;"))
        #expect(!xml.contains("a & b"))
    }

    // MARK: - Units of translation

    struct TargetNameCase: Sendable, CustomStringConvertible {
        let index: Int
        let expected: String
        var description: String { "\(index) → \(expected)" }
    }

    /// Positional, because `VolumeSpec.deviceName` is a control-plane label
    /// rather than a guest device name and two volumes could carry the same one.
    @Test(
        "disk target names are bijective base-26",
        arguments: [
            TargetNameCase(index: 0, expected: "vda"),
            TargetNameCase(index: 25, expected: "vdz"),
            TargetNameCase(index: 26, expected: "vdaa"),
            TargetNameCase(index: 27, expected: "vdab"),
            TargetNameCase(index: 51, expected: "vdaz"),
            TargetNameCase(index: 701, expected: "vdzz"),
        ])
    func targetDeviceNames(_ testCase: TargetNameCase) {
        #expect(DomainXMLBuilder.targetDeviceName(index: testCase.index) == testCase.expected)
    }

    @Test("console arguments are added to a kernel command line exactly once")
    func kernelCommandLineConsoles() {
        let all = "console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0"
        #expect(DomainXMLBuilder.kernelCommandLine(nil) == all)
        #expect(DomainXMLBuilder.kernelCommandLine("   ") == all)
        #expect(DomainXMLBuilder.kernelCommandLine("root=/dev/vda1") == "root=/dev/vda1 " + all)
        #expect(
            DomainXMLBuilder.kernelCommandLine("quiet console=hvc0")
                == "quiet console=hvc0 console=tty0 console=ttyS0,115200 console=ttyAMA0,115200")
    }

    /// libvirt inverts QEMU's split: the total goes in `<memory>` and the boot
    /// size in `<currentMemory>`. Carrying QEMU's split over makes libvirt
    /// compute an initial size of zero and reject the domain.
    @Test("memory elements carry the total, the boot size, and the ceiling")
    func memorySizing() throws {
        let xml = try DomainXMLBuilder.build(
            Self.input(spec: Self.spec(maxMemoryBytes: 8 * 1024 * 1024 * 1024)))
        #expect(xml.contains("<maxMemory slots='1' unit='KiB'>8388608</maxMemory>"))
        #expect(xml.contains("<memory unit='KiB'>8388608</memory>"))
        #expect(xml.contains("<currentMemory unit='KiB'>2097152</currentMemory>"))
        #expect(xml.contains("<size unit='KiB'>6291456</size>"))
    }

    /// Headroom smaller than one virtio-mem block cannot be realized, so the VM
    /// gets no memory device at all rather than one it can never grow into —
    /// and without a device there is nothing requiring a NUMA topology either.
    @Test("sub-block headroom produces no memory device")
    func subBlockHeadroomIsDropped() throws {
        let xml = try DomainXMLBuilder.build(
            Self.input(spec: Self.spec(maxMemoryBytes: 2 * 1024 * 1024 * 1024 + 1024 * 1024)))
        #expect(!xml.contains("virtio-mem"))
        #expect(!xml.contains("<maxMemory"))
        #expect(!xml.contains("<numa>"))
        #expect(xml.contains("<memory unit='KiB'>2097152</memory>"))
    }

    @Test("virtio-mem block size follows the guest architecture")
    func blockSizes() {
        #expect(MemoryHotplugPlan.blockBytes(architecture: .x86_64) == 2 * 1024 * 1024)
        #expect(MemoryHotplugPlan.blockBytes(architecture: .arm64) == 512 * 1024 * 1024)

        let spec = Self.spec(
            memoryBytes: 1024 * 1024 * 1024, maxMemoryBytes: 1024 * 1024 * 1024 + 700 * 1024 * 1024)
        // 700 MiB floors to a single 512 MiB block on arm64 and to 700 MiB
        // exactly on x86, where the block is 2 MiB.
        #expect(
            MemoryHotplugPlan.alignedHotplugBytes(spec: spec, architecture: .arm64)
                == 512 * 1024 * 1024)
        #expect(
            MemoryHotplugPlan.alignedHotplugBytes(spec: spec, architecture: .x86_64)
                == 700 * 1024 * 1024)
        #expect(
            MemoryHotplugPlan.alignedHotplugBytes(spec: Self.spec(), architecture: .x86_64) == 0)
    }

    /// The domain document and the agent's own socket clients derive these
    /// paths separately; a rename has to fail loudly here rather than strand a
    /// running VM's console.
    @Test("per-VM filenames are stable")
    func vmDirectoryLayout() {
        let dir = "/var/lib/strato/vms/abc"
        #expect(VMDirectoryLayout.consoleSocket(vmDirectory: dir) == "\(dir)/console.sock")
        #expect(VMDirectoryLayout.serialSocket(vmDirectory: dir) == "\(dir)/serial.sock")
        #expect(VMDirectoryLayout.guestAgentSocket(vmDirectory: dir) == "\(dir)/qga.sock")
        #expect(VMDirectoryLayout.cloudInitISO(vmDirectory: dir) == "\(dir)/cloud-init.iso")
        #expect(VMDirectoryLayout.nvram(vmDirectory: dir) == "\(dir)/nvram.fd")
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
