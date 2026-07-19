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

    @Test("externalIP6 extracts the address from a valid external_cidr6, canonicalized")
    func externalIP6Valid() {
        let uplink = OVNUplinkConfig(
            externalCIDR: "203.0.113.2/24", gateway: "203.0.113.1",
            externalCIDR6: "2001:0DB8:0000::2/64", gateway6: "2001:db8::1")
        // Canonical RFC 5952 form, so it compares equal to what OVN reports
        // back and the SNAT rule doesn't churn on every reconcile.
        #expect(uplink.externalIP6 == "2001:db8::2")
        #expect(uplink.gateway6 == "2001:db8::1")
    }

    @Test("externalIP6 is nil when external_cidr6 is absent or malformed")
    func externalIP6Invalid() {
        // Absent: the common v4-only uplink, which must stay valid.
        let v4Only = OVNUplinkConfig(externalCIDR: "203.0.113.2/24")
        #expect(v4Only.externalIP6 == nil)
        #expect(v4Only.externalIP == "203.0.113.2")

        #expect(OVNUplinkConfig(externalCIDR: "203.0.113.2/24", externalCIDR6: "2001:db8::2").externalIP6 == nil)
        #expect(OVNUplinkConfig(externalCIDR: "203.0.113.2/24", externalCIDR6: "junk/64").externalIP6 == nil)
        // An out-of-range prefix must be nil, not just a bad address half:
        // ensureUplink validates the whole CIDR, so a laxer accessor here would
        // leave the gateway port v4-only while SNAT still translated to an
        // address the port never claimed.
        #expect(
            OVNUplinkConfig(externalCIDR: "203.0.113.2/24", externalCIDR6: "2001:db8::2/129").externalIP6 == nil)
        #expect(
            OVNUplinkConfig(externalCIDR: "203.0.113.2/24", externalCIDR6: "2001:db8::2/foo").externalIP6 == nil)
        // A v4 address in the v6 slot is not a valid v6 uplink.
        #expect(
            OVNUplinkConfig(externalCIDR: "203.0.113.2/24", externalCIDR6: "203.0.113.9/24").externalIP6 == nil)
    }
}
