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
