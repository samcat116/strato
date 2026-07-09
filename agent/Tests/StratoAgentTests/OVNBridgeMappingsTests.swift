import Testing

@testable import StratoAgentCore

@Suite("OVN Bridge Mappings")
struct OVNBridgeMappingsTests {

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

@Suite("OVN Uplink Config")
struct OVNUplinkConfigTests {

    @Test("externalIP extracts the address from a valid external_cidr")
    func externalIPValid() {
        let uplink = OVNUplinkConfig(externalCIDR: "203.0.113.2/24", gateway: "203.0.113.1")
        #expect(uplink.externalIP == "203.0.113.2")
        #expect(uplink.bridge == "br-ex")
        #expect(uplink.physnet == "physnet-strato")
    }

    @Test("externalIP is nil for a malformed external_cidr")
    func externalIPInvalid() {
        #expect(OVNUplinkConfig(externalCIDR: "203.0.113.2").externalIP == nil)
        #expect(OVNUplinkConfig(externalCIDR: "not-an-ip/24").externalIP == nil)
    }
}
