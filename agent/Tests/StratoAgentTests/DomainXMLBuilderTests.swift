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
/// - all eight validate against the RELAX-NG schema of both libvirt 11.5.0 (the
///   version floor) and 12.6.0 — re-checked against both after STR-134 added
///   `<serial>` and the spare `pcie-root-port`s, together with the hot-plug and
///   detach fragments `DomainDeviceXML` sends (asserted in
///   `DomainDiskInventoryTests`, validated by splicing them into this
///   scenario's `<devices>`);
/// - all eight are accepted by `virsh define --validate` on libvirt 11.6.0,
///   which runs libvirt's own parser and the QEMU driver's checks on top of the
///   schema — that is what caught `<acpi/>` being invalid on aarch64 without
///   UEFI (`acpiRequiresUEFIOnArm64`);
/// - three were started for real under `virtqemud`, which created `serial.sock`,
///   `console.sock`, `qga.sock` and `vnc.sock` at exactly these paths, seeded
///   the varstore from the autoselected Secure Boot firmware, and reported
///   through the balloon.
///
/// Two gaps remain, both environmental: the validating host had no `/dev/kvm`,
/// so `type='kvm'`/`mode='host-passthrough'` were substituted for their TCG
/// equivalents; and an arm64 Secure Boot domain can only be defined where an
/// AAVMF `.secboot` build is installed, which no golden therefore pins.
///
/// **Not re-validated against libvirt:** the `index` STR-192 put on every spare
/// `pcie-root-port`, and the ninth scenario (`x86_64-uefi-maximal-pci`) added
/// with it — the host that fix was written on had no libvirt at all. The
/// attribute is `<controller>`'s own and the shape is what libvirt itself
/// dumps, so the schema is not the risk; what is unproven here is the *number*,
/// which only a defined domain's `dumpxml` can settle. `reservesHotplugPorts`
/// asserts the relationship rather than the number for that reason, and
/// property 2 of issue #1036 — that `attach-device` of a disk succeeds against
/// a freshly defined domain — still needs the e2e suite (issue #1031's gap).
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
            console: ConsoleSpec(console: .socket, serial: .socket, graphics: graphics))
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
        // The most PCI devices the builder can produce, which is the shape the
        // spare root ports have to be numbered past: three disks plus the
        // cloud-init ISO, three NICs, a graphics console (xHCI controller and
        // video), TPM, and the virtio-mem device hot-add headroom brings.
        Scenario(
            name: "x86_64-uefi-maximal-pci",
            input: input(
                spec: spec(
                    cpus: 4, maxCpus: 8, memoryBytes: 4 * 1024 * 1024 * 1024,
                    maxMemoryBytes: 8 * 1024 * 1024 * 1024,
                    machine: MachineProfile(secureBoot: true, tpm: true), graphics: .vnc),
                disks: [
                    bootDisk,
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/data.qcow2", format: .qcow2,
                        volumeId: dataVolumeId),
                    ResolvedDisk(
                        path: "/var/lib/strato/volumes/reference.raw", format: .raw, readonly: true,
                        volumeId: referenceVolumeId),
                ],
                networks: [primaryNIC, jumboNIC, unaddressedNIC])),
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
        // An operator-configured firmware pair, which suppresses autoselection.
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

    /// libvirt adds one `pcie-root-port` per PCI device the document declares,
    /// so a domain that reserves none has nowhere to hot-plug a disk — and a
    /// domain document is written once, so a VM defined without spares can
    /// never gain them.
    ///
    /// The reservation is the *index*, not the element: a port declared without
    /// one is numbered into the auto-assigned range and then filled with one of
    /// the domain's own devices, which is how `spareHotplugPorts` reserved
    /// nothing at all until STR-192. So this counts the document's PCI devices
    /// independently of the builder and asserts the property that survives
    /// libvirt's addressing pass — libvirt grows the bus set to the highest
    /// index declared, so `highest − devices` ports are left empty.
    @Test("every domain reserves empty PCIe root ports for hot-plug", arguments: scenarios)
    func reservesHotplugPorts(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        let spares = Self.rootPortIndexes(xml)
        #expect(spares.count == DomainXMLBuilder.spareHotplugPorts)
        // Never un-indexed, and never index 0 — which belongs to `pcie-root`.
        #expect(!xml.contains("<controller type='pci' model='pcie-root-port'/>"))
        let lowest = try #require(spares.min())
        let highest = try #require(spares.max())
        #expect(lowest > 0)
        // Contiguous, so the document does not depend on the gap fill to
        // produce the ports it names.
        #expect(spares == Array(lowest...highest))

        let devices = Self.pciDeviceCount(xml)
        #expect(highest - devices >= DomainXMLBuilder.spareHotplugPorts)
        // Property 1 from issue #1036: strictly more root ports than PCI
        // devices, which is what "a disk can still be plugged in" reduces to.
        #expect(lowest > devices)
    }

    /// The `index='N'` of every `pcie-root-port` the document declares.
    private static func rootPortIndexes(_ xml: String) -> [Int] {
        xml.components(separatedBy: "\n").compactMap { line in
            guard line.contains("model='pcie-root-port'") else { return nil }
            guard let start = line.range(of: "index='"),
                let end = line[start.upperBound...].firstIndex(of: "'")
            else { return nil }
            return Int(line[start.upperBound..<end])
        }
    }

    /// How many PCI endpoints `xml` declares — counted off the rendered
    /// document rather than through the builder's own classifier, so this is a
    /// check on the result and not on the code agreeing with itself.
    ///
    /// libvirt gives each of these a `pcie-root-port` of its own. The last term
    /// is the USB controller libvirt adds to a domain that declares none; it is
    /// `qemu-xhci` on these machine types, which is a PCIe endpoint too.
    private static func pciDeviceCount(_ xml: String) -> Int {
        func occurrences(_ needle: String) -> Int {
            xml.components(separatedBy: needle).count - 1
        }
        let usbControllers = occurrences("<controller type='usb'")
        return
            // Only disks carry `bus=`; a NIC's virtio-ness is a `<model type>`.
            occurrences("bus='virtio'")
            + occurrences("<interface ")
            + occurrences("<controller type='virtio-serial'")
            + usbControllers
            + occurrences("<memory model='virtio-mem'>")
            + (xml.contains("<memballoon model='virtio'") ? 1 : 0)
            + (xml.contains("<model type='none'/>") ? 0 : 1)  // <video>
            + (usbControllers == 0 ? 1 : 0)
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

    /// The varstore is qcow2 on every firmware path, and that is load-bearing
    /// rather than cosmetic: libvirt refuses an internal snapshot of a pflash
    /// guest whose varstore is raw, so a raw one silently costs `checkpointVM`
    /// — the capability the libvirt >= 11.5 floor exists for. STR-188 tracks
    /// the fact that this cannot currently be satisfied by autoselection on a
    /// host whose EDK2 descriptors are raw-only; whatever fixes it must keep
    /// this property.
    @Test("the varstore is qcow2 on every firmware path", arguments: scenarios)
    func varstoreIsAlwaysQcow2(_ scenario: Scenario) throws {
        let xml = try DomainXMLBuilder.build(scenario.input)
        guard let nvram = xml.range(of: "<nvram") else { return }  // direct kernel / monolithic
        // Attribute order differs between the branches (the `.pflash` one names
        // `template` first), so match inside the element rather than on a
        // prefix. `format=` appears nowhere else — disks spell it `type=`.
        let element = xml[nvram.lowerBound...].prefix(while: { $0 != ">" })
        #expect(element.contains("format='qcow2'"))
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
