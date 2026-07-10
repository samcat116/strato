import Testing

@testable import StratoAgentCore

@Suite("OVN DHCP option shaping")
struct DHCPOptionsTests {

    @Test("required options are always present with defaults")
    func requiredOptions() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil, subnet: "10.0.0.0/24")

        #expect(options["server_id"] == "10.0.0.1")
        #expect(options["router"] == "10.0.0.1")
        #expect(options["lease_time"] == "3600")  // default
        #expect(options["server_mac"] != nil)
        // Absent optional config produces no key at all.
        #expect(options["dns_server"] == nil)
        #expect(options["domain_name"] == nil)
    }

    @Test("DNS servers use OVN set syntax; domain is quoted; lease honored")
    func fullOptions() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "192.168.1.1",
            dnsServers: ["1.1.1.1", " 8.8.8.8 "],
            domainName: "corp.example.com",
            leaseTime: 7200,
            subnet: "192.168.1.0/24")

        #expect(options["dns_server"] == "{1.1.1.1, 8.8.8.8}")
        #expect(options["domain_name"] == "\"corp.example.com\"")
        #expect(options["lease_time"] == "7200")
    }

    @Test("v4 options take only the IPv4 entries of a mixed DNS list")
    func v4OptionsSplitMixedDNS() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1",
            dnsServers: ["1.1.1.1", "fd00::53", "8.8.8.8"],
            domainName: nil, leaseTime: nil, subnet: "10.0.0.0/24")
        #expect(options["dns_server"] == "{1.1.1.1, 8.8.8.8}")
    }

    @Test("v6 options: server_id is a MAC, DNS is the v6 entries, no router option")
    func v6Options() {
        let options = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: ["1.1.1.1", "fd00::53", " 2001:4860:4860::8888 "],
            domainName: "corp.example.com",
            subnet6: "fd12:3456:789a::/64")

        // DHCPv6's server_id seeds the server DUID — a MAC, never an IP.
        #expect(options["server_id"] == OVNDHCPOptionsBuilder.serverMAC(for: "fd12:3456:789a::/64"))
        #expect(options["dns_server"] == "{fd00::53, 2001:4860:4860::8888}")
        #expect(options["domain_search"] == "\"corp.example.com\"")
        // DHCPv6 cannot convey a default route — that's the RA's job.
        #expect(options["router"] == nil)
        #expect(options["server_mac"] == nil)
    }

    @Test("v6 options omit DNS when the list has no v6 entries")
    func v6OptionsWithoutV6DNS() {
        let options = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: ["1.1.1.1"], domainName: nil, subnet6: "fd00::/64")
        #expect(options["dns_server"] == nil)
        #expect(options["domain_search"] == nil)
    }

    @Test("server MAC is stable per subnet and locally administered")
    func serverMACStability() {
        let a = OVNDHCPOptionsBuilder.serverMAC(for: "10.0.0.0/24")
        let b = OVNDHCPOptionsBuilder.serverMAC(for: "10.0.0.0/24")
        let c = OVNDHCPOptionsBuilder.serverMAC(for: "10.1.0.0/24")

        #expect(a == b)  // deterministic across calls / restarts
        #expect(a != c)  // differs by subnet

        // Locally administered (bit 0x02 set) and unicast (bit 0x01 clear) in the
        // first octet.
        let firstOctet = UInt8(a.split(separator: ":").first!, radix: 16)!
        #expect(firstOctet & 0x02 == 0x02)
        #expect(firstOctet & 0x01 == 0x00)
    }
}
