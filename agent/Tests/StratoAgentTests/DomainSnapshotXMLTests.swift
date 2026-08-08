import Foundation
import Libvirt
import StratoShared
import Testing

@testable import StratoAgentCore

/// The checkpoint document and the two readings taken off the result (STR-134,
/// issue #564).
///
/// A wrong document here is not a subtle failure — `<memory snapshot='internal'/>`
/// on an inactive domain is refused outright, and omitting it on a running one
/// captures the disks and silently drops the guest's RAM, which is the whole
/// thing a checkpoint exists to hold.
@Suite("libvirt checkpoint documents")
struct DomainSnapshotXMLTests {

    static let snapshotId = "3f2a1b0c-9d8e-4f70-a1b2-c3d4e5f60718"

    /// Guest RAM can only come from a live domain; libvirt rejects
    /// `<memory snapshot='internal'/>` on an inactive one, where the checkpoint
    /// is the disks alone.
    @Test("the document asks for memory only when the guest is running")
    func document() {
        let name = VMSnapshotTag.tag(for: Self.snapshotId)

        #expect(
            DomainSnapshotXML.document(name: name, includesMemory: true) == """
                <domainsnapshot>
                  <name>strato-\(Self.snapshotId)</name>
                  <memory snapshot='internal'/>
                </domainsnapshot>

                """)
        #expect(
            DomainSnapshotXML.document(name: name, includesMemory: false) == """
                <domainsnapshot>
                  <name>strato-\(Self.snapshotId)</name>
                </domainsnapshot>

                """)
    }

    /// Naming no disks lets libvirt capture every disk it can — the selection
    /// a QMP-driven capture's block-node rules spent their effort arriving at.
    @Test("the document names no disks")
    func documentSelectsNoDisks() {
        #expect(!DomainSnapshotXML.document(name: "strato-x", includesMemory: true).contains("<disks"))
    }

    // MARK: - Reading the result back

    static let capturedSnapshot = """
        <domainsnapshot>
          <name>strato-\(snapshotId)</name>
          <state>running</state>
          <creationTime>1780000000</creationTime>
          <memory snapshot='internal'/>
          <disks>
            <disk name='vda' snapshot='internal'/>
            <disk name='vdb' snapshot='no'/>
            <disk name='vdc' snapshot='internal'/>
          </disks>
          <domain type='kvm'>
            <name>vm</name>
          </domain>
        </domainsnapshot>
        """

    @Test("the captured disks are reported, and the skipped ones are not")
    func deviceNodes() {
        #expect(DomainSnapshotXML.deviceNodes(inSnapshotXML: Self.capturedSnapshot) == ["vda", "vdc"])
    }

    /// Diagnostics only, and the checkpoint already exists by the time this
    /// runs — failing a captured checkpoint because its description would not
    /// parse would leave an artifact on the host that no row describes.
    @Test("an unreadable snapshot document reports no disks rather than failing")
    func deviceNodesTolerateGarbage() {
        #expect(DomainSnapshotXML.deviceNodes(inSnapshotXML: "<domainsnapshot><disks>").isEmpty)
        #expect(DomainSnapshotXML.deviceNodes(inSnapshotXML: "").isEmpty)
    }

    static func stat(_ field: String, _ value: UInt64) -> TypedParam {
        TypedParam(field: field, value: .ullong(value))
    }

    /// `memory_processed` is what the job actually wrote; `memory_total` is
    /// what it expected to. The first wins where both are present.
    @Test("the state size comes from what the job wrote")
    func stateSize() {
        #expect(
            DomainSnapshotXML.vmStateSizeBytes(fromJobStats: [
                Self.stat("memory_total", 999), Self.stat("memory_processed", 4096),
                Self.stat("disk_processed", 1 << 30),
            ]) == 4096)
        #expect(
            DomainSnapshotXML.vmStateSizeBytes(fromJobStats: [Self.stat("memory_total", 8192)]) == 8192)
    }

    /// Nil is "unknown", never "empty": the control plane keeps its own
    /// estimate rather than recording a zero for a checkpoint that exists.
    @Test("an unreported state size is unknown, not zero")
    func stateSizeUnknown() {
        #expect(DomainSnapshotXML.vmStateSizeBytes(fromJobStats: []) == nil)
        #expect(DomainSnapshotXML.vmStateSizeBytes(fromJobStats: [Self.stat("memory_processed", 0)]) == nil)
        #expect(
            DomainSnapshotXML.vmStateSizeBytes(fromJobStats: [
                TypedParam(field: "operation", value: .int(3))
            ]) == nil)
        // A count that cannot be represented is corrupt rather than large;
        // reporting it wrapped would be worse than reporting nothing.
        #expect(DomainSnapshotXML.vmStateSizeBytes(fromJobStats: [Self.stat("memory_processed", .max)]) == nil)
    }

    /// The hypervisor's version, not libvirtd's: a restore needs a compatible
    /// QEMU, which is what `virConnectGetVersion` reports.
    @Test("the packed hypervisor version is unpacked")
    func hypervisorVersion() {
        #expect(DomainSnapshotXML.hypervisorVersion(packed: 9_002_000) == "9.2.0")
        #expect(DomainSnapshotXML.hypervisorVersion(packed: 10_000_050) == "10.0.50")
        // Zero is libvirt saying it has no version to report.
        #expect(DomainSnapshotXML.hypervisorVersion(packed: 0) == nil)
    }
}
