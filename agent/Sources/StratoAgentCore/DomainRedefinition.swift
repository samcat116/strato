import Foundation
import StratoShared

/// Widens the limits a libvirt domain would otherwise carry for life (STR-187):
/// the spare PCIe root ports a disk hot-plug needs, the virtio-mem region a
/// memory grow works into, and the `<vcpu>` maximum a vCPU hot-add works within.
///
/// ## Why this exists at all
///
/// `LibvirtService.createVM` writes a domain document once, and until this
/// existed nothing ever rewrote it. All three limits are decided in that
/// document — libvirt allocates a root port per PCI device present at define
/// time, so the spares have to be declared up front, and the region and the vCPU
/// maximum are whatever the spec asked for at create — so a VM that outgrew any
/// of them could only be *recreated*. The process driver had none of those
/// limits, because it re-spawned from the current spec on every boot, and a
/// restart was enough to widen all three; under libvirt a restart changed
/// nothing. That was a real capability difference between two drivers the
/// control plane cannot tell apart.
///
/// So this is what a boot or stopped-domain resize does before acting: it makes
/// the definition able to satisfy the current spec. "Recreate the VM" becomes
/// "stop and start it".
///
/// ## Why the existing document is edited rather than rebuilt
///
/// Rebuilding with `DomainXMLBuilder` from the current spec is the obvious
/// shape and is the wrong one. The spec is not a complete description of an
/// existing domain: a VM created from an image boots off a `disk.qcow2` that is
/// in no `VolumeSpec`, its MAC may be one libvirt generated rather than one the
/// control plane allocated, its `<os>` names the firmware *this host resolved on
/// the day it was created*. Every one of those would have to be recovered from
/// the domain anyway, and each recovery this pass got wrong would silently
/// change a VM's hardware at its next power cycle — a far worse failure than the
/// ceiling it set out to remove.
///
/// Editing inverts the failure. Everything not named below is carried through
/// exactly as libvirt wrote it, and an edit this pass cannot make becomes a
/// *refusal* the driver logs rather than a rewrite: the VM keeps the ceiling it
/// had, which is the status quo, and nothing it was running with moves.
///
/// ## What it changes
///
/// - **Spare root ports.** Tops the domain up to `spareHotplugPorts` ports that
///   no device's `<address>` claims, numbering the new ones past every PCI
///   controller index already in the document. Nothing is ever removed: a port a
///   device sits in is not free, and a port that is free is already the thing
///   being counted.
/// - **Memory headroom.** Only ever upward, and only when the spec asks for a
///   *higher total* than the domain has. What it writes is exactly what
///   `DomainXMLBuilder` would emit for this spec — `<maxMemory>`, `<memory>`,
///   `<currentMemory>`, the NUMA cell's memory and the virtio-mem device's
///   `<target><size>` — with `<requested>` reset to zero, because the boot size
///   moves up to `spec.memoryBytes` and a region left plugged on top of it would
///   hand the guest that memory twice. A spec that asks for **no** region takes
///   `<maxMemory>` with the device: the element is what enables memory hot-plug,
///   and leaving it behind alone is a domain QEMU refuses to start.
/// - **The vCPU ceiling.** Likewise upward only, in `<vcpu>` and the NUMA cell's
///   `cpus` range.
///
/// The boot *size* moves with the ceiling in both cases — `<currentMemory>` and
/// `<vcpu current=…>` are written from the spec — and that is deliberate rather
/// than scope creep. `addResizes` plans nothing for a stopped VM, so a size left
/// behind here is converged a whole reconcile later, as a *hot-add*: memory the
/// guest may take, vCPUs most guests will not online without a udev rule. The
/// operator told to "stop and start the VM" would restart and still see the old
/// size. This is not a resize path for all that: a domain whose ceilings already
/// fit its spec is left completely alone, and converging *that* VM's size stays
/// `resizeVM`'s job. STR-248 drives a stopped shrink through that resize path;
/// this pass prepares any simultaneous upward ceiling change first.
public enum DomainRedefinition {

    /// Adds the two libvirt elements that make an existing x86 IMDS guest
    /// select NoCloud's network mode at its next boot.
    ///
    /// Domains created before the IMDS bootstrap repair have neither element:
    /// rebuilding them through `DomainXMLBuilder` would lose host-resolved and
    /// libvirt-assigned state, so the boot path applies this narrow edit to the
    /// inactive definition instead. A domain that already carries the hint is
    /// a no-op, which makes the migration safe to run before every boot.
    ///
    /// An existing, different SMBIOS declaration is refused rather than
    /// overwritten. Strato did not emit one before this migration, and silently
    /// replacing an operator-authored serial would change guest-visible
    /// hardware.
    public static func addingIMDSBootstrapHint(
        toInactiveDomainXML xml: String,
        metadataSource: MetadataSource,
        architecture: CPUArchitecture
    ) throws -> String? {
        guard metadataSource == .imds, architecture == .x86_64 else { return nil }

        var domain = try DomainXMLNode.parse(xml)
        guard domain.name == "domain" else {
            throw DomainInventoryError.unparseable("no <domain> element")
        }
        guard let osIndex = domain.firstIndex(ofChildNamed: "os") else {
            throw DomainInventoryError.unparseable("the domain document declares no <os>")
        }

        let serial = "ds=nocloud;dsmode=net"
        let sysinfos = domain.children.filter { $0.name == "sysinfo" && $0.attribute("type") == "smbios" }
        let hasSerialHint = sysinfos.contains { sysinfo in
            sysinfo.child(named: "system")?.children.contains {
                $0.name == "entry" && $0.attribute("name") == "serial" && $0.text == serial
            } == true
        }
        if !hasSerialHint && !sysinfos.isEmpty {
            throw DomainInventoryError.unparseable(
                "an existing SMBIOS sysinfo would have to be replaced to add the IMDS datasource hint")
        }

        let os = domain.children[osIndex]
        let existingSMBIOS = os.child(named: "smbios")
        if let existingSMBIOS, existingSMBIOS.attribute("mode") != "sysinfo" {
            throw DomainInventoryError.unparseable(
                "<os> already selects a different SMBIOS mode")
        }

        var changed = false
        if !hasSerialHint {
            domain.insert(
                DomainXMLNode(
                    "sysinfo", [("type", "smbios")],
                    children: [
                        DomainXMLNode(
                            "system",
                            children: [
                                DomainXMLNode(
                                    "entry", [("name", "serial")],
                                    text: serial)
                            ])
                    ]),
                at: osIndex)
            changed = true
        }

        if existingSMBIOS == nil {
            domain.editChild(named: "os") { os in
                let insertion = os.firstIndex(ofChildNamed: "type").map { $0 + 1 } ?? 0
                os.insert(DomainXMLNode("smbios", [("mode", "sysinfo")]), at: insertion)
            }
            changed = true
        }

        return changed ? domain.render() : nil
    }

    /// The outcome of one widening pass.
    public struct Widening: Sendable, Equatable {
        /// The document to hand `virDomainDefineXML`, or nil when the domain's
        /// definition already satisfies the spec and there is nothing to define.
        public let xml: String?
        /// Spare `pcie-root-port`s added.
        public let addedHotplugPorts: Int
        /// The domain's new memory ceiling, or nil when the memory layout was
        /// left exactly as it was.
        public let memoryCeilingBytes: Int64?
        /// The domain's new vCPU ceiling, or nil when `<vcpu>` was left alone.
        public let vcpuCeiling: Int?
        /// Widenings the spec asked for that this pass could not make, each
        /// naming what stopped it.
        ///
        /// Not an error: a refusal leaves the definition alone, so the VM boots
        /// with the ceiling it already had. It is reported so that the ceiling
        /// is *said out loud* at the one moment something could have been done
        /// about it, rather than surfacing later as libvirt's bare "No more
        /// available PCI slots" on some unrelated attach.
        public let refusals: [String]

        /// Whether anything is worth defining.
        public var isEmpty: Bool { xml == nil }
    }

    /// The widened document for `inactiveDomainXML`, or a `Widening` with no
    /// `xml` when the definition already satisfies `spec`.
    ///
    /// The document must be the domain's **persistent** definition
    /// (`VIR_DOMAIN_XML_INACTIVE`), and the caller must have established that
    /// the domain is not running: the port arithmetic reads the `<address>`
    /// elements libvirt assigned at define time, and a live document carries
    /// state that is not part of what the next boot will read.
    ///
    /// Throws only when the document cannot be read or re-emitted at all
    /// (`DomainInventoryError`). Everything this pass merely declines to do
    /// comes back in `refusals`.
    public static func widening(
        forInactiveDomainXML xml: String, spec: VMSpec, architecture: CPUArchitecture
    ) throws -> Widening {
        var domain = try DomainXMLNode.parse(xml)
        guard domain.name == "domain" else {
            throw DomainInventoryError.unparseable("no <domain> element")
        }
        guard domain.firstIndex(ofChildNamed: "devices") != nil else {
            throw DomainInventoryError.unparseable("the domain document declares no <devices>")
        }
        // The two elements this pass gives children to must not be leaves.
        // `DomainXMLNode` states that exclusivity with an `assert`, which is
        // compiled out at `-O` — so on a hypervisor node an `append` to an
        // element carrying character data would silently drop the data instead,
        // in a document about to redefine an existing VM. `parse` refuses mixed
        // content, so the only way in is an element that is *only* text where
        // this expects a container; libvirt writes no such document, and one
        // that arrives anyway is refused here rather than re-emitted short.
        for container in ["devices", "cpu"] where domain.child(named: container)?.text != nil {
            throw DomainInventoryError.unparseable(
                "<\(container)> carries character data, so it is not an element this can add to")
        }

        var refusals: [String] = []
        // Order is not arbitrary. vCPUs first, because a NUMA cell has to span
        // every vCPU the domain can reach and the memory pass may be the one
        // creating that cell. Memory before the ports, because a domain that
        // gains a virtio-mem device gains a PCI device with it, and the ports
        // have to be counted against the document as it will be defined rather
        // than as it was read.
        let vcpuCeiling = widenVCPUs(&domain, spec: spec, refusals: &refusals)
        let memory = widenMemory(&domain, spec: spec, architecture: architecture, refusals: &refusals)
        let addedPorts = addSparePorts(
            &domain, pendingPCIDevices: memory.addedDevice ? 1 : 0, refusals: &refusals)

        let changed = addedPorts > 0 || memory.ceilingBytes != nil || vcpuCeiling != nil
        return Widening(
            xml: changed ? domain.render() : nil,
            addedHotplugPorts: addedPorts,
            memoryCeilingBytes: memory.ceilingBytes,
            vcpuCeiling: vcpuCeiling,
            refusals: refusals)
    }

    // MARK: - vCPU ceiling

    /// Raises `<vcpu>` to the maximum the spec asks for, returning the new
    /// ceiling or nil where none was needed.
    ///
    /// The same defect as the memory ceiling and fixed here for the same reason:
    /// `virDomainSetVcpusFlags` can only move a domain's *current* count within
    /// the maximum its document declares, so a VM resized past that maximum came
    /// up at the old count and then failed its drift resize with libvirt's
    /// "requested vcpus is greater than max allowable vcpus". The control plane
    /// already tells the operator to "restart it to grow beyond that" and
    /// already raises a stopped VM's recorded `maxCpu` on the assumption that a
    /// boot re-reads it — this is what makes both true.
    ///
    /// **`current` moves to `spec.cpus` with it**, which is the same rule the
    /// memory pass follows for `<currentMemory>`: where this rewrites a domain's
    /// sizing it writes the size the spec asks for, not just the ceiling. The
    /// alternative — pinning the count and leaving it to `resizeCPUs` — makes
    /// the operator's remedy land in two power cycles rather than one, because
    /// `addResizes` plans nothing for a stopped VM, and the follow-up arrives as
    /// a vCPU *hot-add* that most guests will not online without a udev rule. So
    /// a VM resized 2 → 16 while stopped would restart, as instructed, and still
    /// show 2.
    ///
    /// This does not make the pass a resize path. It rewrites sizing only where
    /// it is already rewriting a *ceiling*; a domain whose ceilings already fit
    /// its spec is left entirely alone, and converging the count there stays
    /// `resizeCPUs`' job.
    private static func widenVCPUs(
        _ domain: inout DomainXMLNode, spec: VMSpec, refusals: inout [String]
    ) -> Int? {
        guard let vcpu = domain.child(named: "vcpu"),
            let current = vcpu.text.flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { return nil }
        let wanted = max(spec.maxCpus, spec.cpus)
        guard wanted > current else { return nil }

        // libvirt validates a declared topology against the vCPU maximum
        // (sockets × dies × cores × threads), so raising one without the other
        // is a document it rejects. The builder declares none, and inventing a
        // socket layout for a guest that was booted with a different one is not
        // a decision a widening gets to make.
        if domain.child(named: "cpu")?.child(named: "topology") != nil {
            refusals.append(
                "the domain declares an explicit CPU topology, which fixes its vCPU maximum at "
                    + "\(current); the sockets, cores and threads a larger one should have are not "
                    + "something this can decide")
            return nil
        }

        // A cell list that does not cover every vCPU is a domain libvirt
        // refuses, and dividing new vCPUs between several cells is not a
        // decision this can make.
        let cells = domain.child(named: "cpu")?.child(named: "numa")?.children.filter { $0.name == "cell" }
        if let cells, cells.count > 1 {
            refusals.append(
                "the domain has \(cells.count) NUMA cells, so which of them the vCPUs above \(current) "
                    + "belong to is not something this can decide")
            return nil
        }

        // Clamped at both ends: never above the ceiling being written, and never
        // zero, which libvirt rejects — a spec is not normalized on the way off
        // the wire (`DomainXMLBuilderError.invalidCPUCount`).
        let boot = min(max(spec.cpus, 1), wanted)
        domain.editChild(named: "vcpu") {
            $0.setAttribute("current", "\(boot)")
            $0.setText("\(wanted)")
        }
        domain.editChild(named: "cpu") { cpu in
            cpu.editChild(named: "numa") { numa in
                numa.editChildren(named: "cell") { $0.setAttribute("cpus", "0-\(wanted - 1)") }
            }
        }
        return wanted
    }

    // MARK: - Spare root ports

    /// Adds empty `pcie-root-port`s until `spareHotplugPorts` of them are free,
    /// returning how many were added.
    ///
    /// "Free" is a port no device's `<address type='pci'>` names as its bus.
    /// That is libvirt's own answer rather than a prediction — unlike the create
    /// path, which has to over-estimate the devices it is about to declare
    /// (`declaredPCIDeviceCount`), a defined domain has already been through
    /// libvirt's address allocator and says where everything went. Bus `0x00` is
    /// `pcie-root` itself, where a q35 machine's integrated devices live without
    /// consuming a port, so it never counts as occupying one.
    ///
    /// New ports are numbered past **every** PCI controller index in the
    /// document, not just past the root ports: an index libvirt has already
    /// given to something else is a document it rejects.
    private static func addSparePorts(
        _ domain: inout DomainXMLNode, pendingPCIDevices: Int, refusals: inout [String]
    ) -> Int {
        guard let devices = domain.child(named: "devices") else { return 0 }

        var pciControllerIndexes: Set<Int> = []
        var rootPortIndexes: Set<Int> = []
        for child in devices.children where child.name == "controller" && child.attribute("type") == "pci" {
            guard let index = child.attribute("index").flatMap(Int.init) else { continue }
            pciControllerIndexes.insert(index)
            if child.attribute("model") == "pcie-root-port" {
                rootPortIndexes.insert(index)
            }
        }
        let occupied = occupiedPCIBuses(devices)
        let free = rootPortIndexes.subtracting(occupied).count

        let wanted = DomainXMLBuilder.spareHotplugPorts + pendingPCIDevices
        guard wanted > free else { return 0 }

        var next = (pciControllerIndexes.union(occupied).max() ?? 0) + 1
        var added = 0
        domain.editChild(named: "devices") { devices in
            while added < wanted - free, next <= DomainXMLBuilder.rootPortIndexCeiling {
                devices.append(
                    DomainXMLNode(
                        "controller", [("type", "pci"), ("index", "\(next)"), ("model", "pcie-root-port")]))
                next += 1
                added += 1
            }
        }
        if added < wanted - free {
            refusals.append(
                "this VM's own devices reach the \(DomainXMLBuilder.rootPortIndexCeiling)-port limit a domain "
                    + "can still be started with, so it keeps \(free + added) free PCIe root port(s) rather "
                    + "than \(DomainXMLBuilder.spareHotplugPorts); attach further volumes with the VM stopped")
        }
        return added
    }

    /// Every non-zero PCI bus a device in the document sits on.
    ///
    /// Recursive, because a device's `<address>` hangs off the device rather
    /// than off `<devices>` — and only `type='pci'` addresses are read, since
    /// `<address type='drive'>` has a `bus` of its own that means something
    /// entirely different.
    private static func occupiedPCIBuses(_ node: DomainXMLNode) -> Set<Int> {
        var buses: Set<Int> = []
        if node.name == "address", node.attribute("type") == "pci",
            let bus = node.attribute("bus").flatMap(pciBusNumber), bus != 0
        {
            buses.insert(bus)
        }
        for child in node.children {
            buses.formUnion(occupiedPCIBuses(child))
        }
        return buses
    }

    /// libvirt writes PCI address components as `0x02`. Plain decimal is
    /// accepted too — the schema allows it, and a document that took another
    /// route (a `virsh edit`) is still one this has to read rather than misread.
    private static func pciBusNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed)
    }

    // MARK: - Memory headroom

    private struct MemoryWidening {
        static let unchanged = MemoryWidening(ceilingBytes: nil, addedDevice: false)
        let ceilingBytes: Int64?
        let addedDevice: Bool
    }

    /// Rewrites the domain's memory layout to what `DomainXMLBuilder` would emit
    /// for `spec` — boot memory of `spec.memoryBytes`, a virtio-mem region for
    /// the rest of `spec.maxMemoryBytes` — but **only when that raises the
    /// total**.
    ///
    /// The gate is the total rather than the region, and the difference is the
    /// whole stopped-resize case. A VM resized while stopped comes back with
    /// `maxMemoryBytes == memoryBytes`, because the control plane raises the
    /// recorded ceiling to the new size: there is no *headroom* being asked for
    /// at all, and yet the domain — defined at 2 GiB boot plus 6 GiB of region —
    /// cannot boot the 16 GiB the spec now names. Gating on the region would
    /// skip exactly the case the operator was told a restart would fix.
    ///
    /// Never downward. A spec asking for less already converges — through the
    /// balloon on a live guest, through `<currentMemory>` on a stopped one — and
    /// deciding at boot time that a guest should come back holding less is the
    /// resize path's call to make, not a document rewrite's.
    private static func widenMemory(
        _ domain: inout DomainXMLNode, spec: VMSpec, architecture: CPUArchitecture,
        refusals: inout [String]
    ) -> MemoryWidening {
        guard let currentTotal = memoryValue(domain.child(named: "memory")) else {
            refusals.append("the domain declares no readable <memory>, so its ceiling cannot be raised")
            return .unchanged
        }

        guard let devices = domain.child(named: "devices") else { return .unchanged }
        let memoryDevices = devices.children.filter { $0.name == "memory" }
        guard memoryDevices.count <= 1 else {
            refusals.append(
                "the domain has \(memoryDevices.count) memory devices, and which of them holds this VM's "
                    + "headroom is not something the document says")
            return .unchanged
        }
        let existing = memoryDevices.first
        if let existing, existing.attribute("model") != "virtio-mem" {
            refusals.append(
                "the domain's memory device is a \(existing.attribute("model") ?? "device of no stated model") "
                    + "rather than virtio-mem, so its region is not one this can resize")
            return .unchanged
        }

        // The device's own block size, never a recomputed one: it is a property
        // of the guest the domain was defined for, and every size the device
        // takes has to be a multiple of it.
        let block =
            existing.flatMap { memoryValue($0.child(named: "target")?.child(named: "block")) }
            ?? QEMUMemoryReservation.blockBytes(architecture: architecture)
        guard block > 0 else {
            refusals.append("the domain's memory device declares no usable block size")
            return .unchanged
        }
        let requestedHotplug = QEMUMemoryReservation.alignedHotplugBytes(spec: spec, architecture: architecture)
        let size = requestedHotplug - (requestedHotplug % block)
        let total = spec.memoryBytes + size
        guard total > currentTotal else { return .unchanged }

        // libvirt requires a NUMA topology wherever memory hotplug is enabled,
        // and the cell holds the *boot* memory — which this is about to move.
        // More than one cell is a topology nothing here wrote and nothing here
        // knows how to divide a new boot size between.
        let cells = domain.child(named: "cpu")?.child(named: "numa")?.children.filter { $0.name == "cell" }
        if let cells, cells.count > 1 {
            refusals.append(
                "the domain has \(cells.count) NUMA cells, and how a new boot size divides between them is "
                    + "not something this can decide")
            return .unchanged
        }
        // Only a domain that will *have* hot-pluggable memory needs a cell to
        // hang it off; one that is only growing its boot size does not.
        if size > 0, domain.firstIndex(ofChildNamed: "cpu") == nil {
            refusals.append("the domain declares no <cpu> element to hang a NUMA cell off")
            return .unchanged
        }
        // A *new* device is `DomainXMLBuilder.memoryDeviceNode`, whose `<node>`
        // is 0 — the cell the builder writes — and libvirt refuses a backend for
        // a guest node that does not exist. Retargeting it at the cell instead
        // would not help: `DomainDeviceXML.memoryDevice` builds the resize
        // fragment from the same function and matches libvirt's device by
        // identity, so a device on node 1 would be one no later resize could
        // find. Refusing keeps both honest. Strato writes no such document; nor
        // does it write `<qemu:commandline>`, which `parse` survives on purpose.
        let cellID = cells?.first?.attribute("id") ?? "0"
        if size > 0, existing == nil, cellID != "0" {
            refusals.append(
                "the domain's only NUMA cell is node \(cellID) rather than node 0, and a memory device "
                    + "this pass added would name a node no later resize could match")
            return .unchanged
        }

        // **`<maxMemory>` tracks the region, in both directions.** It is what
        // turns memory hot-plug on — `virDomainDefHasMemoryHotplug` is true for
        // its presence alone — and libvirt then starts QEMU with
        // `-m size=…,slots=…,maxmem=…`. With no device left, initial memory
        // *is* the total, so keeping the element would hand QEMU a `maxmem`
        // equal to `size` alongside a slot count, which it refuses outright:
        // "memory slots were specified but maximum memory size … is equal to
        // the initial memory size". libvirt's own hot-plug validation does not
        // catch it, because the NUMA cell it checks for is still there.
        //
        // `DomainXMLBuilder` emits the element only for `hotplugBytes > 0`, so
        // no *created* VM is ever in that state and this pass is the only thing
        // that could put one there — a domain that defines and then will not
        // start, which is precisely the regression this type's note rules out.
        // Where the element is kept, it keeps its `slots`: that is a fact about
        // the domain rather than about the size. Where it is added, it goes
        // before `<memory>`, which is where libvirt's schema puts it.
        let ceiling = DomainXMLBuilder.kib(total)
        let boot = DomainXMLBuilder.kib(spec.memoryBytes)
        let maxCPUs = domain.child(named: "vcpu")?.text
        guard size > 0 else {
            domain.removeChildren(named: "maxMemory")
            rewriteMemorySizes(&domain, total: ceiling, boot: boot)
            // The cell can stay: a single NUMA node without hot-plug is a valid
            // domain, and removing it would change the guest's visible topology
            // on the same boot its size moves.
            if cells?.isEmpty == false {
                domain.editChild(named: "cpu") {
                    setNUMACell(&$0, bootMemory: boot, maxCPUs: maxCPUs)
                }
            }
            domain.editChild(named: "devices") { $0.removeChildren(named: "memory") }
            return MemoryWidening(ceilingBytes: total, addedDevice: false)
        }

        let hadMaxMemory = domain.editChild(
            named: "maxMemory",
            {
                $0.setAttribute("unit", "KiB"); $0.setText(ceiling)
            })
        if !hadMaxMemory, let memoryIndex = domain.firstIndex(ofChildNamed: "memory") {
            domain.insert(
                DomainXMLNode("maxMemory", [("slots", "1"), ("unit", "KiB")], text: ceiling),
                at: memoryIndex)
        }

        rewriteMemorySizes(&domain, total: ceiling, boot: boot)
        domain.editChild(named: "cpu") { setNUMACell(&$0, bootMemory: boot, maxCPUs: maxCPUs) }

        // `<requested>` back to zero, always. The guest now boots at
        // `spec.memoryBytes`, so a region left plugged from an earlier grow
        // would be that memory handed over a second time.
        let addedDevice = existing == nil
        domain.editChild(named: "devices") { devices in
            if addedDevice {
                devices.append(
                    DomainXMLBuilder.memoryDeviceNode(
                        sizeBytes: size, blockBytes: block, requestedBytes: 0))
                return
            }
            devices.editChildren(named: "memory") { device in
                device.editChild(named: "target") { target in
                    target.editChild(named: "size") {
                        $0.setAttribute("unit", "KiB")
                        $0.setText(DomainXMLBuilder.kib(size))
                    }
                    target.editChild(named: "requested") {
                        $0.setAttribute("unit", "KiB")
                        $0.setText("0")
                    }
                }
            }
        }
        return MemoryWidening(ceilingBytes: total, addedDevice: addedDevice)
    }

    /// Writes `<memory>` and `<currentMemory>` — the domain's total and the size
    /// the guest boots with — inserting `<currentMemory>` where libvirt left it
    /// implicit.
    private static func rewriteMemorySizes(
        _ domain: inout DomainXMLNode, total: String, boot: String
    ) {
        domain.editChild(named: "memory") {
            $0.setAttribute("unit", "KiB"); $0.setText(total)
        }
        let hadCurrent = domain.editChild(
            named: "currentMemory",
            {
                $0.setAttribute("unit", "KiB"); $0.setText(boot)
            })
        if !hadCurrent, let memoryIndex = domain.firstIndex(ofChildNamed: "memory") {
            domain.insert(
                DomainXMLNode("currentMemory", [("unit", "KiB")], text: boot), at: memoryIndex + 1)
        }
    }

    /// Writes the boot size into `<cpu><numa><cell>`, creating the topology
    /// where the domain was defined without headroom and so has none.
    ///
    /// A cell created here spans every vCPU the domain can grow to, read from
    /// `<vcpu>` — the domain's own maximum, not the spec's, because this pass
    /// does not move the vCPU ceiling and a cell naming more CPUs than the
    /// domain has is a document libvirt rejects.
    private static func setNUMACell(
        _ cpu: inout DomainXMLNode, bootMemory: String, maxCPUs: String?
    ) {
        if cpu.child(named: "numa")?.children.contains(where: { $0.name == "cell" }) == true {
            cpu.editChild(named: "numa") { numa in
                numa.editChildren(named: "cell") { cell in
                    cell.setAttribute("memory", bootMemory)
                    cell.setAttribute("unit", "KiB")
                }
            }
            return
        }

        let cpus = maxCPUs.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        let cell = DomainXMLNode(
            "cell",
            [
                ("id", "0"), ("cpus", cpus > 1 ? "0-\(cpus - 1)" : "0"),
                ("memory", bootMemory), ("unit", "KiB"),
            ])
        if cpu.editChild(named: "numa", { $0.append(cell) }) == false {
            cpu.append(DomainXMLNode("numa", children: [cell]))
        }
    }

    /// A libvirt memory element as bytes, honouring its declared `unit`.
    private static func memoryValue(_ node: DomainXMLNode?) -> Int64? {
        guard let node, let text = node.text else { return nil }
        return DomainMemoryInventory.bytes(text, unit: node.attribute("unit"))
    }
}
