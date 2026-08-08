import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The two properties of the domain document that **only real libvirt can
/// answer**, because neither is visible in the document the builder writes
/// (STR-192):
///
/// 1. the *defined* domain has strictly more `pcie-root-port`s than devices
///    occupying one, by at least `spareHotplugPorts`;
/// 2. a disk hot-plugs into that domain once it is running.
///
/// The RELAX-NG check in `DomainXMLBuilderTests` cannot see either: the document
/// that left every VM with zero free ports validated against the schema for as
/// long as it shipped. libvirt's own PCI address assignment is what decides, and
/// it runs at define time — so property 1 needs a daemon but no guest, and only
/// property 2 needs one to boot.
///
/// Every test here is **skipped rather than failed** where libvirt is absent,
/// the same bargain `validatesAgainstLibvirtSchema` makes: CI is a compile check
/// that never runs tests, so these are for a dev box, a hypervisor node, or the
/// manual `Full Test Suite` workflow. That bargain extends to what the host can
/// *emulate* — a scenario whose architecture this libvirt has no emulator for is
/// dropped from `defineableScenarios` rather than failed, since `virsh define`
/// refuses it outright and the developer cannot act on it. Firmware paths need
/// no such care: libvirt resolves a `<loader>` at start, not at define, and
/// defines a domain naming one that does not exist without complaint (checked on
/// 12.0.0), so the two goldens that hardcode Fedora-shaped paths are safe
/// everywhere.
///
///     STRATO_LIBVIRT_TEST_URI=qemu:///system \
///       swift test --package-path agent --filter DomainXMLLibvirtTests
///
/// Starting guests is opt-in on top of that (`STRATO_LIBVIRT_TEST_START=1`),
/// since it boots a real QEMU process, needs a firmware image on the host, and
/// takes seconds rather than milliseconds.
///
/// Measured against libvirt 12.0.0 — the version STR-192 was reported on — where
/// before the fix all nine goldens defined with **zero** free ports and a live
/// attach failed with "No more available PCI slots", and after it every one has
/// at least four.
@Suite("libvirt's own view of the domain document")
struct DomainXMLLibvirtTests {

    // MARK: - Reaching libvirt

    private static let uri =
        ProcessInfo.processInfo.environment["STRATO_LIBVIRT_TEST_URI"] ?? "qemu:///system"

    private static let virshPath: String? = {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return searchPath.components(separatedBy: ":")
            .map { ($0 as NSString).appendingPathComponent("virsh") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// A daemon that answers, not merely a `virsh` on `PATH`: the client is
    /// installed on plenty of hosts that run no hypervisor.
    private static let libvirtIsReachable: Bool = {
        guard virshPath != nil else { return false }
        return (try? run(["capabilities"]))?.status == 0
    }()

    private static let startsGuests =
        libvirtIsReachable && hostBootROM != nil
        && ProcessInfo.processInfo.environment["STRATO_LIBVIRT_TEST_START"] == "1"

    /// What this host's libvirt says about itself, read once.
    private static let capabilities: String = (try? run(["capabilities"]))?.output ?? ""

    /// The guest architectures this host can emulate.
    ///
    /// A scenario for an architecture missing from this set is not a document
    /// problem: `virsh define` refuses it outright with "unsupported
    /// configuration: No emulator found for arch 'aarch64'" on any host without
    /// `qemu-system-aarch64`, which is most x86 hypervisor nodes. Failing there
    /// would make the suite red for a host fact — and a suite that is red on a
    /// dev box for a reason the dev cannot act on is a suite that gets ignored,
    /// which for a change CI never tests is the worst outcome available.
    static let emulatableArchitectures: Set<CPUArchitecture> = {
        Set(
            CPUArchitecture.allCases.filter {
                capabilities.contains("<arch name='\(libvirtArchName($0))'>")
            })
    }()

    /// The host's own architecture, from `<host><cpu><arch>`.
    static let hostArchitecture: CPUArchitecture? = {
        guard let start = capabilities.range(of: "<arch>"),
            let end = capabilities.range(of: "</arch>", range: start.upperBound..<capabilities.endIndex)
        else { return nil }
        let name = String(capabilities[start.upperBound..<end.lowerBound])
        return CPUArchitecture.allCases.first { libvirtArchName($0) == name }
    }()

    /// libvirt's spelling, which is not the wire enum's: arm64 is `aarch64`.
    private static func libvirtArchName(_ architecture: CPUArchitecture) -> String {
        architecture == .arm64 ? "aarch64" : "x86_64"
    }

    /// The scenarios this host can define at all. `someScenariosAreDefineable`
    /// is what stops a broken capabilities parse from quietly emptying it.
    static let defineableScenarios = DomainXMLBuilderTests.scenarios.filter {
        emulatableArchitectures.contains($0.input.architecture)
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: virshPath ?? "/usr/bin/virsh")
        process.arguments = ["--connect", uri] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting, or a full pipe buffer deadlocks the child against
        // a parent that never drains it.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    // MARK: - Counting what libvirt decided

    /// The ports a defined domain has, and how many devices sit in one.
    ///
    /// Every device libvirt put in a root port carries an `<address type='pci'>`
    /// naming that port's bus; bus `0x00` is `pcie-root` itself, where the
    /// machine's integrated devices (q35's SATA and LPC, the primary
    /// framebuffer) live without consuming a port.
    ///
    /// **Devices, not distinct buses.** The two agree on every domain libvirt
    /// actually produces — it gives each device its own port — but they differ
    /// if it ever packs two into one, and then counting devices *understates*
    /// the free ports while counting buses overstates them. The assertion here
    /// is `free >= spareHotplugPorts`, so the metric's error has to point at
    /// failing the test rather than passing it.
    static func portCensus(_ dumped: String) -> (ports: Int, occupied: Int) {
        let ports = dumped.components(separatedBy: "model='pcie-root-port'").count - 1
        var occupied = 0
        for element in dumped.components(separatedBy: "<address type='pci'").dropFirst() {
            guard let start = element.range(of: "bus='"),
                let end = element[start.upperBound...].firstIndex(of: "'")
            else { continue }
            if element[start.upperBound..<end] != "0x00" { occupied += 1 }
        }
        return (ports, occupied)
    }

    /// Makes a golden defineable on whatever host is running the test, without
    /// touching a single device that takes a PCI slot — the only thing under
    /// test here.
    ///
    /// Three substitutions, each for a host fact rather than a document one: an
    /// accelerator the host may not have (the goldens' own note records the same
    /// swap), the firmware autoselect that no Debian/Ubuntu host can satisfy
    /// while the varstore is qcow2 (STR-188), and the TPM, which needs swtpm
    /// installed. None is a PCI device: the framebuffer, disks, NICs and
    /// controllers all survive verbatim.
    static func defineable(_ xml: String, name: String) -> String {
        var document = xml
        for accelerated in ["<domain type='kvm'>", "<domain type='hvf'>"] {
            document = document.replacingOccurrences(of: accelerated, with: "<domain type='qemu'>")
        }
        document = document.replacingOccurrences(
            of: "mode='host-passthrough'", with: "mode='maximum'")
        document = replacingElement("name", in: document, with: "<name>\(name)</name>")
        document = replacingElement("uuid", in: document, with: "")
        document = replacingElement("tpm", in: document, with: "")

        // Autoselect is only replaced where this host has a pair to replace it
        // with; where it does not, the document goes over as written and a
        // define failure is the honest answer.
        guard document.contains("<os firmware='efi'>"), let firmware = hostFirmware else {
            return document
        }
        document = document.replacingOccurrences(of: "<os firmware='efi'>", with: "<os>")
        document = replacingElement("firmware", in: document, with: "")
        // Secure Boot's SMM needs a `secure='yes'` loader, which the pair below
        // is not; neither is a device.
        document = document.replacingOccurrences(of: "\n    <smm state='on'/>", with: "")
        return replacingElement(
            "nvram", in: document,
            with: "<loader readonly='yes' type='pflash'>\(firmware.code)</loader>\n"
                + "<nvram template='\(firmware.varsTemplate)' format='raw'>"
                + "\(NSTemporaryDirectory())\(name).nvram</nvram>")
    }

    /// Removes or replaces an element, and the indentation ahead of it, without
    /// a parser. Every element this touches is one our own builder writes with a
    /// closing tag, so "from `<element` to `</element>`" is exact rather than a
    /// heuristic — and pulling in an XML dependency to delete three of them
    /// would be worse.
    private static func replacingElement(
        _ element: String, in document: String, with replacement: String
    ) -> String {
        guard let open = document.range(of: "<\(element)"),
            let close = document.range(
                of: "</\(element)>", range: open.upperBound..<document.endIndex)
        else { return document }

        var start = open.lowerBound
        while start > document.startIndex, document[document.index(before: start)] == " " {
            start = document.index(before: start)
        }
        let indent = String(document[start..<open.lowerBound])
        guard !replacement.isEmpty else {
            // The newline as well, or the removal leaves a blank line behind.
            let from =
                start > document.startIndex && document[document.index(before: start)] == "\n"
                ? document.index(before: start) : start
            return document.replacingCharacters(in: from..<close.upperBound, with: "")
        }
        return document.replacingCharacters(
            in: start..<close.upperBound,
            with: indent + replacement.replacingOccurrences(of: "\n", with: "\n" + indent))
    }

    /// The firmware pair to substitute for autoselect, if this host has one.
    ///
    /// The varstore written beside it is `raw`, not the `qcow2` every Strato
    /// document asks for: libvirt will not convert a raw template into a qcow2
    /// varstore ("conversion of the nvram template to another target format is
    /// not supported"), which is the same host gap STR-188 is about. The
    /// varstore's format is not a PCI device either, so the substitution costs
    /// this test nothing.
    static let hostFirmware: (code: String, varsTemplate: String)? = {
        let candidates = [
            ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
            ("/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
            ("/usr/share/qemu/ovmf-x86_64-code.bin", "/usr/share/qemu/ovmf-x86_64-vars.bin"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.0) && FileManager.default.fileExists(atPath: $0.1)
        }
    }()

    /// A single-blob firmware for the domain the hot-plug test boots, for this
    /// host's own architecture.
    ///
    /// `.monolithic` rather than the pair above, because a guest that only has
    /// to reach "no bootable device" and stay there needs no writable UEFI
    /// varstore — and skipping it skips every way a varstore can fail to be
    /// created on a host this test knows nothing about. On x86 that can be
    /// SeaBIOS, which ships with QEMU itself; `virt` has no BIOS and needs EDK2.
    static let hostBootROM: String? = hostArchitecture.flatMap { architecture in
        let candidates: [String]
        switch architecture {
        case .x86_64:
            candidates = [
                "/usr/share/qemu/bios-256k.bin", "/usr/share/seabios/bios-256k.bin",
                "/usr/share/qemu/bios.bin", "/usr/share/ovmf/OVMF.fd", "/usr/share/edk2/ovmf/OVMF.fd",
            ]
        case .arm64:
            candidates = [
                "/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
                "/usr/share/edk2/aarch64/QEMU_EFI.fd",
            ]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Property 1: the defined domain has ports nothing occupies

    /// Dropping a scenario this host cannot emulate is deliberate; dropping
    /// *every* scenario is a broken capabilities parse quietly turning the whole
    /// suite into a no-op, which would look exactly like passing.
    @Test(
        "this host can define at least the scenarios matching its own architecture",
        .enabled(if: libvirtIsReachable, "no libvirt daemon at STRATO_LIBVIRT_TEST_URI"))
    func someScenariosAreDefineable() throws {
        let architecture = try #require(
            Self.hostArchitecture, "libvirt reported no host architecture:\n\(Self.capabilities)")
        #expect(Self.emulatableArchitectures.contains(architecture))
        #expect(
            !Self.defineableScenarios.isEmpty,
            "no scenario matched \(Self.emulatableArchitectures), so nothing below tested anything")
    }

    @Test(
        "the defined domain keeps its spare root ports free",
        .enabled(if: libvirtIsReachable, "no libvirt daemon at STRATO_LIBVIRT_TEST_URI"),
        arguments: defineableScenarios)
    func definedDomainHasFreePorts(_ scenario: DomainXMLBuilderTests.Scenario) throws {
        let name = "strato-test-\(scenario.name)"
        let document = Self.defineable(try DomainXMLBuilder.build(scenario.input), name: name)
        let census = try Self.withDefinedDomain(name: name, document: document) {
            Self.portCensus($0)
        }

        #expect(
            census.ports - census.occupied >= DomainXMLBuilder.spareHotplugPorts,
            """
            \(scenario.name) defined with \(census.ports) root ports and \(census.occupied) \
            occupied, leaving \(census.ports - census.occupied) free — a hot-plug into this \
            domain fails with "No more available PCI slots"
            """)
    }

    /// The control that keeps the test above honest. Numbering is the whole
    /// mechanism, so the same document with its ports un-indexed — exactly what
    /// the builder emitted before STR-192 — must come back *short* of the spares
    /// it claims. Without this, a libvirt that generously over-allocated ports
    /// would make the assertion above pass for a reason that has nothing to do
    /// with the document.
    @Test(
        "un-indexed spare ports reserve nothing, which is the regression",
        .enabled(if: libvirtIsReachable, "no libvirt daemon at STRATO_LIBVIRT_TEST_URI"),
        arguments: defineableScenarios)
    func unindexedPortsReserveNothing(_ scenario: DomainXMLBuilderTests.Scenario) throws {
        let name = "strato-test-unindexed-\(scenario.name)"
        var document = Self.defineable(try DomainXMLBuilder.build(scenario.input), name: name)
        for index in DomainXMLBuilderTests.spareIndexes(scenario.input) {
            document = document.replacingOccurrences(
                of: "<controller type='pci' index='\(index)' model='pcie-root-port'/>",
                with: "<controller type='pci' model='pcie-root-port'/>")
        }
        let census = try Self.withDefinedDomain(name: name, document: document) {
            Self.portCensus($0)
        }

        #expect(census.ports - census.occupied < DomainXMLBuilder.spareHotplugPorts)
    }

    // MARK: - Property 2: a disk hot-plugs into the running domain

    /// The failure STR-192 was reported as, reproduced end to end: a running
    /// domain, `attach-device --live`, and libvirt's own allocator deciding
    /// whether there is a port to put the disk in. Nothing short of a live
    /// attach tests this — a `--config` attach against an inactive domain grows
    /// the bus and always succeeds, on a document with four free ports and on
    /// one with none alike.
    ///
    /// The domain is stripped down to what any libvirt host can boot: no NICs
    /// (their TAPs belong to the network reconciler), a small raw disk this test
    /// creates, and whatever firmware image the host already ships. The PCI
    /// topology is what matters, and it is the builder's throughout.
    @Test(
        "a disk hot-plugs into a running domain, and cannot without indexed spares",
        .enabled(if: startsGuests, "STRATO_LIBVIRT_TEST_START is not set"))
    func liveAttachFindsAFreePort() throws {
        // Both derived from the host rather than assumed, so the one test that
        // reproduces the reported failure runs on a hypervisor node of either
        // architecture. `startsGuests` already required the ROM.
        let bootROM = try #require(Self.hostBootROM)
        let architecture = try #require(Self.hostArchitecture)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("strato-hotplug-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let disk = directory.appendingPathComponent("disk.raw")
        let hotplugged = directory.appendingPathComponent("hotplug.raw")
        for path in [disk, hotplugged] {
            FileManager.default.createFile(atPath: path.path, contents: nil)
            try FileHandle(forWritingTo: path).truncate(atOffset: 1024 * 1024)
        }

        let input = DomainXMLInput(
            vmId: "strato-hotplug-test", vmDirectory: directory.path,
            spec: VMSpec(
                cpus: 1, memoryBytes: 1024 * 1024 * 1024, boot: .disk(firmware: nil),
                console: ConsoleSpec(console: .socket, serial: .socket)),
            disks: [ResolvedDisk(path: disk.path, format: .raw)],
            networks: [], architecture: architecture,
            accelerator: FileManager.default.fileExists(atPath: "/dev/kvm") ? .kvm : .tcg,
            firmware: .monolithic(path: bootROM))
        let fragment = DomainDeviceXML.hotplugDisk(
            path: hotplugged.path, format: .raw, target: "vdz", readonly: false,
            volumeId: "6b1c0a5e-7d2f-4a83-9e10-5c4b3a2d1f00")

        // The document as built, and the same one with its spares un-indexed:
        // the second is the control, and a run where both attach proves nothing.
        let built = Self.defineable(try DomainXMLBuilder.build(input), name: "strato-hotplug-test")
        var unindexed = built
        for index in DomainXMLBuilderTests.spareIndexes(input) {
            unindexed = unindexed.replacingOccurrences(
                of: "<controller type='pci' index='\(index)' model='pcie-root-port'/>",
                with: "<controller type='pci' model='pcie-root-port'/>")
        }

        #expect(try Self.attachesLive(fragment, to: built, named: "strato-hotplug-indexed"))
        #expect(try !Self.attachesLive(fragment, to: unindexed, named: "strato-hotplug-unindexed"))
    }

    private static func attachesLive(
        _ fragment: String, to document: String, named name: String
    ) throws -> Bool {
        try withDefinedDomain(
            name: name, document: replacingElement("name", in: document, with: "<name>\(name)</name>")
        ) { _ in
            let started = try run(["start", name])
            guard started.status == 0 else {
                Issue.record("\(name) would not start: \(started.output)")
                return false
            }
            // No `destroy` here: `withDefinedDomain` already does one on the way
            // out, and destroying a domain twice leaves libvirt waiting on a
            // transition that has already happened.
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(name)-device.xml")
            try fragment.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            return try run(["attach-device", name, file.path, "--live"]).status == 0
        }
    }

    /// Defines `document`, hands the resulting `dumpxml` to `body`, and undefines
    /// on every path — a leaked test domain is a domain the *next* run collides
    /// with by name.
    private static func withDefinedDomain<T>(
        name: String, document: String, _ body: (String) throws -> T
    ) throws -> T {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).xml")
        try document.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        // Destroy before undefining, both here and on the way out: a previous
        // run killed mid-test leaves a *running* domain, which `undefine`
        // refuses — and the next run then fails to define over it for a reason
        // that has nothing to do with the document.
        _ = try? run(["destroy", name])
        _ = try? run(["undefine", "--nvram", name])
        let defined = try run(["define", file.path])
        guard defined.status == 0 else {
            Issue.record("libvirt refused the document for \(name):\n\(defined.output)")
            throw LibvirtTestError.defineFailed(defined.output)
        }
        defer {
            _ = try? run(["destroy", name])
            _ = try? run(["undefine", "--nvram", name])
        }
        return try body(try run(["dumpxml", name]).output)
    }

    enum LibvirtTestError: Error {
        case defineFailed(String)
    }
}
