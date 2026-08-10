import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Metadata Caller Index Tests")
struct MetadataCallerIndexTests {

    private static func nic(
        network: UUID, mac: String = "52:54:00:00:00:01", ipv4: String? = nil, ipv6: String? = nil
    ) -> MetadataNIC {
        MetadataNIC(
            deviceName: "net0", macAddress: mac, networkId: network, networkName: "tenant",
            ipAddress: ipv4, prefixLength: ipv4 == nil ? nil : 24,
            ipv6Address: ipv6, ipv6PrefixLength: ipv6 == nil ? nil : 64)
    }

    private static func instance(_ vmId: UUID, nics: [MetadataNIC]) -> InstanceMetadata {
        InstanceMetadata(instanceId: vmId, projectId: UUID(), nics: nics, serviceEnabled: true)
    }

    private static func address(_ text: String) -> MetadataCallerAddress {
        guard let address = MetadataCallerAddress(text) else {
            Issue.record("\(text) should parse as an address")
            return .v4(IPv4Address(raw: 0))
        }
        return address
    }

    @Test("An allocated v4 address resolves to its instance")
    func resolvesIPv4() {
        let network = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network, instances: [Self.instance(vmId, nics: [Self.nic(network: network, ipv4: "10.0.0.5")])])
        #expect(index.resolve(Self.address("10.0.0.5")) == .vm(vmId))
        #expect(index.resolve(Self.address("10.0.0.6")) == .unknown)
    }

    @Test("A v6 address resolves however it is spelled")
    func resolvesIPv6Canonically() {
        let network = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network,
            instances: [Self.instance(vmId, nics: [Self.nic(network: network, ipv6: "fd12:3456:789a:0:0:0:0:5")])])
        // The stored spelling, the compressed spelling and an uppercase
        // spelling are one key: the kernel reports whichever it likes.
        #expect(index.resolve(Self.address("fd12:3456:789a::5")) == .vm(vmId))
        #expect(index.resolve(Self.address("FD12:3456:789A::5")) == .vm(vmId))
    }

    @Test("An IPv4-mapped v6 source folds to the v4 key")
    func mappedIPv4Folds() {
        // A dual-stack socket reports a v4 peer as ::ffff:10.0.0.5; an index
        // that kept the two apart would miss exactly the callers it is for.
        let network = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network, instances: [Self.instance(vmId, nics: [Self.nic(network: network, ipv4: "10.0.0.5")])])
        #expect(index.resolve(Self.address("::ffff:10.0.0.5")) == .vm(vmId))
    }

    @Test("The EUI-64 link-local derived from the NIC's MAC resolves too")
    func resolvesLinkLocal() {
        // It is inside OVN's port_security already, so it is exactly as
        // unspoofable as the allocated addresses.
        let network = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network,
            instances: [Self.instance(vmId, nics: [Self.nic(network: network, mac: "52:54:00:12:34:56")])])
        let linkLocal = IPv6Address.linkLocalEUI64(fromMAC: "52:54:00:12:34:56")!
        #expect(index.resolve(.v6(linkLocal)) == .vm(vmId))
    }

    @Test("NICs on other networks are not keys in this network's index")
    func ignoresOtherNetworks() {
        // The namespace already scopes the listener to one network; a NIC on
        // another one is reachable from a different listener entirely.
        let network = UUID()
        let other = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network,
            instances: [
                Self.instance(
                    vmId,
                    nics: [
                        Self.nic(network: network, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5"),
                        Self.nic(network: other, mac: "52:54:00:00:00:0b", ipv4: "192.168.0.5"),
                    ])
            ])
        #expect(index.resolve(Self.address("10.0.0.5")) == .vm(vmId))
        #expect(index.resolve(Self.address("192.168.0.5")) == .unknown)
    }

    @Test("One address claimed by two instances is ambiguous, not a winner")
    func duplicateAddressIsAmbiguous() {
        let network = UUID()
        let first = UUID()
        let second = UUID()
        let index = MetadataCallerIndex(
            networkId: network,
            instances: [
                Self.instance(first, nics: [Self.nic(network: network, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5")]),
                Self.instance(second, nics: [Self.nic(network: network, mac: "52:54:00:00:00:0b", ipv4: "10.0.0.5")]),
            ])
        guard case .ambiguous(let vmIds) = index.resolve(Self.address("10.0.0.5")) else {
            Issue.record("two claimants must not resolve to one")
            return
        }
        #expect(Set(vmIds) == Set([first, second]))
    }

    @Test("One instance holding an address on two NICs is not ambiguous")
    func sameInstanceTwiceIsNotAmbiguous() {
        // Multiplicity within one instance is not a conflict — there is still
        // only one answer.
        let network = UUID()
        let vmId = UUID()
        let index = MetadataCallerIndex(
            networkId: network,
            instances: [
                Self.instance(
                    vmId,
                    nics: [
                        Self.nic(network: network, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5"),
                        Self.nic(network: network, mac: "52:54:00:00:00:0b", ipv4: "10.0.0.5"),
                    ])
            ])
        #expect(index.resolve(Self.address("10.0.0.5")) == .vm(vmId))
    }

    @Test("An address on no NIC is unknown, and an empty index resolves nothing")
    func unknownAddresses() {
        let network = UUID()
        let empty = MetadataCallerIndex(networkId: network, instances: [])
        #expect(empty.resolve(Self.address("10.0.0.5")) == .unknown)
        #expect(empty.resolve(Self.address("fd00::1")) == .unknown)
    }

    @Test("A source address with a zone id or a port is not an address at all")
    func malformedSources() {
        #expect(MetadataCallerAddress("fe80::1%eth0") == nil)
        #expect(MetadataCallerAddress("10.0.0.5:80") == nil)
        #expect(MetadataCallerAddress("") == nil)
        #expect(MetadataCallerAddress("not-an-address") == nil)
    }
}
