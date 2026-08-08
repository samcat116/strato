import Foundation
import StratoShared

/// Which accelerator the domain runs under, selecting `<domain type=…>` and the
/// `<cpu>` model. A parameter rather than a compile-time platform check, so
/// both the accelerated and the TCG document are assertable from one host.
public enum DomainAccelerator: String, Sendable, CaseIterable {
    case kvm
    case hvf
    case tcg

    /// libvirt's domain type. `tcg` is not one: plain QEMU emulation is
    /// `type='qemu'`, with the CPU model carrying the difference.
    var domainType: String {
        switch self {
        case .kvm: return "kvm"
        case .hvf: return "hvf"
        case .tcg: return "qemu"
        }
    }

    /// `host-passthrough` is libvirt's spelling of `-cpu host`, which is only
    /// valid with a hardware accelerator. Under TCG we fall back to `maximum`
    /// (`-cpu max`), the most capable model the emulator can offer.
    var cpuMode: String {
        switch self {
        case .kvm, .hvf: return "host-passthrough"
        case .tcg: return "maximum"
        }
    }
}

/// Everything a libvirt domain document needs, already resolved on this host.
///
/// The builder that consumes this touches no filesystem, so every path here is
/// one the caller decided on — including paths that do not exist yet, like the
/// UEFI varstore libvirt is about to create.
public struct DomainXMLInput: Sendable {
    /// The VM's id. Becomes `<name>`, and `<uuid>` when it parses as one.
    public var vmId: String
    /// `<vmStoragePath>/<vmId>`: the directory holding this VM's sockets and
    /// varstore. Passed in rather than derived, so the builder never assembles
    /// a path it cannot see.
    public var vmDirectory: String
    public var spec: VMSpec
    public var disks: [ResolvedDisk]
    /// The NoCloud seed ISO, when guest provisioning produced one.
    public var cloudInitISOPath: String?
    public var networks: [ResolvedNetworkAttachment]
    /// Guest architecture. A parameter, never `#if arch`, so both branches are
    /// assertable from one host (the `QEMUGraphicsDevice` convention).
    public var architecture: CPUArchitecture
    public var accelerator: DomainAccelerator
    /// The firmware set this host resolved, from `FirmwareResolver`. **The
    /// normal case is a `.pflash` pair**; nil falls back to libvirt's own
    /// autoselection and only happens where the resolver matched nothing at all
    /// (`FirmwareResolver.domainFirmware`).
    ///
    /// A `.pflash` set carries an obligation the builder cannot check and does
    /// not try to: **the varstore at `VMDirectoryLayout.nvram(vmDirectory:)`
    /// must already exist** by the time the domain starts, because the document
    /// names it with no `template` to seed from. `UEFIVarstore` is what puts it
    /// there; `LibvirtService.createVM` is where the two are sequenced.
    public var firmware: FirmwareSet?
    /// `<emulator>` override. Omitted when nil, letting libvirt choose from its
    /// own capabilities.
    public var emulatorPath: String?

    public init(
        vmId: String,
        vmDirectory: String,
        spec: VMSpec,
        disks: [ResolvedDisk] = [],
        cloudInitISOPath: String? = nil,
        networks: [ResolvedNetworkAttachment] = [],
        architecture: CPUArchitecture,
        accelerator: DomainAccelerator,
        firmware: FirmwareSet? = nil,
        emulatorPath: String? = nil
    ) {
        self.vmId = vmId
        self.vmDirectory = vmDirectory
        self.spec = spec
        self.disks = disks
        self.cloudInitISOPath = cloudInitISOPath
        self.networks = networks
        self.architecture = architecture
        self.accelerator = accelerator
        self.firmware = firmware
        self.emulatorPath = emulatorPath
    }
}

public enum DomainXMLBuilderError: Error, Equatable, CustomStringConvertible {
    /// libvirt does have `<interface type='user'>`, but Strato's user-mode
    /// networking is the macOS-only SLIRP fallback, which the libvirt driver
    /// does not cover and no spike validated. Refusing beats emitting an
    /// interface nobody has ever booted.
    case unsupportedNetworkAttachment(network: String)
    /// A domain name libvirt cannot hold.
    case invalidDomainName(String)
    /// A vCPU count libvirt will not accept. Nothing normalizes `VMSpec`, so a
    /// zero reaches here as `<vcpu>0</vcpu>` and fails the define with an error
    /// naming the element rather than the spec that produced it.
    case invalidCPUCount(Int)
    /// Likewise for a memory size of zero, which libvirt rejects with "Memory
    /// size must be specified via <memory> or in the <numa> configuration".
    case invalidMemorySize(Int64)

    public var description: String {
        switch self {
        case .unsupportedNetworkAttachment(let network):
            return
                "network '\(network)' uses user-mode networking, which the libvirt driver does not support; "
                + "only tap attachments can be realized as a libvirt domain interface"
        case .invalidDomainName(let name):
            return "'\(name)' is not a usable libvirt domain name (it must be non-empty and contain no '/')"
        case .invalidCPUCount(let cpus):
            return "a domain needs at least one vCPU; the spec asked for \(cpus)"
        case .invalidMemorySize(let bytes):
            return "a domain needs a non-zero memory size; the spec asked for \(bytes) bytes"
        }
    }
}

/// Translates a `VMSpec` and its host-resolved disks and NICs into a libvirt
/// domain XML document.
///
/// This is the libvirt counterpart of the process driver's argv assembly.
/// It lives in the core library for the reason `QEMUGraphicsDevice` and
/// `QEMUGraphicsDevice` give: the driver that will call it links a hypervisor
/// SDK and therefore has no unit tests, and a device the hypervisor rejects
/// kills every VM boot on the host while surfacing only as an opaque timeout
/// (issue #740). swift-libvirt deliberately models no domain XML — you hand it
/// strings — so this document is ours to own, and the golden tests beside it
/// are the only thing standing between a typo and every create on a node
/// failing.
///
/// The builder is a **pure total function**: no `FileManager`, no `#if arch`,
/// no firmware resolution, no socket cleanup. The QEMU path interleaves those
/// side effects with argument assembly; under libvirt most of them stop being
/// the agent's job at all (libvirt creates the varstore and supervises swtpm),
/// and the rest belong to the caller. Purity is also what makes a golden file
/// meaningful — anything nondeterministic in here would make it a liability.
///
/// ## Deliberately not emitted
///
/// - **`<seclabel>`.** The spike settled this: rather than suppressing
///   labelling, hypervisor nodes set `user`/`group` in `/etc/libvirt/qemu.conf`
///   to the agent's account and leave `dynamic_ownership = 1`, so relabelling
///   is a no-op on files the agent already owns *and* libvirt still prepares
///   its own runtime artifacts. Suppressing it instead breaks swtpm. Do not add
///   a `<seclabel>` element here.
/// - **The paused-at-create behaviour.** `-S` has no document form and needs
///   none: `LibvirtService` creates with `domainDefineXML`, which leaves the
///   domain `SHUTOFF` and satisfies the create contract's "exists, not running"
///   (issue #260) directly. A driver that reached for `domainCreateXML` instead
///   would define *and start* a transient domain — every fresh VM booting once,
///   with the next periodic sync shutting it down again, and nothing left for an
///   agent restart to adopt.
/// - **The three QMP monitors.** libvirt owns the monitor; re-adoption and the
///   balloon-stats probe become libvirt API calls, not sockets.
/// - **`<memoryBacking>`.** `spec.sharedMemory` and `spec.hugepages` are read
///   nowhere in the QEMU path either, so honouring them here would smuggle a
///   behaviour change into a translation. When they are implemented they become
///   `<memoryBacking><hugepages/><access mode='shared'/></memoryBacking>`.
/// - `<rng>`, `<pm>`, `<metadata>`, `<alias>`, and any `<qemu:commandline>`
///   passthrough.
///
/// ## Spare PCIe root ports are emitted, and their indexes are the mechanism
///
/// libvirt adds a `pcie-root-port` per PCI device the document declares, so a
/// domain built from only the devices a VM needs has **no free slot** and
/// `virDomainAttachDeviceFlags` fails a disk hot-plug with "No more available
/// PCI slots". The ports have to be in the document before the domain is
/// defined, so `spareHotplugPorts` is a ceiling on how many volumes a VM can be
/// given **while it is running** (STR-134).
///
/// It is no longer a ceiling for the VM's whole life. `DomainRedefinition` tops
/// the spares back up on a stopped domain, and `LibvirtService.redefineVM` runs
/// it before every boot, so a VM that has used all four gets four more by being
/// stopped and started (STR-187). An attach to a *stopped* VM was never bounded
/// by this at all: that one carries `AFFECT_CONFIG` alone, and libvirt grows the
/// bus in the persistent definition itself, adding a port for the disk (measured
/// on 12.0.0, on a domain whose every port was occupied).
///
/// **Declaring the ports is not enough; they have to be numbered.** An
/// un-indexed `pcie-root-port` is numbered by libvirt out of the very range it
/// was going to allocate for the domain's own devices, and then *used for one of
/// them*: it pre-declares part of the allocation rather than adding to it. On
/// libvirt 12.0.0, a domain of one disk, virtio-serial and a memballoon comes up
/// with five ports and four occupied when it declares none, and with four ports
/// and four occupied when it declares four un-indexed — un-indexed spares leave
/// a domain with *fewer* free ports than declaring nothing at all, which is why
/// every hot-plug failed with the ceiling nominally set to four (STR-192).
///
/// What works is an explicit index past everything libvirt will auto-assign,
/// which is what `spareHotplugPortIndexes` computes. libvirt materializes every
/// index below the highest one declared, so the top index *is* the port count
/// and the devices fill in from the bottom; the spares are whatever is left over
/// the top. They cost little: libvirt packs eight ports into one `pcie-root`
/// slot as functions of a multifunction device.
///
/// ## Known divergence from the QEMU command line
///
/// The balloon is emitted with free-page **reporting**, where the QEMU path
/// sets free-page **hinting** plus the dedicated iothread that hinting makes
/// mandatory (issue #740). Hinting has no libvirt schema element and would
/// require a `<qemu:commandline>` escape hatch; reporting is the mechanism that
/// actually returns freed guest pages to the host, which is what that code
/// wanted in the first place.
public enum DomainXMLBuilder {

    /// How many empty `pcie-root-port`s every domain carries for later
    /// hot-plug. Each costs a little guest address space, so this trades the
    /// ceiling described above against what the guest can still boot with; four
    /// is well clear of the one or two volumes a VM typically gains after
    /// creation and nowhere near the port count that stops a domain starting.
    public static let spareHotplugPorts = 4

    /// Ports the defined domain occupies for devices this document never
    /// declared, added to the count below before the spares are numbered.
    ///
    /// One is measured: a q35 domain that declares no USB controller has a
    /// `qemu-xhci` added for it, and that controller takes a root port like any
    /// other PCI device — on libvirt 12.0.0 it is the entire difference between
    /// `declaredPCIDeviceCount` and the ports a defined domain occupies, on
    /// every golden. (The `virt` machine adds nothing.) The second is margin: a
    /// libvirt version that auto-adds one device more than this one costs a
    /// spare port rather than the whole mechanism.
    static let implicitPortAllowance = 2

    /// The highest port index the builder will number a spare with.
    ///
    /// There is no define-time limit to bump into — libvirt 12.0.0 defines a
    /// domain declaring index 240 without complaint — but there is a *start*
    /// one: each port reserves guest I/O and MMIO windows, and the same domain
    /// at 240 ports fails to start while 60 starts fine. This is far above the
    /// device count of any VM Strato places, so it never binds in practice; it
    /// exists so that a pathological one loses its spare ports rather than its
    /// ability to boot.
    static let rootPortIndexCeiling = 32

    /// The domain document for `input`, ready for `virDomainDefineXML`.
    public static func build(_ input: DomainXMLInput) throws -> String {
        guard !input.vmId.isEmpty, !input.vmId.contains("/") else {
            throw DomainXMLBuilderError.invalidDomainName(input.vmId)
        }
        guard input.spec.cpus > 0 else {
            throw DomainXMLBuilderError.invalidCPUCount(input.spec.cpus)
        }
        guard input.spec.memoryBytes > 0 else {
            throw DomainXMLBuilderError.invalidMemorySize(input.spec.memoryBytes)
        }

        let spec = input.spec
        let machine = spec.effectiveMachine
        let hotplugBytes = MemoryHotplugPlan.alignedHotplugBytes(
            spec: spec, architecture: input.architecture)
        let totalMemoryBytes = spec.memoryBytes + hotplugBytes
        // A spec decoded straight off the wire is not guaranteed to have
        // maxCpus >= cpus, and libvirt rejects a `current` above the maximum.
        let maxCpus = max(spec.maxCpus, spec.cpus)

        var domain = DomainXMLNode("domain", [("type", input.accelerator.domainType)])
        domain.append(DomainXMLNode("name", text: input.vmId))
        // Emitted only when the id really is a UUID, and lowercased because
        // that is how libvirt echoes it back — keeping a later `virsh dumpxml`
        // diffable against what we defined.
        if let uuid = UUID(uuidString: input.vmId) {
            domain.append(DomainXMLNode("uuid", text: uuid.uuidString.lowercased()))
        }

        // Memory. libvirt inverts QEMU's split, and getting it wrong is not a
        // subtle failure: `<memory>` is the *total* including every memory
        // device, `<currentMemory>` is what the guest boots with. Carrying
        // `-m <boot>,maxmem=<total>` over verbatim makes libvirt compute an
        // initial size of zero and reject the domain with a message that names
        // neither the cause nor the device that caused it.
        if hotplugBytes > 0 {
            domain.append(
                DomainXMLNode(
                    "maxMemory", [("slots", "1"), ("unit", "KiB")], text: kib(totalMemoryBytes)))
        }
        domain.append(DomainXMLNode("memory", [("unit", "KiB")], text: kib(totalMemoryBytes)))
        domain.append(
            DomainXMLNode("currentMemory", [("unit", "KiB")], text: kib(spec.memoryBytes)))

        domain.append(
            DomainXMLNode(
                "vcpu",
                [("placement", "static"), ("current", maxCpus > spec.cpus ? "\(spec.cpus)" : nil)],
                text: "\(maxCpus)"))

        domain.append(osNode(input, machine: machine))
        domain.append(featuresNode(input, machine: machine))
        domain.append(cpuNode(input, hotplugBytes: hotplugBytes, maxCpus: maxCpus))

        // libvirt's own defaults, stated explicitly because the reconciler
        // depends on them: a guest shutdown must stop the domain (so the agent
        // observes `shutdown`), and a guest reboot must not.
        //
        // `on_crash` is `destroy` for a third reason, and changing it is not
        // just a policy tweak: under `preserve` libvirt keeps a panicked domain
        // *and its QEMU process* alive in `VIR_DOMAIN_CRASHED`. Anything that
        // reads a crashed domain as stopped would then be reasoning about a live
        // guest — see `LibvirtDomain.State.holdsResources`, which counts it as
        // holding for exactly that reason.
        domain.append(DomainXMLNode("clock", [("offset", "utc")]))
        domain.append(DomainXMLNode("on_poweroff", text: "destroy"))
        domain.append(DomainXMLNode("on_reboot", text: "restart"))
        domain.append(DomainXMLNode("on_crash", text: "destroy"))

        domain.append(try devicesNode(input, machine: machine, hotplugBytes: hotplugBytes))

        return domain.render()
    }

    // MARK: - Operating system and firmware

    private static func osNode(_ input: DomainXMLInput, machine: MachineProfile) -> DomainXMLNode {
        var kernelBoot: (kernel: String, initramfs: String?, cmdline: String?)?
        switch input.spec.boot {
        case .directKernel(let kernel, let initramfs, let cmdline):
            kernelBoot = (kernel, initramfs, cmdline)
        case .disk:
            kernelBoot = nil
        }

        // `firmware='efi'` asks libvirt to pick a firmware from its installed
        // descriptors; it is mutually exclusive with naming one ourselves. It
        // is also the *fallback* rather than the norm — see
        // `DomainXMLInput.firmware`, and the `.none` branch below for what it
        // costs on a host whose descriptors declare a raw varstore.
        let autoselectFirmware = kernelBoot == nil && input.firmware == nil
        var os = DomainXMLNode("os", [("firmware", autoselectFirmware ? "efi" : nil)])
        os.append(
            DomainXMLNode(
                "type",
                [("arch", libvirtArch(input.architecture)), ("machine", machineType(input.architecture))],
                text: "hvm"))

        if let kernelBoot {
            os.append(DomainXMLNode("kernel", text: kernelBoot.kernel))
            if let initramfs = kernelBoot.initramfs {
                os.append(DomainXMLNode("initrd", text: initramfs))
            }
            os.append(DomainXMLNode("cmdline", text: kernelCommandLine(kernelBoot.cmdline)))
            return os
        }

        // Secure Boot on x86 needs the varstore pflash marked SMM-only, which
        // is what stops a compromised guest rewriting `db`/`dbx`. `secure='yes'`
        // is libvirt's whole spelling of that; it pairs with `<smm state='on'/>`
        // in `<features>`. ARM's `virt` machine has no SMM and needs neither.
        let secureLoader = input.architecture == .x86_64 && machine.secureBoot

        switch input.firmware {
        case .none:
            // Both features are stated explicitly, including the disabled case:
            // leaving them out lets libvirt's descriptor ranking decide, which
            // could hand a non-Secure-Boot VM a Secure Boot firmware (or the
            // reverse) depending on what the host has installed.
            os.append(
                DomainXMLNode(
                    "firmware",
                    children: [
                        DomainXMLNode(
                            "feature",
                            [
                                ("enabled", machine.secureBoot ? "yes" : "no"),
                                ("name", "enrolled-keys"),
                            ]),
                        DomainXMLNode(
                            "feature",
                            [
                                ("enabled", machine.secureBoot ? "yes" : "no"),
                                ("name", "secure-boot"),
                            ]),
                    ]))
            // No `template`: the selected descriptor names the variable store
            // to seed from. libvirt creates the file itself, which is why the
            // builder can emit a path that does not exist yet.
            //
            // The format stays qcow2 even here, where it is the reason this
            // branch cannot be satisfied on Debian or Ubuntu — libvirt matches
            // the requested format against its descriptors at define time, and
            // every EDK2 descriptor those ship declares `raw` (STR-188).
            // Dropping it would make the define succeed and disable VM
            // checkpoints, which is the trade this whole path exists to avoid;
            // reaching this branch at all means the resolver found no pair to
            // name, so there is nothing better available.
            os.append(
                DomainXMLNode(
                    "nvram", [("format", "qcow2")],
                    text: VMDirectoryLayout.nvram(vmDirectory: input.vmDirectory)))
        case .pflash(let code, _):
            os.append(
                DomainXMLNode(
                    "loader",
                    [("readonly", "yes"), ("secure", secureLoader ? "yes" : nil), ("type", "pflash")],
                    text: code))
            // **No `template`, and the varstore must already exist** — see
            // `DomainXMLInput.firmware`. Naming the set's `varsTemplate` here
            // is what the document used to do, and it defines but does not
            // start on any host whose template is raw: libvirt seeds the
            // varstore at start and refuses to change its format on the way
            // ("conversion of the nvram template to another target format is
            // not supported"). A file that is already there is never seeded, so
            // it is never converted (STR-188).
            os.append(
                DomainXMLNode(
                    "nvram", [("format", "qcow2")],
                    text: VMDirectoryLayout.nvram(vmDirectory: input.vmDirectory)))
        case .monolithic(let path):
            // libvirt's `-bios`: no writable varstore, so the guest's UEFI
            // variables reset on every start. Kept only for hosts that ship
            // nothing else.
            os.append(DomainXMLNode("loader", [("readonly", "yes"), ("type", "rom")], text: path))
        }
        return os
    }

    /// The console arguments the QEMU path forces into every direct-kernel
    /// command line, so a guest's early output reaches one of the sockets the
    /// agent is listening on whichever console its kernel picks.
    static func kernelCommandLine(_ cmdline: String?) -> String {
        let consoleArgs = [
            "console=tty0",
            "console=ttyS0,115200",
            "console=ttyAMA0,115200",
            "console=hvc0",
        ]
        var result = cmdline ?? ""
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return consoleArgs.joined(separator: " ")
        }
        for arg in consoleArgs where !result.contains(arg) {
            result.append(" \(arg)")
        }
        return result
    }

    // MARK: - Machine features and CPU

    private static func featuresNode(_ input: DomainXMLInput, machine: MachineProfile) -> DomainXMLNode? {
        let uefiBoot: Bool
        if case .disk = input.spec.boot { uefiBoot = true } else { uefiBoot = false }

        var features = DomainXMLNode("features")
        // ACPI is unconditional on x86, but on aarch64 libvirt only accepts it
        // alongside UEFI firmware — a direct-kernel domain carrying `<acpi/>`
        // is rejected outright with "ACPI requires UEFI on this architecture"
        // (libvirt 11.6.0).
        if input.architecture == .x86_64 || uefiBoot {
            features.append(DomainXMLNode("acpi"))
        }
        if input.architecture == .x86_64 {
            features.append(DomainXMLNode("apic"))
            if machine.secureBoot {
                features.append(DomainXMLNode("smm", [("state", "on")]))
            }
        } else if uefiBoot {
            // The QEMU path asks for `virt,gic-version=3` on UEFI boot only —
            // EDK2 needs GICv3 — and plain `virt` for direct kernel boot. The
            // asymmetry is reproduced rather than tidied up, so this stays a
            // translation.
            features.append(DomainXMLNode("gic", [("version", "3")]))
        }
        // An arm64 direct-kernel domain has no features at all; an empty
        // element would only be noise.
        return features.children.isEmpty ? nil : features
    }

    private static func cpuNode(
        _ input: DomainXMLInput, hotplugBytes: Int64, maxCpus: Int
    ) -> DomainXMLNode {
        // `check='none'` keeps libvirt from refusing to start a domain whose
        // passed-through model it cannot verify against its CPU map.
        var cpu = DomainXMLNode("cpu", [("mode", input.accelerator.cpuMode), ("check", "none")])
        guard hotplugBytes > 0 else { return cpu }

        // libvirt requires a NUMA topology whenever memory hotplug is enabled;
        // QEMU accepts `maxmem=` plus virtio-mem without one. The cell holds
        // the *boot* memory — the hot-pluggable region is the device's — and
        // its cpu range must cover every vCPU the domain can grow to.
        let cpuRange = maxCpus > 1 ? "0-\(maxCpus - 1)" : "0"
        cpu.append(
            DomainXMLNode(
                "numa",
                children: [
                    DomainXMLNode(
                        "cell",
                        [
                            ("id", "0"), ("cpus", cpuRange),
                            ("memory", kib(input.spec.memoryBytes)), ("unit", "KiB"),
                        ])
                ]))
        return cpu
    }

    // MARK: - Devices

    private static func devicesNode(
        _ input: DomainXMLInput, machine: MachineProfile, hotplugBytes: Int64
    ) throws -> DomainXMLNode {
        var devices = DomainXMLNode("devices")
        let graphics = input.spec.console?.effectiveGraphics == .vnc

        if let emulatorPath = input.emulatorPath {
            devices.append(DomainXMLNode("emulator", text: emulatorPath))
        }

        // A boot element is emitted only where the control plane actually
        // expressed an order. Mixing per-device `<boot order>` with `<os><boot
        // dev>` is rejected by libvirt, and emitting neither is faithful: the
        // QEMU path passes no `-boot` and lets firmware choose.
        let bootOrders = derivedBootOrders(input.disks)
        for (index, disk) in input.disks.enumerated() {
            devices.append(
                diskNode(
                    path: disk.path, format: disk.format.rawValue, index: index,
                    readonly: disk.readonly, bootOrder: bootOrders[index],
                    volumeId: disk.volumeId))
        }
        if let isoPath = input.cloudInitISOPath {
            // A read-only virtio *disk*, not a cdrom, matching the QEMU path's
            // `-drive …,if=virtio,readonly=on`. It is always last, so its
            // presence can never shift a data disk's target name.
            devices.append(
                diskNode(
                    path: isoPath, format: "raw", index: input.disks.count, readonly: true,
                    bootOrder: nil, volumeId: nil))
        }

        // The root complex itself, declared before any port hangs off it. Both
        // machine types the builder emits (q35, virt) reserve PCI controller
        // index 0 for `pcie-root`, and libvirt numbers un-indexed controllers
        // from 0 — so without this the first spare port below claims index 0
        // and the whole document is rejected. libvirt's implicit-controller
        // pass would add this, but it runs after the validation that rejects.
        devices.append(DomainXMLNode("controller", [("type", "pci"), ("index", "0"), ("model", "pcie-root")]))

        // Empty PCIe root ports for later hot-plug. See the type's note: these
        // cannot be added to a domain after it is defined, and without them
        // every disk hot-plug fails on a full root complex.
        for index in spareHotplugPortIndexes(input, hotplugBytes: hotplugBytes) {
            // The index is the whole mechanism. Left off, libvirt numbers these
            // from the range it was going to allocate for the devices above and
            // then puts those devices in them, leaving nothing free; numbered
            // past that range, they are ports nothing has claimed.
            devices.append(
                DomainXMLNode(
                    "controller", [("type", "pci"), ("index", "\(index)"), ("model", "pcie-root-port")]))
        }

        // libvirt would add both controllers implicitly; declaring them pins
        // index 0 and keeps the document stable across libvirt versions that
        // differ in what they auto-add.
        devices.append(DomainXMLNode("controller", [("type", "virtio-serial"), ("index", "0")]))
        if graphics {
            devices.append(
                DomainXMLNode(
                    "controller",
                    [("type", "usb"), ("index", "0"), ("model", QEMUGraphicsDevice.usbControllerModel)]))
        }

        for nic in input.networks {
            devices.append(try interfaceNode(nic))
        }

        // All three sockets are named explicitly. libvirt honours the paths
        // rather than relocating them under its own runtime directory, which is
        // what lets ConsoleSocketManager survive the migration untouched.
        // `mode='bind'` means the hypervisor listens and the agent connects —
        // the same direction as the QEMU path's `server=on,wait=off`.
        devices.append(
            DomainXMLNode(
                "serial", [("type", "unix")],
                children: [
                    unixSource(VMDirectoryLayout.serialSocket(vmDirectory: input.vmDirectory)),
                    // Left bare: libvirt fills in isa-serial on x86 and pl011
                    // on aarch64, which is arch-dependence we would rather not
                    // hand-encode.
                    DomainXMLNode("target", [("port", "0")]),
                ]))
        devices.append(
            DomainXMLNode(
                "console", [("type", "unix")],
                children: [
                    unixSource(VMDirectoryLayout.consoleSocket(vmDirectory: input.vmDirectory)),
                    // `type='virtio'` is hvc0. With `type='serial'` this would
                    // alias the serial device above and the two sockets would
                    // collide.
                    DomainXMLNode("target", [("type", "virtio"), ("port", "0")]),
                ]))
        devices.append(
            DomainXMLNode(
                "channel", [("type", "unix")],
                children: [
                    unixSource(VMDirectoryLayout.guestAgentSocket(vmDirectory: input.vmDirectory)),
                    DomainXMLNode(
                        "target", [("type", "virtio"), ("name", "org.qemu.guest_agent.0")]),
                ]))

        if graphics {
            // A unix socket in the VM's directory, never a TCP listener: the
            // socket's file mode plus the control plane's `view_console`
            // authorization are the security boundary, and the console carries
            // no RFB password. There must be no port or listen address here.
            devices.append(
                DomainXMLNode(
                    "graphics", [("type", "vnc")],
                    children: [
                        DomainXMLNode(
                            "listen",
                            [
                                ("type", "socket"),
                                ("socket", QEMUGraphicsDevice.socketPath(vmDirectory: input.vmDirectory)),
                            ])
                    ]))
        }
        devices.append(videoNode(architecture: input.architecture, graphics: graphics))
        if graphics {
            // Absolute pointer positions, so the guest cursor tracks the
            // browser's instead of drifting; and a USB keyboard on every
            // architecture, because `virt` creates no input devices at all and
            // an aarch64 guest would otherwise render and click while dropping
            // every keystroke.
            devices.append(DomainXMLNode("input", [("type", "tablet"), ("bus", "usb")]))
            devices.append(DomainXMLNode("input", [("type", "keyboard"), ("bus", "usb")]))
        }

        if machine.tpm {
            // `tpm-tis` on both architectures: libvirt's model vocabulary has
            // no `tpm-tis-device`, and it selects QEMU's MMIO variant itself on
            // aarch64. No socket and no supervisor either — libvirt runs swtpm.
            devices.append(
                DomainXMLNode(
                    "tpm", [("model", "tpm-tis")],
                    children: [DomainXMLNode("backend", [("type", "emulator"), ("version", "2.0")])]))
        }

        // Free-page reporting, not the QEMU path's free-page hinting — see the
        // type's note. Reporting needs no iothread, so the device that made one
        // mandatory disappears with it.
        devices.append(DomainXMLNode("memballoon", [("model", "virtio"), ("freePageReporting", "on")]))

        if hotplugBytes > 0 {
            // Nothing plugged in at boot; a resize raises `<requested>` through
            // `virDomainUpdateDeviceFlags` with the same element.
            devices.append(
                memoryDeviceNode(
                    sizeBytes: hotplugBytes,
                    blockBytes: MemoryHotplugPlan.blockBytes(architecture: input.architecture),
                    requestedBytes: 0))
        }

        return devices
    }

    /// The `<memory model='virtio-mem'>` device.
    ///
    /// Shared with the resize path (`DomainDeviceXML.memoryDevice`), which
    /// updates the device by handing libvirt this same element with a new
    /// `<requested>`. libvirt matches an update against the device's *identity*
    /// — model, target node, size and block size — so a fragment assembled
    /// anywhere but here would silently fail to match the device it meant to
    /// grow. Sizes are parameters rather than derived for the same reason: the
    /// resize path reads the domain's real ones back rather than recomputing
    /// what a newer spec would have asked for.
    static func memoryDeviceNode(
        sizeBytes: Int64, blockBytes: Int64, requestedBytes: Int64
    ) -> DomainXMLNode {
        DomainXMLNode(
            "memory", [("model", "virtio-mem")],
            children: [
                DomainXMLNode(
                    "target",
                    children: [
                        DomainXMLNode("size", [("unit", "KiB")], text: kib(sizeBytes)),
                        // Points at the single NUMA cell `cpuNode` emits, which
                        // libvirt requires for a hot-pluggable device.
                        DomainXMLNode("node", text: "0"),
                        DomainXMLNode("block", [("unit", "KiB")], text: kib(blockBytes)),
                        DomainXMLNode("requested", [("unit", "KiB")], text: kib(requestedBytes)),
                    ])
            ])
    }

    /// How many PCI slots the devices this document declares will occupy.
    ///
    /// This is what the spare ports are numbered from, so it is deliberately an
    /// **over-estimate rather than an exact count**: a device counted here that
    /// libvirt turns out to place elsewhere costs one spare port, while a device
    /// missed costs a *free* one — which is the failure the whole mechanism
    /// exists to prevent. The framebuffer is the case in point, and is counted
    /// on both architectures: q35 puts it on `pcie-root` at 00:01.0, `virt`
    /// gives it a port of its own.
    ///
    /// Devices that take no PCI slot at all are excluded: `<serial>`,
    /// `<console>` and `<channel>` ride the virtio-serial controller, the
    /// `<input>` devices ride the USB one, `<graphics>` describes the
    /// framebuffer rather than being a device, and `tpm-tis` is ISA (MMIO on
    /// `virt`). Nothing here is a guess — every one was read off a `dumpxml` of
    /// the goldens defined against libvirt 12.0.0.
    static func declaredPCIDeviceCount(_ input: DomainXMLInput, hotplugBytes: Int64) -> Int {
        let graphics = input.spec.console?.effectiveGraphics == .vnc
        return input.disks.count
            + (input.cloudInitISOPath == nil ? 0 : 1)
            + input.networks.count
            + 1  // virtio-serial
            + (graphics ? 2 : 0)  // qemu-xhci, and the framebuffer
            + 1  // memballoon
            + (hotplugBytes > 0 ? 1 : 0)  // virtio-mem
    }

    /// The indexes the spare `pcie-root-port`s take: `spareHotplugPorts` of
    /// them, starting one past every port the defined domain will occupy.
    ///
    /// Index 0 is `pcie-root` itself, declared just above them (STR-189), so the
    /// first port a domain could have is 1 and the first *free* one is one past
    /// the occupied count. Empty when even the first spare would sit above
    /// `rootPortIndexCeiling`, and short of `spareHotplugPorts` where only some
    /// of them fit — a VM that big has other problems, and losing spare ports is
    /// a better failure than losing the boot.
    static func spareHotplugPortIndexes(
        _ input: DomainXMLInput, hotplugBytes: Int64
    ) -> Range<Int> {
        let first = declaredPCIDeviceCount(input, hotplugBytes: hotplugBytes) + implicitPortAllowance + 1
        let end = min(first + spareHotplugPorts, rootPortIndexCeiling + 1)
        return first..<max(first, end)
    }

    /// How many spare ports the document for `input` will actually carry —
    /// `spareHotplugPorts` in every ordinary case, fewer where the VM's own
    /// devices reach the ceiling.
    ///
    /// Exposed so the driver can *say so at define time*. A shortfall here is
    /// permanent for that VM and its only other symptom is the bare "No more
    /// available PCI slots" this whole mechanism exists to prevent — which,
    /// unremarked, is indistinguishable from the bug (STR-192).
    public static func reservedHotplugPortCount(_ input: DomainXMLInput) -> Int {
        spareHotplugPortIndexes(
            input,
            hotplugBytes: MemoryHotplugPlan.alignedHotplugBytes(
                spec: input.spec, architecture: input.architecture)
        ).count
    }

    /// The `<boot order>` for each disk, or nil where none should be emitted.
    ///
    /// The stored value is used only as a flag — *this disk was given an order*
    /// — and never copied through, because nothing keeps it valid for libvirt.
    /// libvirt types the attribute as `positiveInteger` and rejects a repeated
    /// one ("boot order '1' used for more than one device"), while Strato's is
    /// an unvalidated `Int?` documented as "lower = higher priority" whose
    /// first value is naturally 0: `MigrateVMDisksToVolumes` writes exactly
    /// that on every migrated boot volume, so existing databases already hold
    /// a value libvirt refuses.
    ///
    /// Numbering positionally instead is not a guess. `VMSpecBuilder`
    /// sorts volumes by boot order before they go on the wire, and the spec
    /// says as much of the field ("volumes are sent pre-sorted, this is
    /// informational") — so the sequence is the order, and a dense `1...N` over
    /// it is both faithful and always valid. Same reasoning as
    /// `targetDeviceName(index:)` declining to trust `VolumeSpec.deviceName`.
    static func derivedBootOrders(_ disks: [ResolvedDisk]) -> [Int?] {
        var next = 0
        return disks.map { disk in
            guard disk.bootOrder != nil else { return nil }
            next += 1
            return next
        }
    }

    /// One `<disk>`. Shared by the create-time document and by the hot-plug
    /// fragment (`DomainDeviceXML.hotplugDisk`), so a disk a VM was
    /// created with and one plugged in later are described identically —
    /// including the serial a detach resolves by.
    static func diskNode(
        path: String, format: String, target: String, readonly: Bool, bootOrder: Int?,
        volumeId: String?
    ) -> DomainXMLNode {
        var disk = DomainXMLNode("disk", [("type", "file"), ("device", "disk")])
        // No cache/discard/io tuning: the QEMU path passes none, and adding it
        // here would be a behaviour change disguised as a translation.
        disk.append(DomainXMLNode("driver", [("name", "qemu"), ("type", format)]))
        disk.append(DomainXMLNode("source", [("file", path)]))
        disk.append(DomainXMLNode("target", [("dev", target), ("bus", "virtio")]))
        if readonly {
            disk.append(DomainXMLNode("readonly"))
        }
        // The volume this disk realizes, written where a later detach can read
        // it back off the domain. `QEMUDiskIdentity` mints the same string the
        // QEMU driver names its QMP device with, so one volume has one identity
        // whichever driver realizes it (STR-129).
        if let volumeId {
            disk.append(DomainXMLNode("serial", text: QEMUDiskIdentity.deviceID(volumeId: volumeId)))
        }
        if let bootOrder {
            disk.append(DomainXMLNode("boot", [("order", "\(bootOrder)")]))
        }
        return disk
    }

    private static func diskNode(
        path: String, format: String, index: Int, readonly: Bool, bootOrder: Int?,
        volumeId: String?
    ) -> DomainXMLNode {
        diskNode(
            path: path, format: format, target: targetDeviceName(index: index),
            readonly: readonly, bootOrder: bootOrder, volumeId: volumeId)
    }

    private static func interfaceNode(_ nic: ResolvedNetworkAttachment) throws -> DomainXMLNode {
        guard case .tap(let interface) = nic.attachment else {
            throw DomainXMLBuilderError.unsupportedNetworkAttachment(network: nic.network)
        }
        var node = DomainXMLNode("interface", [("type", "ethernet")])
        // Omitted when the control plane allocated none; libvirt then generates
        // one and persists it in the domain definition, as QEMU does today.
        if let mac = nic.macAddress {
            node.append(DomainXMLNode("mac", [("address", mac)]))
        }
        // `managed='no'` is load-bearing: without it libvirt takes ownership of
        // the TAP and tears it down, and the TAP belongs to the network
        // reconciler, which created it and bound it to the integration bridge.
        node.append(DomainXMLNode("target", [("dev", interface), ("managed", "no")]))
        node.append(DomainXMLNode("model", [("type", "virtio")]))
        if let mtu = nic.mtu {
            node.append(DomainXMLNode("mtu", [("size", "\(mtu)")]))
        }
        return node
    }

    private static func videoNode(architecture: CPUArchitecture, graphics: Bool) -> DomainXMLNode {
        guard graphics else {
            // Stated rather than omitted so no libvirt version auto-adds a
            // framebuffer to a VM whose console is the serial port.
            return DomainXMLNode("video", children: [DomainXMLNode("model", [("type", "none")])])
        }
        // Standard VGA on x86: this console exists for pre-driver output — UEFI,
        // GRUB, Windows Setup, a panic screen — which a virtio adapter cannot
        // show without a guest driver. The arm64 `virt` machine has no VGA at
        // all, and EDK2 drives virtio-gpu at firmware time.
        let model = architecture == .x86_64 ? "vga" : "virtio"
        return DomainXMLNode(
            "video", children: [DomainXMLNode("model", [("type", model), ("heads", "1")])])
    }

    private static func unixSource(_ path: String) -> DomainXMLNode {
        DomainXMLNode("source", [("mode", "bind"), ("path", path)])
    }

    // MARK: - Naming and units

    /// libvirt's architecture names, which are not the wire enum's: arm64 is
    /// `aarch64` to libvirt and to QEMU.
    private static func libvirtArch(_ architecture: CPUArchitecture) -> String {
        switch architecture {
        case .x86_64: return "x86_64"
        case .arm64: return "aarch64"
        }
    }

    /// The bare machine type. QEMU's suffixes (`q35,smm=on`,
    /// `virt,gic-version=3`) are `<features>` children in libvirt, not part of
    /// this string.
    private static func machineType(_ architecture: CPUArchitecture) -> String {
        switch architecture {
        case .x86_64: return "q35"
        case .arm64: return "virt"
        }
    }

    /// Target device names, derived positionally: `vda`…`vdz`, then `vdaa`…
    ///
    /// `VolumeSpec.deviceName` is deliberately not used — it is a control-plane
    /// label ("disk0"), not a guest device name, and letting it through would
    /// let two volumes claim one target.
    static func targetDeviceName(index: Int) -> String {
        var suffix = ""
        var remaining = index
        repeat {
            let letter = Character(UnicodeScalar(UInt8(97 + remaining % 26)))
            suffix = String(letter) + suffix
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return "vd" + suffix
    }

    /// Bytes as whole KiB, rounding up. libvirt's memory elements take KiB by
    /// default; the unit is stated anyway so the document does not depend on
    /// that default.
    ///
    /// Shared with `DomainRedefinition`, which rewrites the same elements in a
    /// domain that already exists and has to spell their values identically.
    static func kib(_ bytes: Int64) -> String {
        "\((bytes + 1023) / 1024)"
    }
}
