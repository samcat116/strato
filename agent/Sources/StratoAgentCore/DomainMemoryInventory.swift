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
/// - the memory **device's** size and block size, which are what makes an
///   update fragment match the device already present rather than describe a
///   different one;
/// - whether there is a memory device at all.
///
/// `QEMUService` keeps the equivalent in `vmSpawnSizing`, a dictionary keyed by
/// VM id that is lost whenever the agent restarts. Here the domain document is
/// the record, so this is a query — which is also why a VM defined by an older
/// spec resizes correctly against the headroom it really has instead of the
/// headroom its newest spec asks for.
public struct DomainMemoryLayout: Sendable, Equatable {
    /// `<currentMemory>` — what the guest boots with.
    public let bootBytes: Int64
    /// `<memory>` — boot plus every memory device.
    public let maximumBytes: Int64
    /// The `<memory model='virtio-mem'>` device, absent for a VM defined with
    /// no hot-plug headroom.
    public let virtioMem: VirtioMem?

    public struct VirtioMem: Sendable, Equatable {
        /// `<target><size>` — the whole hot-pluggable region.
        public let sizeBytes: Int64
        /// `<target><block>` — the granularity every `<requested>` must be a
        /// multiple of.
        public let blockBytes: Int64
        /// `<target><requested>` — how much of the region is plugged in now.
        public let requestedBytes: Int64

        public init(sizeBytes: Int64, blockBytes: Int64, requestedBytes: Int64) {
            self.sizeBytes = sizeBytes
            self.blockBytes = blockBytes
            self.requestedBytes = requestedBytes
        }
    }

    public init(bootBytes: Int64, maximumBytes: Int64, virtioMem: VirtioMem?) {
        self.bootBytes = bootBytes
        self.maximumBytes = maximumBytes
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
        guard let boot = delegate.currentMemory ?? delegate.memory, let maximum = delegate.memory else {
            throw DomainInventoryError.unparseable("the domain document declares no memory size")
        }
        return DomainMemoryLayout(
            bootBytes: boot, maximumBytes: maximum, virtioMem: delegate.virtioMem)
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

/// Collects the domain's memory elements and its virtio-mem device.
///
/// Scoped by parent throughout: `<memory>` means the domain's total when it
/// hangs off `<domain>` and a memory *device* when it hangs off `<devices>`,
/// and `<size>` appears under half a dozen unrelated elements.
private final class MemoryCollector: NSObject, XMLParserDelegate {
    private(set) var memory: Int64?
    private(set) var currentMemory: Int64?
    private(set) var virtioMem: DomainMemoryLayout.VirtioMem?

    private var path: [String] = []
    private var text: String?
    private var unit: String?
    /// Set while inside `<devices><memory model='virtio-mem'>`.
    private var inVirtioMem = false
    private var deviceSize: Int64?
    private var deviceBlock: Int64?
    private var deviceRequested: Int64?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        defer { path.append(elementName) }

        if elementName == "memory", path.last == "devices" {
            inVirtioMem = attributes["model"] == "virtio-mem"
            deviceSize = nil
            deviceBlock = nil
            deviceRequested = nil
            return
        }
        switch (path.last, elementName) {
        case ("domain", "memory"), ("domain", "currentMemory"):
            text = ""
            unit = attributes["unit"]
        case ("target", "size"), ("target", "block"), ("target", "requested"):
            guard inVirtioMem else { return }
            text = ""
            unit = attributes["unit"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard text != nil else { return }
        text? += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        path.removeLast()

        if elementName == "memory", path.last == "devices" {
            if inVirtioMem, let size = deviceSize, let block = deviceBlock, block > 0 {
                virtioMem = DomainMemoryLayout.VirtioMem(
                    sizeBytes: size, blockBytes: block, requestedBytes: deviceRequested ?? 0)
            }
            inVirtioMem = false
            return
        }

        guard let raw = text else { return }
        let value = DomainMemoryInventory.bytes(raw, unit: unit)
        text = nil
        unit = nil
        guard let value else { return }

        switch elementName {
        case "memory" where path.last == "domain": memory = value
        case "currentMemory": currentMemory = value
        case "size" where inVirtioMem: deviceSize = value
        case "block" where inVirtioMem: deviceBlock = value
        case "requested" where inVirtioMem: deviceRequested = value
        default: break
        }
    }
}
