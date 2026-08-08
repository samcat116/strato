import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// One `<disk>` read back out of a live domain document.
///
/// Only the fields a hot-unplug needs to *identify* the disk. Everything else
/// libvirt knows already, and copying more of the element into Swift would only
/// create a second, staler description of the domain.
public struct DomainDisk: Sendable, Equatable {
    /// `<target dev='…'>` — the guest device name, and the identifier libvirt
    /// matches a detach against.
    public let target: String
    /// `<source file='…'>`, absent for a disk with no source (an empty cdrom).
    public let sourceFile: String?
    /// `<serial>` — for a Strato volume, `QEMUDiskIdentity.deviceID`.
    public let serial: String?
    /// `<driver type='…'>`, echoed back on a detach fragment so it parses as
    /// the same kind of disk libvirt already has.
    public let driverType: String?

    public init(target: String, sourceFile: String? = nil, serial: String? = nil, driverType: String? = nil) {
        self.target = target
        self.sourceFile = sourceFile
        self.serial = serial
        self.driverType = driverType
    }
}

/// Reads a domain's disks back out of `virDomainGetXMLDesc`.
///
/// `LibvirtService` keeps no model of a domain — the whole point of driving
/// libvirtd is that it is the durable store — so hot-plug has to *ask* which
/// target names are taken and which disk carries a given volume. That answer
/// comes as a document, and parsing it is the kind of thing that has to be
/// tested away from a running daemon: this lives in the core library for the
/// same reason `DomainXMLBuilder` does.
public enum DomainDiskInventory {

    /// Every `<devices><disk>` in a domain document, in document order.
    ///
    /// Returns an empty array for a document that has none. A document that
    /// cannot be parsed at all throws, because the two are not the same thing:
    /// "this domain has no disks" would let a hot-plug pick `vda` on a VM whose
    /// boot disk is already there.
    public static func disks(inDomainXML xml: String) throws -> [DomainDisk] {
        guard let data = xml.data(using: .utf8) else {
            throw DomainInventoryError.unparseable("the domain document is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = DiskCollector()
        parser.delegate = delegate
        // `parse()` alone is not the check: swift-corelibs-foundation answers
        // **true** for a document that simply stops early (`<domain><devices>`
        // and nothing more), reporting the truncation only through
        // `parserError`. Trusting the return value there would turn a half-read
        // document into "this domain has no disks" — which is exactly the
        // answer that lets a hot-plug take `vda` and shadow the boot disk.
        guard parser.parse(), parser.parserError == nil else {
            throw DomainInventoryError.unparseable(
                parser.parserError?.localizedDescription ?? "the domain document could not be parsed")
        }
        // And an empty document parses cleanly while describing nothing at all.
        guard delegate.sawDomain else {
            throw DomainInventoryError.unparseable("no <domain> element")
        }
        return delegate.disks
    }

    /// The disk realizing `volumeId`, or nil when the domain has none.
    ///
    /// Matched on the serial rather than on the source path: a path is a fact
    /// about the host that the domain merely records, while the serial is the
    /// volume's identity written into the document on purpose (STR-129).
    public static func disk(forVolume volumeId: String, in disks: [DomainDisk]) -> DomainDisk? {
        let serial = QEMUDiskIdentity.deviceID(volumeId: volumeId)
        return disks.first { $0.serial == serial }
    }

    /// The lowest `vd…` name no disk in `disks` has taken.
    ///
    /// Lowest-free rather than next-after-highest, so a VM that has had volumes
    /// come and go does not walk its target names off toward `vdz` — and so the
    /// name a guest sees is a function of what is attached rather than of the
    /// order it happened in.
    public static func nextTargetDevice(after disks: [DomainDisk]) -> String {
        let used = Set(disks.map(\.target))
        var index = 0
        while used.contains(DomainXMLBuilder.targetDeviceName(index: index)) {
            index += 1
        }
        return DomainXMLBuilder.targetDeviceName(index: index)
    }
}

/// A domain document that could not be read, from either inventory
/// (`DomainDiskInventory` or `DomainMemoryInventory`).
///
/// One case, because there is one thing a caller can do about it: nothing that
/// reads a domain has a partial answer worth acting on, and every empty one is
/// actively dangerous — "no disks" lets a hot-plug take `vda`, and "no memory"
/// would make a resize compute a size from zero.
public enum DomainInventoryError: Error, Equatable, CustomStringConvertible {
    case unparseable(String)

    public var description: String {
        switch self {
        case .unparseable(let detail):
            return "libvirt's domain document could not be read: \(detail)"
        }
    }
}

/// Collects `<devices><disk>` elements. Scoped to that parent deliberately:
/// `<domainsnapshot>` documents carry a `<disks><disk name='vda'/>` list of
/// their own, and reading one of those as a domain disk would produce a disk
/// with no target and a name that means something else.
private final class DiskCollector: NSObject, XMLParserDelegate {
    private(set) var disks: [DomainDisk] = []
    /// Whether this was a domain document at all — an empty one parses cleanly.
    private(set) var sawDomain = false
    /// Ancestors of the element being parsed, innermost last.
    private var path: [String] = []
    private var target: String?
    private var sourceFile: String?
    private var serial: String?
    private var driverType: String?
    private var inDisk = false
    /// Character data of the `<serial>` currently open, if any. Accumulated
    /// rather than assigned: `XMLParser` may split text across callbacks.
    private var serialText: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        defer { path.append(elementName) }

        if elementName == "domain", path.isEmpty { sawDomain = true }
        if elementName == "disk", path.last == "devices" {
            inDisk = true
            target = nil
            sourceFile = nil
            serial = nil
            driverType = nil
            return
        }
        guard inDisk, path.last == "disk" else { return }
        switch elementName {
        case "target": target = attributes["dev"]
        case "source": sourceFile = attributes["file"]
        case "driver": driverType = attributes["type"]
        case "serial": serialText = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard serialText != nil else { return }
        serialText? += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        path.removeLast()

        if elementName == "serial", let text = serialText {
            serial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            serialText = nil
            return
        }
        guard elementName == "disk", inDisk else { return }
        inDisk = false
        // A disk with no target is one libvirt has not assigned a device name
        // to yet, which cannot happen in a document libvirtd handed back. It is
        // dropped rather than defaulted, so it can never shadow a real target.
        if let target {
            disks.append(
                DomainDisk(
                    target: target, sourceFile: sourceFile, serial: serial, driverType: driverType))
        }
    }
}
