import Testing

@testable import App

@Suite("IPAM Service")
struct IPAMServiceTests {

    // MARK: - Pure allocation core

    @Test("first allocation skips the network address and gateway")
    func firstAllocation() throws {
        let allocation = try IPAMService.allocateIP(
            networkName: "default", subnet: "192.168.1.0/24", gateway: "192.168.1.1", used: [])
        #expect(allocation.ipAddress == "192.168.1.2")
        #expect(allocation.netmask == "255.255.255.0")
    }

    @Test("without a gateway the first host address is allocated")
    func noGateway() throws {
        let allocation = try IPAMService.allocateIP(
            networkName: "default", subnet: "10.0.0.0/16", gateway: nil, used: [])
        #expect(allocation.ipAddress == "10.0.0.1")
        #expect(allocation.netmask == "255.255.0.0")
    }

    @Test("used addresses are skipped; the lowest free one wins")
    func skipsUsed() throws {
        let used: Set<UInt32> = [
            IPAMService.parseIPv4("192.168.1.2")!,
            IPAMService.parseIPv4("192.168.1.3")!,
            IPAMService.parseIPv4("192.168.1.5")!,
        ]
        let allocation = try IPAMService.allocateIP(
            networkName: "default", subnet: "192.168.1.0/24", gateway: "192.168.1.1", used: used)
        #expect(allocation.ipAddress == "192.168.1.4")
    }

    @Test("a full subnet throws poolExhausted")
    func poolExhausted() {
        // /30 has two host addresses: .1 (gateway) and .2 (used).
        let used: Set<UInt32> = [IPAMService.parseIPv4("192.168.1.2")!]
        #expect(throws: IPAMService.IPAMError.poolExhausted(network: "tiny", subnet: "192.168.1.0/30")) {
            try IPAMService.allocateIP(
                networkName: "tiny", subnet: "192.168.1.0/30", gateway: "192.168.1.1", used: used)
        }
    }

    @Test("the broadcast address is never allocated")
    func broadcastExcluded() throws {
        // /30: hosts are .1 and .2 only; .3 is broadcast.
        let allocation = try IPAMService.allocateIP(
            networkName: "tiny", subnet: "192.168.1.0/30", gateway: nil,
            used: [
                IPAMService.parseIPv4("192.168.1.1")!
            ])
        #expect(allocation.ipAddress == "192.168.1.2")
    }

    @Test("invalid subnets are rejected")
    func invalidSubnet() {
        // Includes prefixes outside the allocatable /8–/30 range: /31–/32 have
        // no host range, and wider-than-/8 would make exhaustion scans huge.
        for subnet in ["not-a-cidr", "192.168.1.0", "192.168.1.0/33", "192.168.1.0/31", "0.0.0.0/1", "1.2.3/24"] {
            #expect(throws: IPAMService.IPAMError.invalidSubnet(subnet)) {
                try IPAMService.allocateIP(networkName: "x", subnet: subnet, gateway: nil, used: [])
            }
        }
    }

    @Test("a malformed gateway is rejected rather than silently allocatable")
    func invalidGateway() {
        // A typo like "192.168.1.1/24" must not degrade to "no gateway" — that
        // would hand the real gateway's address to the first VM.
        for gateway in ["192.168.1.1/24", "gateway", ""] {
            #expect(throws: IPAMService.IPAMError.invalidGateway(gateway)) {
                try IPAMService.allocateIP(
                    networkName: "default", subnet: "192.168.1.0/24", gateway: gateway, used: [])
            }
        }
    }

    @Test("an unnormalized subnet base is masked before allocation")
    func unnormalizedBase() throws {
        let allocation = try IPAMService.allocateIP(
            networkName: "default", subnet: "192.168.1.77/24", gateway: "192.168.1.1", used: [])
        #expect(allocation.ipAddress == "192.168.1.2")
    }

    // MARK: - Helpers

    @Test("firstHostAddress returns the conventional gateway")
    func firstHost() {
        #expect(IPAMService.firstHostAddress(inSubnet: "192.168.1.0/24") == "192.168.1.1")
        #expect(IPAMService.firstHostAddress(inSubnet: "10.0.0.0/8") == "10.0.0.1")
        #expect(IPAMService.firstHostAddress(inSubnet: "junk") == nil)
    }

    @Test("CIDR parsing accepts valid inputs and rejects malformed ones")
    func cidrParsing() {
        #expect(IPAMService.parseCIDR("192.168.1.0/24")?.prefix == 24)
        #expect(IPAMService.parseCIDR("0.0.0.0/0")?.prefix == 0)
        #expect(IPAMService.parseCIDR("192.168.1.0") == nil)
        #expect(IPAMService.parseCIDR("192.168.1.0/24/7") == nil)
        #expect(IPAMService.parseCIDR("299.0.0.1/24") == nil)
    }
}
