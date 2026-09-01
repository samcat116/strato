import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// The memory sizing a domain was *defined* with, read back out of its document.
///
/// A resize needs three numbers the desired spec cannot supply, because the
/// spec describes what the VM should become while these describe what it
/// already is:
///
/// - the **boot** size, which is the floor a virtio-mem resize works up from —
///   only the region above it is plug/unpluggable;
/// - the memory **device's** size, block size and complete live element, so an
///   update can retain the identity libvirt assigned to the existing device;
/// - whether there is a memory device at all.
///
/// The process driver kept the equivalent in `vmSpawnSizing`, a dictionary keyed by
/// VM id that is lost whenever the agent restarts. Here the domain document is
/// the record, so this is a query — which is also why a VM defined by an older
/// spec resizes correctly against the headroom it really has instead of the
/// headroom its newest spec asks for.
///
/// ## Why the boot size is derived rather than read
///
/// `<currentMemory>` looks like the boot size and is not one. libvirt formats
/// it from `def->mem.cur_balloon`, and in the **live** definition — which is
/// what `virDomainGetXMLDesc` returns for a running domain — that is the
/// current balloon allocation, which `virDomainSetMemory` moves. The driver
/// calls exactly that at the end of every resize, so reading the floor from
/// `<currentMemory>` is right on a VM's first resize and wrong on every one
/// after it: a second grow would compute its delta from the size the first one
/// left, and shrink the device it meant to grow.
///
/// `<memory>` and the memory devices' `<target><size>` are the quantities that
/// do not move. libvirt formats `<memory>` from `virDomainDefGetMemoryTotal` —
/// initial memory plus every memory device's *size* (never its `<requested>`) —
/// so the difference is the initial memory by construction, under ballooning
/// and under hot-plug alike.
public struct DomainMemoryLayout: Sendable, Equatable {
    /// `<memory>` — the initial memory plus every memory device.
    public let maximumBytes: Int64
    /// The sum of every `<memory model=…>` device's `<target><size>`.
    ///
    /// Every device, not just the virtio-mem one: Strato defines no others, but
    /// a domain that acquired a DIMM some other way would otherwise have its
    /// boot size under-reported by that DIMM's size, and a resize would compute
    /// its delta from a floor that is too high.
    public let memoryDeviceBytes: Int64
    /// The `<memory model='virtio-mem'>` device, absent for a VM defined with
    /// no hot-plug headroom.
    public let virtioMem: VirtioMem?

    /// What the guest boots with — the floor a virtio-mem resize works up from.
    public var bootBytes: Int64 { maximumBytes - memoryDeviceBytes }

    public struct VirtioMem: Sendable, Equatable {
        /// `<target><size>` — the whole hot-pluggable region.
        public let sizeBytes: Int64
        /// `<target><block>` — the granularity every `<requested>` must be a
        /// multiple of.
        public let blockBytes: Int64
        /// `<target><requested>` — how much of the region is plugged in now.
        public let requestedBytes: Int64
        /// The complete `<memory>` element read from the domain, including
        /// identity libvirt assigned when it defined the device.
        ///
        /// An update must change this element in place rather than reconstruct
        /// it from the sizing fields above: the live XML also carries the
        /// device's `<alias>` and `<address>`, and libvirt uses those to find
        /// the device that `virDomainUpdateDeviceFlags` should update.
        public let deviceXML: String

        public init(
            sizeBytes: Int64, blockBytes: Int64, requestedBytes: Int64,
            deviceXML: String
        ) {
            self.sizeBytes = sizeBytes
            self.blockBytes = blockBytes
            self.requestedBytes = requestedBytes
            self.deviceXML = deviceXML
        }
    }

    public init(maximumBytes: Int64, memoryDeviceBytes: Int64, virtioMem: VirtioMem?) {
        self.maximumBytes = maximumBytes
        self.memoryDeviceBytes = memoryDeviceBytes
        self.virtioMem = virtioMem
    }

    /// The `<requested>` that would leave the guest holding `targetBytes` in
    /// total, clamped to what the device can actually deliver.
    ///
    /// Below the boot size the answer is zero: virtio-mem can only give back
    /// what it plugged in, so a shrink past boot memory is not something this
    /// device can do — the QEMU path says the same thing by capping the delta
    /// at zero. Above the device's size it is the whole device, for the same
    /// reason in the other direction. In between it is rounded **down** to a
    /// whole block, because a request that is not a multiple of the block size
    /// is refused outright rather than rounded by QEMU.
    public func requestedBytes(forTotal targetBytes: Int64) -> Int64? {
        guard let virtioMem else { return nil }
        let delta = max(targetBytes - bootBytes, 0)
        let aligned = delta - (delta % virtioMem.blockBytes)
        return min(aligned, virtioMem.sizeBytes)
    }

    /// How much of `targetBytes` this domain cannot deliver, or nil when it can
    /// deliver all of it.
    ///
    /// The companion to the clamp above, and the reason it needs one. Every
    /// bound in `requestedBytes(forTotal:)` is right — QEMU refuses a
    /// `<requested>` above the device's size outright — but they make a target
    /// beyond the ceiling *indistinguishable from one at it*: the resize plugs
    /// the whole region, reports success, and leaves the VM short with nothing
    /// anywhere saying so, while the control plane reads the generation as
    /// converged. So the shortfall is a separate question, asked separately
    /// (STR-187).
    ///
    /// Lives here rather than in the driver because it is arithmetic over this
    /// type and a `VMSpec`, and the driver has no tests — the same reason
    /// `DomainXMLBuilder` is in this target.
    public func shortfall(forTotal targetBytes: Int64) -> Int64? {
        targetBytes > maximumBytes ? targetBytes - maximumBytes : nil
    }
}

/// Reads `DomainMemoryLayout` out of `virDomainGetXMLDesc`.
public enum DomainMemoryInventory {

    public static func memoryLayout(inDomainXML xml: String) throws -> DomainMemoryLayout {
        guard let data = xml.data(using: .utf8) else {
            throw DomainInventoryError.unparseable("the domain document is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = MemoryCollector()
        parser.delegate = delegate
        // See `DomainDiskInventory.disks`: `parse()` answers true for a
        // document that stops early and reports the truncation only through
        // `parserError`.
        guard parser.parse(), parser.parserError == nil else {
            throw DomainInventoryError.unparseable(
                parser.parserError?.localizedDescription ?? "the domain document could not be parsed")
        }
        guard let maximum = delegate.memory else {
            throw DomainInventoryError.unparseable("the domain document declares no memory size")
        }
        if let refusal = delegate.deviceRefusal {
            throw DomainInventoryError.unparseable(refusal)
        }
        let deviceNodes = delegate.virtioMemDevices
        let virtioMem: DomainMemoryLayout.VirtioMem?
        if let parsed = delegate.virtioMem {
            guard deviceNodes.count == 1 else {
                throw DomainInventoryError.unparseable(
                    "the domain declares \(deviceNodes.count) virtio-mem devices; expected exactly one")
            }
            virtioMem = DomainMemoryLayout.VirtioMem(
                sizeBytes: parsed.sizeBytes, blockBytes: parsed.blockBytes,
                requestedBytes: parsed.requestedBytes, deviceXML: deviceNodes[0].render())
        } else {
            virtioMem = nil
        }
        return DomainMemoryLayout(
            maximumBytes: maximum, memoryDeviceBytes: delegate.memoryDeviceBytes,
            virtioMem: virtioMem)
    }

    /// A libvirt memory value in its declared unit, as bytes.
    ///
    /// libvirt's own `dumpxml` always writes `unit='KiB'`, which is also this
    /// function's default — the rest of the vocabulary is accepted because the
    /// schema allows it and a document that took another path through libvirt
    /// (a `virsh edit`, a restored definition) is still one this has to read
    /// rather than misread by a factor of 1024.
    static func bytes(_ text: String, unit: String?) -> Int64? {
        guard let value = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let multiplier: Int64
        switch (unit ?? "KiB") {
        case "b", "bytes", "B": multiplier = 1
        case "KB": multiplier = 1000
        case "k", "KiB": multiplier = 1024
        case "MB": multiplier = 1000 * 1000
        case "M", "MiB": multiplier = 1024 * 1024
        case "GB": multiplier = 1000 * 1000 * 1000
        case "G", "GiB": multiplier = 1024 * 1024 * 1024
        case "TB": multiplier = 1000 * 1000 * 1000 * 1000
        case "T", "TiB": multiplier = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : bytes
    }
}

/// Collects the domain's total memory and its memory devices.
///
/// Scoped by parent throughout: `<memory>` means the domain's total when it
/// hangs off `<domain>` and a memory *device* when it hangs off `<devices>`,
/// and `<size>` appears under half a dozen unrelated elements.
///
/// `<currentMemory>` is deliberately not collected — see `DomainMemoryLayout`
/// for why it is not the boot size.
private struct ParsedVirtioMem {
    let sizeBytes: Int64
    let blockBytes: Int64
    let requestedBytes: Int64
}

private final class MemoryCollector: NSObject, XMLParserDelegate {
    /// One element inside a selected virtio-mem subtree. Unlike
    /// `DomainXMLNode.parse`, this stack is empty everywhere else in the domain,
    /// so unrelated application metadata can contain CDATA or mixed content
    /// without making an ordinary resize impossible.
    private struct DeviceFrame {
        let name: String
        let attributes: [DomainXMLAttribute]
        var children: [DomainXMLNode] = []
        var text = ""
    }

    private(set) var memory: Int64?
    private(set) var memoryDeviceBytes: Int64 = 0
    private(set) var virtioMem: ParsedVirtioMem?
    private(set) var virtioMemDevices: [DomainXMLNode] = []
    private(set) var deviceRefusal: String?

    private var path: [String] = []
    private var text: String?
    private var unit: String?
    /// Set while inside any `<devices><memory model=…>`, and separately for the
    /// virtio-mem one: every device counts toward the boot-size derivation,
    /// while only virtio-mem is a device a resize can drive.
    private var inMemoryDevice = false
    private var isVirtioMem = false
    private var deviceSize: Int64?
    private var deviceBlock: Int64?
    private var deviceRequested: Int64?
    private var deviceFrames: [DeviceFrame] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        defer { path.append(elementName) }

        if !deviceFrames.isEmpty
            || (elementName == "memory" && path.last == "devices"
                && attributes["model"] == "virtio-mem")
        {
            let orderedAttributes = attributes.keys.sorted().map {
                DomainXMLAttribute(name: $0, value: attributes[$0] ?? "")
            }
            deviceFrames.append(
                DeviceFrame(name: elementName, attributes: orderedAttributes))
        }

        if elementName == "memory", path.last == "devices" {
            inMemoryDevice = true
            isVirtioMem = attributes["model"] == "virtio-mem"
            deviceSize = nil
            deviceBlock = nil
            deviceRequested = nil
            return
        }
        switch (path.last, elementName) {
        case ("domain", "memory"):
            text = ""
            unit = attributes["unit"]
        case ("target", "size"), ("target", "block"), ("target", "requested"):
            guard inMemoryDevice else { return }
            text = ""
            unit = attributes["unit"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text != nil {
            text? += string
        }
        if !deviceFrames.isEmpty {
            deviceFrames[deviceFrames.count - 1].text += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !deviceFrames.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        deviceFrames[deviceFrames.count - 1].text += text
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        finishDeviceElement(named: elementName)
        path.removeLast()

        if elementName == "memory", path.last == "devices" {
            if let size = deviceSize {
                memoryDeviceBytes += size
                if isVirtioMem, let block = deviceBlock, block > 0 {
                    virtioMem = ParsedVirtioMem(
                        sizeBytes: size, blockBytes: block, requestedBytes: deviceRequested ?? 0)
                }
            }
            inMemoryDevice = false
            isVirtioMem = false
            return
        }

        guard let raw = text else { return }
        let value = DomainMemoryInventory.bytes(raw, unit: unit)
        text = nil
        unit = nil
        guard let value else { return }

        switch elementName {
        case "memory" where path.last == "domain": memory = value
        case "size" where inMemoryDevice: deviceSize = value
        case "block" where inMemoryDevice: deviceBlock = value
        case "requested" where inMemoryDevice: deviceRequested = value
        default: break
        }
    }

    private func finishDeviceElement(named elementName: String) {
        guard let frame = deviceFrames.popLast() else { return }

        var text: String?
        if frame.children.isEmpty {
            text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : frame.text
        } else if !frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordDeviceRefusal("mixed content in <\(frame.name)>, which this cannot re-emit")
        }

        let node = DomainXMLNode(
            frame.name, frame.attributes.map { ($0.name, Optional($0.value)) }, text: text,
            children: frame.children)
        if deviceFrames.isEmpty {
            virtioMemDevices.append(node)
        } else {
            deviceFrames[deviceFrames.count - 1].children.append(node)
        }
    }

    private func recordDeviceRefusal(_ what: String) {
        guard deviceRefusal == nil else { return }
        deviceRefusal = "the virtio-mem device contains \(what)"
    }
}
