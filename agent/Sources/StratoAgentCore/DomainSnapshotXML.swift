import Foundation
import Libvirt

#if canImport(FoundationXML)
import FoundationXML
#endif

/// The `<domainsnapshot>` document a VM checkpoint is taken with, and the two
/// readings taken off the result (STR-134, issue #564).
///
/// libvirt's system checkpoint is what `QEMUService` assembles by hand out of
/// `snapshot-save` plus a block-node selection: guest RAM, device state and the
/// disks captured at one instant, all inside the VM's own qcow2 files.
/// `VMCheckpointTargets` has no counterpart here — libvirt chooses the disks —
/// so what is left to own is the document and the two facts
/// `VMCheckpointReport` carries.
///
/// **Two host preconditions**, both established before this file is reachable
/// (STR-130): the UEFI varstore must be qcow2 rather than raw, which
/// `DomainXMLBuilder` emits, and the host needs libvirt ≥ 11.5, which
/// `LibvirtProbe.minimumVersion` gates `.qemu` on. On anything older libvirt
/// refuses outright with "internal snapshots of a VM with pflash based firmware
/// are not supported", because internal snapshots only moved onto the modern
/// `snapshot-save` job API in 10.9.
public enum DomainSnapshotXML {

    /// The document for a checkpoint named `name`.
    ///
    /// - Parameter includesMemory: whether the domain is running. Guest RAM can
    ///   only be captured from a live domain; libvirt rejects
    ///   `<memory snapshot='internal'/>` on an inactive one, where the
    ///   checkpoint is the disks alone. Passed in rather than assumed, because
    ///   the reconciler can ask for a capture of a VM the operator has since
    ///   stopped and refusing it would strand the artifact on the one host that
    ///   holds its disks.
    public static func document(name: String, includesMemory: Bool) -> String {
        var snapshot = DomainXMLNode("domainsnapshot")
        snapshot.append(DomainXMLNode("name", text: name))
        if includesMemory {
            snapshot.append(DomainXMLNode("memory", [("snapshot", "internal")]))
        }
        // No `<disks>`: naming none lets libvirt capture every disk it can,
        // which is the selection `VMCheckpointTargets.forCapture` spent its
        // rules arriving at.
        return snapshot.render()
    }

    /// The disks a captured checkpoint spans, from `virDomainSnapshotGetXMLDesc`.
    ///
    /// Diagnostics only — `VMCheckpointReport.deviceNodes` is not read back by
    /// anything that acts on it — so a document that cannot be parsed yields an
    /// empty list rather than failing a checkpoint that has already been taken.
    public static func deviceNodes(inSnapshotXML xml: String) -> [String] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = SnapshotDiskCollector()
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.names
    }

    /// Bytes of guest RAM the completed snapshot job wrote, or nil when the
    /// daemon reported none.
    ///
    /// Nil is "unknown", never "empty" — `VMCheckpointReport` documents it that
    /// way and the control plane keeps its own estimate rather than recording a
    /// zero. A checkpoint of an inactive domain legitimately has no memory
    /// figure at all, and so does one whose job stats were cleared by another
    /// job before this could ask.
    public static func vmStateSizeBytes(fromJobStats params: [TypedParam]) -> Int64? {
        var byField: [String: Int64] = [:]
        for param in params {
            switch param.value {
            case .ullong(let value): byField[param.field] = Int64(exactly: value)
            case .llong(let value): byField[param.field] = value
            case .uint(let value): byField[param.field] = Int64(value)
            case .int(let value): byField[param.field] = Int64(value)
            default: continue
            }
        }
        // `memory_processed` is what the job actually wrote; `memory_total` is
        // what it expected to. The first is the truthful answer where both are
        // present, and where only the second is, it is much better than nothing.
        for field in ["memory_processed", "memory_total"] {
            if let value = byField[field], value > 0 { return value }
        }
        return nil
    }

    /// libvirt's packed hypervisor version (`major * 1_000_000 + minor * 1_000
    /// + release`) as a dotted string, for `VMCheckpointReport.hypervisorVersion`.
    ///
    /// This is QEMU's version, not libvirtd's: `virConnectGetVersion` reports
    /// the hypervisor behind the connection, which is the build a restore has
    /// to be compatible with — the same thing `QMPProbeClient.qemuVersion`
    /// asks QEMU for directly.
    public static func hypervisorVersion(packed: UInt64) -> String? {
        guard packed > 0 else { return nil }
        let major = packed / 1_000_000
        let minor = (packed % 1_000_000) / 1_000
        let release = packed % 1_000
        return "\(major).\(minor).\(release)"
    }
}

/// Collects `<domainsnapshot><disks><disk name='…'>` entries, skipping disks
/// the snapshot explicitly excluded.
private final class SnapshotDiskCollector: NSObject, XMLParserDelegate {
    private(set) var names: [String] = []
    private var path: [String] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        defer { path.append(elementName) }
        guard elementName == "disk", path.last == "disks" else { return }
        guard attributes["snapshot"] != "no", let name = attributes["name"] else { return }
        names.append(name)
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        path.removeLast()
    }
}
