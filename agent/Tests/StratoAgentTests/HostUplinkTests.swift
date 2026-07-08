import Testing

@testable import StratoAgentCore

@Suite("Host Uplink Detection")
struct HostUplinkTests {

    @Test("parseRoute extracts source IP, egress device, and next-hop gateway")
    func parseRoute() {
        let json = """
            [{"dst":"1.1.1.1","gateway":"192.168.1.1","dev":"eth0","prefsrc":"192.168.1.10","flags":[]}]
            """
        let result = HostUplinkDetection.parseRoute(json)
        #expect(result?.ip == "192.168.1.10")
        #expect(result?.device == "eth0")
        #expect(result?.gateway == "192.168.1.1")
    }

    @Test("parseRoute yields a nil gateway for a directly-connected uplink")
    func parseRouteNoGateway() {
        let json = """
            [{"dst":"1.1.1.1","dev":"eth0","prefsrc":"10.0.0.5","flags":[]}]
            """
        let result = HostUplinkDetection.parseRoute(json)
        #expect(result?.ip == "10.0.0.5")
        #expect(result?.gateway == nil)
    }

    @Test("parseRoute returns nil without a source or device")
    func parseRouteMissing() {
        #expect(HostUplinkDetection.parseRoute("[{\"dst\":\"1.1.1.1\"}]") == nil)
        #expect(HostUplinkDetection.parseRoute("not json") == nil)
        #expect(HostUplinkDetection.parseRoute("[]") == nil)
    }

    @Test("parsePrefixLength finds the prefix for the matching inet address")
    func parsePrefix() {
        let json = """
            [{"ifname":"eth0","addr_info":[
              {"family":"inet6","local":"fe80::1","prefixlen":64},
              {"family":"inet","local":"192.168.1.10","prefixlen":24}
            ]}]
            """
        #expect(HostUplinkDetection.parsePrefixLength(json, forIP: "192.168.1.10") == 24)
        // A different IP on the interface isn't matched.
        #expect(HostUplinkDetection.parsePrefixLength(json, forIP: "10.0.0.1") == nil)
    }

    @Test("HostUplink renders its external router-port CIDR")
    func uplinkCIDR() {
        let uplink = HostUplink(ipAddress: "192.168.1.10", interface: "eth0", prefixLength: 24)
        #expect(uplink.cidr == "192.168.1.10/24")
    }

    // MARK: - Bridge mappings

    @Test("merged adds a provider mapping to an empty or nil value")
    func bridgeMappingAdd() {
        #expect(
            OVNBridgeMappings.merged(existing: nil, physnet: "physnet-strato", bridge: "br-ex")
                == "physnet-strato:br-ex")
        #expect(
            OVNBridgeMappings.merged(existing: "", physnet: "physnet-strato", bridge: "br-ex")
                == "physnet-strato:br-ex")
    }

    @Test("merged preserves other operators' mappings")
    func bridgeMappingPreserves() {
        let result = OVNBridgeMappings.merged(
            existing: "physnet1:br0", physnet: "physnet-strato", bridge: "br-ex")
        #expect(result == "physnet1:br0,physnet-strato:br-ex")
    }

    @Test("merged is a no-op when the mapping already matches")
    func bridgeMappingIdempotent() {
        #expect(
            OVNBridgeMappings.merged(
                existing: "physnet-strato:br-ex", physnet: "physnet-strato", bridge: "br-ex") == nil)
    }

    @Test("merged replaces a physnet pointing at a different bridge")
    func bridgeMappingReplace() {
        let result = OVNBridgeMappings.merged(
            existing: "physnet-strato:br-old", physnet: "physnet-strato", bridge: "br-ex")
        #expect(result == "physnet-strato:br-ex")
    }
}
