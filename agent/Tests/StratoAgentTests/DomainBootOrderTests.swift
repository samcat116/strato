import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

@Suite("libvirt persistent disk boot order")
struct DomainBootOrderTests {
    static let root = "00000000-0000-4000-8000-000000000001"
    static let order30 = "00000000-0000-4000-8000-000000000030"
    static let order10 = "00000000-0000-4000-8000-000000000010"
    static let order20 = "00000000-0000-4000-8000-000000000020"

    static let inactiveDomain = """
        <domain type='kvm'>
          <name>vm</name>
          <devices>
            <disk type='file' device='disk'>
              <source file='/volumes/root.qcow2'/>
              <target dev='vda' bus='virtio'/>
              <serial>vol-\(root)</serial>
              <boot order='1'/>
            </disk>
            <disk type='file' device='disk'>
              <source file='/volumes/order-30.qcow2'/>
              <target dev='vdc' bus='virtio'/>
              <serial>vol-\(order30)</serial>
            </disk>
            <disk type='file' device='disk'>
              <source file='/volumes/order-10.qcow2'/>
              <target dev='vdd' bus='virtio'/>
              <serial>vol-\(order10)</serial>
            </disk>
            <disk type='file' device='disk'>
              <source file='/volumes/order-20.qcow2'/>
              <target dev='vde' bus='virtio'/>
              <serial>vol-\(order20)</serial>
            </disk>
          </devices>
        </domain>
        """

    private static func bootOrdersByTarget(in xml: String) throws -> [String: String] {
        let domain = try DomainXMLNode.parse(xml)
        let disks = try #require(domain.child(named: "devices"))
            .children.filter { $0.name == "disk" }
        return Dictionary(
            uniqueKeysWithValues: disks.compactMap { disk in
                guard let target = disk.child(named: "target")?.attribute("dev"),
                    let order = disk.child(named: "boot")?.attribute("order")
                else { return nil }
                return (target, order)
            })
    }

    @Test("request order 30, 10, 20 becomes a dense persistent total order")
    func denseTotalOrder() throws {
        let rewritten = try #require(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain,
                orderedVolumeIds: [Self.root, Self.order10, Self.order20, Self.order30]))
        let bootByTarget = try Self.bootOrdersByTarget(in: rewritten)
        #expect(bootByTarget["vda"] == "1")
        #expect(bootByTarget["vdc"] == "4")
        #expect(bootByTarget["vdd"] == "2")
        #expect(bootByTarget["vde"] == "3")
    }

    @Test("dense orders are stable across a second persistent-definition pass")
    func idempotentAcrossRestartPass() throws {
        let ordered = [Self.root, Self.order10, Self.order20, Self.order30]
        let first = try #require(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain, orderedVolumeIds: ordered))
        #expect(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: first, orderedVolumeIds: ordered) == nil)
    }

    @Test("pre-boot redefinition repairs attachments that already converged")
    func preBootRepairForExistingAttachments() throws {
        let volumes = [
            Self.volume(Self.root, device: 0, bootOrder: 0),
            Self.volume(Self.order10, device: 2, bootOrder: 10),
            Self.volume(Self.order20, device: 3, bootOrder: 20),
            Self.volume(Self.order30, device: 1, bootOrder: 30),
        ]
        let rewritten = try #require(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain, volumes: volumes))

        #expect(
            try Self.bootOrdersByTarget(in: rewritten)
                == ["vda": "1", "vdc": "4", "vdd": "2", "vde": "3"])
    }

    @Test("pre-boot redefinition leaves legacy image-backed boot metadata alone")
    func preBootRepairSkipsSpecsWithoutExplicitOrder() throws {
        #expect(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain,
                volumes: [Self.volume(Self.root, device: 0, bootOrder: nil)]) == nil)
    }

    @Test("manifest realization preserves the authoritative VMSpec order")
    func manifestPreservesVMSpecOrderForEqualValues() {
        let first = Self.volume(Self.order30, device: 3, bootOrder: 10)
        let second = Self.volume(Self.order10, device: 1, bootOrder: 10)
        let recording = ManifestVolumeOrder.recording(
            first,
            in: [second],
            authoritative: [first, second])

        #expect(recording.volumes.map(\.volumeId) == [first.volumeId, second.volumeId])
        #expect(
            recording.orderedBootVolumeIds
                == [first.volumeId.uuidString, second.volumeId.uuidString])
    }

    @Test("volumes without an API boot order lose stale libvirt metadata")
    func removesStaleUnorderedMetadata() throws {
        let rewritten = try #require(
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain,
                orderedVolumeIds: [Self.root, Self.order20]))
        #expect(
            try Self.bootOrdersByTarget(in: rewritten)
                == ["vda": "1", "vde": "2"])
    }

    @Test("an incomplete persistent disk set is refused instead of partially ordered")
    func missingOrderedVolumeIsRefused() {
        #expect(throws: DomainInventoryError.self) {
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain,
                orderedVolumeIds: [Self.root, "ffffffff-ffff-4fff-8fff-ffffffffffff"])
        }
    }

    @Test("a duplicate desired identity is refused before redefining the domain")
    func duplicateOrderedVolumeIsRefused() {
        #expect(throws: DomainInventoryError.self) {
            try DomainRedefinition.applyingBootOrder(
                toInactiveDomainXML: Self.inactiveDomain,
                orderedVolumeIds: [Self.root, Self.root.uppercased()])
        }
    }

    private static func volume(
        _ id: String, device: Int, bootOrder: Int?
    ) -> VolumeSpec {
        VolumeSpec(
            volumeId: UUID(uuidString: id)!,
            deviceName: .disk(device),
            bootOrder: bootOrder)
    }
}
