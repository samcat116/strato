import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Network Attachment & IPv4 helpers")
struct NetworkAttachmentTests {

    // MARK: - IPv4Address

    @Test("IPv4 parse/format round-trips")
    func ipv4RoundTrip() {
        for string in ["0.0.0.0", "192.168.1.7", "255.255.255.255", "10.0.2.15"] {
            let parsed = IPv4Address(string)
            #expect(parsed != nil)
            #expect(parsed?.description == string)
        }
    }

    @Test("invalid IPv4 strings are rejected")
    func ipv4Invalid() {
        for string in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "a.b.c.d", "1..2.3"] {
            #expect(IPv4Address(string) == nil, "'\(string)' should not parse")
        }
    }

    @Test("contiguous netmasks yield prefix lengths")
    func netmaskPrefixes() {
        #expect(IPv4Address("255.255.255.0")?.prefixLength == 24)
        #expect(IPv4Address("255.255.0.0")?.prefixLength == 16)
        #expect(IPv4Address("255.255.255.252")?.prefixLength == 30)
        #expect(IPv4Address("0.0.0.0")?.prefixLength == 0)
        #expect(IPv4Address("255.255.255.255")?.prefixLength == 32)
    }

    @Test("non-contiguous netmasks have no prefix length")
    func nonContiguousNetmask() {
        #expect(IPv4Address("255.0.255.0")?.prefixLength == nil)
        #expect(IPv4Address("0.255.255.0")?.prefixLength == nil)
    }

    // MARK: - subnetCIDR

    @Test("subnet CIDR derived from IP and netmask")
    func subnetDerivation() {
        #expect(subnetCIDR(ipAddress: "192.168.1.7", netmask: "255.255.255.0") == "192.168.1.0/24")
        #expect(subnetCIDR(ipAddress: "10.1.2.3", netmask: "255.255.0.0") == "10.1.0.0/16")
    }

    @Test("subnet CIDR is nil for missing or invalid parts")
    func subnetDerivationNil() {
        #expect(subnetCIDR(ipAddress: nil, netmask: "255.255.255.0") == nil)
        #expect(subnetCIDR(ipAddress: "192.168.1.7", netmask: nil) == nil)
        #expect(subnetCIDR(ipAddress: "not-an-ip", netmask: "255.255.255.0") == nil)
        #expect(subnetCIDR(ipAddress: "192.168.1.7", netmask: "255.0.255.0") == nil)
    }

    @Test("IPv6 subnet CIDR derived from address and prefix length")
    func subnet6Derivation() {
        #expect(
            subnet6CIDR(ip6Address: "fd12:3456:789a::100", prefixLength: 64) == "fd12:3456:789a::/64")
        #expect(subnet6CIDR(ip6Address: nil, prefixLength: 64) == nil)
        #expect(subnet6CIDR(ip6Address: "fd12::1", prefixLength: nil) == nil)
        #expect(subnet6CIDR(ip6Address: "not-an-ip", prefixLength: 64) == nil)
        #expect(subnet6CIDR(ip6Address: "fd12::1", prefixLength: 129) == nil)
    }

    // MARK: - NetworkAttachment coding

    @Test("attachment descriptor round-trips through Codable")
    func attachmentCodable() throws {
        let attachments: [NetworkAttachment] = [.tap(interface: "tap0123456789ab"), .userMode]
        let data = try JSONEncoder().encode(attachments)
        let decoded = try JSONDecoder().decode([NetworkAttachment].self, from: data)
        #expect(decoded == attachments)
    }
}
