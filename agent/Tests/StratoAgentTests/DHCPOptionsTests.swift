import Foundation
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

    @Test("a metadata-publishing network advertises the IMDS route via option 121")
    func classlessStaticRouteAdvertisesMetadata() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil, subnet: "10.0.0.0/24",
            metadataEnabled: true)

        // On-link (next hop 0.0.0.0): OVN's ARP responder answers for the
        // localport's own address, and no logical router has a path to it.
        #expect(options["classless_static_route"] == "{169.254.169.254/32,0.0.0.0, 0.0.0.0/0,10.0.0.1}")
        // The default route rides along because RFC 3442 makes a client that
        // understands option 121 ignore option 3 outright — omitting it would
        // trade the guest's IMDS route for its default gateway.
        #expect(options["classless_static_route"]?.contains("0.0.0.0/0,10.0.0.1") == true)
        // `router` stays for clients that don't implement 121.
        #expect(options["router"] == "10.0.0.1")
    }

    @Test("a network with the metadata service off advertises no static routes")
    func classlessStaticRouteOmittedWithoutMetadata() {
        // Also the shape a control plane predating `metadataEnabled` produces:
        // silence advertises nothing rather than a route to an address it never
        // asked to publish.
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil, subnet: "10.0.0.0/24")
        #expect(options["classless_static_route"] == nil)
        #expect(options["router"] == "10.0.0.1")
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
        // Nor a metadata route: DHCPv6 has no option 121, which is why the v6
        // IMDS route travels in the guest's `network-config` instead.
        #expect(options["classless_static_route"] == nil)
    }

    @Test("v6 options omit DNS when the list has no v6 entries")
    func v6OptionsWithoutV6DNS() {
        let options = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: ["1.1.1.1"], domainName: nil, subnet6: "fd00::/64")
        #expect(options["dns_server"] == nil)
        #expect(options["domain_search"] == nil)
    }

    @Test("a malformed domain is dropped from both families rather than emitted")
    func malformedDomainIsDropped() {
        // The control plane refuses these on write (issue #876); a row that
        // predates the validation still holds one. A `"` would end OVN's quoted
        // option early and make the whole DHCP_Options row unparseable, costing
        // every VM on the network its lease — so the option is dropped and the
        // guest simply gets no search domain. Everything else stays.
        for bad in ["corp\".com", "corp.example.com\n routes:", "corp .com", "-corp.com", "corp..com"] {
            let v4 = OVNDHCPOptionsBuilder.v4Options(
                gateway: "10.0.0.1", dnsServers: ["1.1.1.1"], domainName: bad, leaseTime: nil,
                subnet: "10.0.0.0/24")
            #expect(v4["domain_name"] == nil, "'\(bad)' should not be advertised")
            #expect(v4["dns_server"] == "{1.1.1.1}", "'\(bad)' should not cost the row its DNS")
            #expect(v4["router"] == "10.0.0.1")

            let v6 = OVNDHCPOptionsBuilder.v6Options(
                dnsServers: ["fd00::53"], domainName: bad, subnet6: "fd00::/64")
            #expect(v6["domain_search"] == nil, "'\(bad)' should not be advertised")
            #expect(v6["dns_server"] == "{fd00::53}")
        }
    }

    @Test("a single-label domain is advertised, and surrounding whitespace never reaches the guest")
    func singleLabelAndTrimmedDomains() {
        // `internal` is a legitimate search domain — the label grammar is what
        // keeps the option well formed, not the label count.
        let v4 = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: "internal", leaseTime: nil, subnet: "10.0.0.0/24")
        #expect(v4["domain_name"] == "\"internal\"")

        let v6 = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: [], domainName: " corp.example.com \n", subnet6: "fd00::/64")
        #expect(v6["domain_search"] == "\"corp.example.com\"")
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

    @Test("server MAC preserves the deployed subnet identity derivation")
    func serverMACCompatibility() {
        #expect(OVNDHCPOptionsBuilder.serverMAC(for: "10.0.0.0/24") == "4e:1f:e1:0d:e0:ee")
        #expect(OVNDHCPOptionsBuilder.serverMAC(for: "fd12:3456:789a::/64") == "a2:23:71:ae:a5:14")
    }
}

/// Which `DHCP_Options` row belongs to which network (issue #765). This is the
/// rule that keeps two projects' same-named networks from sharing one row.
@Suite("DHCP row identity")
struct DHCPRowIdentityTests {

    @Test("A managed row carries the network's id, its name as a label, and the marker")
    func externalIDsStamping() {
        let networkId = UUID()
        let ids = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: "default")

        #expect(ids[DHCPRowIdentity.networkIDKey] == networkId.uuidString.lowercased())
        #expect(ids[DHCPRowIdentity.networkNameKey] == "default")
        #expect(ids[DHCPRowIdentity.managedKey] == DHCPRowIdentity.managedValue)
    }

    @Test("Two same-named networks on the same subnet match disjointly")
    func sameNameSameSubnetDoesNotCollide() {
        // The configuration per-project isolation creates: both projects call
        // their network "default" and both use 192.168.1.0/24.
        let cidr = "192.168.1.0/24"
        let projectA = UUID()
        let projectB = UUID()
        let rowA = DHCPRowIdentity.externalIDs(networkId: projectA, networkName: "default")
        let rowB = DHCPRowIdentity.externalIDs(networkId: projectB, networkName: "default")

        #expect(DHCPRowIdentity.isOwn(rowA, rowCIDR: cidr, cidr: cidr, networkId: projectA))
        #expect(DHCPRowIdentity.isOwn(rowB, rowCIDR: cidr, cidr: cidr, networkId: projectB))
        // Neither may claim the other's row — the regression this guards.
        #expect(!DHCPRowIdentity.isOwn(rowA, rowCIDR: cidr, cidr: cidr, networkId: projectB))
        #expect(!DHCPRowIdentity.isOwn(rowB, rowCIDR: cidr, cidr: cidr, networkId: projectA))
    }

    @Test("A row for another CIDR, or one no one manages, is never claimed")
    func nonMatchingRowsRejected() {
        let networkId = UUID()
        let ids = DHCPRowIdentity.externalIDs(networkId: networkId, networkName: "default")

        // Right network, wrong subnet: a renumbered network's stale row.
        #expect(!DHCPRowIdentity.isOwn(ids, rowCIDR: "10.0.0.0/24", cidr: "192.168.1.0/24", networkId: networkId))
        // An operator's hand-made row for the same prefix is never adopted.
        let operatorRow = [DHCPRowIdentity.networkIDKey: networkId.uuidString.lowercased()]
        #expect(!DHCPRowIdentity.isOwn(operatorRow, rowCIDR: "10.0.0.0/24", cidr: "10.0.0.0/24", networkId: networkId))
        #expect(!DHCPRowIdentity.isOwn(nil, rowCIDR: "10.0.0.0/24", cidr: "10.0.0.0/24", networkId: networkId))
    }

}

@Suite("DHCP Options — per-network resolver")
struct DHCPOptionsResolverTests {

    // MARK: - The per-network resolver (STR-40)

    @Test("With the resolver on, the guest is told the resolver rather than the upstreams")
    func resolverReplacesDNSServer() {
        // The substitution happens agent-side so one field carries one meaning
        // on the wire, and so a NIC degraded to user-mode can fall back to the
        // raw list.
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: ["1.1.1.1", "8.8.8.8"], domainName: nil, leaseTime: nil,
            subnet: "10.0.0.0/24", resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"])
        #expect(options["dns_server"] == "{169.254.1.0}")
    }

    @Test("With the resolver off, the configured servers reach the guest unchanged")
    func resolverOffKeepsLegacyBehaviour() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: ["1.1.1.1", "8.8.8.8"], domainName: nil, leaseTime: nil,
            subnet: "10.0.0.0/24", resolverAddresses: [])
        #expect(options["dns_server"] == "{1.1.1.1, 8.8.8.8}")
    }

    @Test("The DHCPv6 dns_server flips the same way")
    func resolverReplacesDNSServerV6() {
        let on = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: ["2606:4700:4700::1111"], domainName: nil, subnet6: "fd00::/64",
            resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"])
        #expect(on["dns_server"] == "{fd00:ec2:1::100}")

        let off = OVNDHCPOptionsBuilder.v6Options(
            dnsServers: ["2606:4700:4700::1111"], domainName: nil, subnet6: "fd00::/64",
            resolverAddresses: [])
        #expect(off["dns_server"] == "{2606:4700:4700::1111}")
    }

    @Test("Option 121 carries whichever link-local services the network publishes")
    func classlessStaticRouteCoversBothServices() {
        // Most Linux images carry a 169.254.0.0/16 route that covers both by
        // accident, but that is not universal — and a missing resolver route
        // costs the guest all name resolution, not just IMDS.
        #expect(
            OVNDHCPOptionsBuilder.classlessStaticRoute(gateway: "10.0.0.1", metadata: true, resolver: nil)
                == "{169.254.169.254/32,0.0.0.0, 0.0.0.0/0,10.0.0.1}")
        #expect(
            OVNDHCPOptionsBuilder.classlessStaticRoute(
                gateway: "10.0.0.1", metadata: false, resolver: "169.254.1.0")
                == "{169.254.1.0/32,0.0.0.0, 0.0.0.0/0,10.0.0.1}")
        #expect(
            OVNDHCPOptionsBuilder.classlessStaticRoute(
                gateway: "10.0.0.1", metadata: true, resolver: "169.254.1.0")
                == "{169.254.169.254/32,0.0.0.0, 169.254.1.0/32,0.0.0.0, 0.0.0.0/0,10.0.0.1}")
    }

    @Test("The default route is repeated in option 121 whichever services are on")
    func defaultRouteAlwaysRepeated() {
        // RFC 3442 requires a client that understands option 121 to ignore
        // option 3 entirely, so omitting it would trade the guest's default
        // gateway for a link-local route.
        for (metadata, resolver) in [(true, nil), (false, "169.254.1.0"), (true, "169.254.1.0")]
            as [(Bool, String?)]
        {
            let route = OVNDHCPOptionsBuilder.classlessStaticRoute(
                gateway: "10.0.0.1", metadata: metadata, resolver: resolver)
            #expect(route.contains("0.0.0.0/0,10.0.0.1"))
        }
    }

    @Test("A resolver-only network still gets option 121")
    func resolverAloneEmitsOption121() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil,
            subnet: "10.0.0.0/24", metadataEnabled: false, resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"])
        #expect(options["classless_static_route"]?.contains("169.254.1.0/32") == true)
        #expect(options["classless_static_route"]?.contains("169.254.169.254/32") == false)
    }

    @Test("A network with neither service emits no option 121 at all")
    func neitherServiceOmitsOption121() {
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil,
            subnet: "10.0.0.0/24", metadataEnabled: false, resolverAddresses: [])
        #expect(options["classless_static_route"] == nil)
    }

    @Test("The resolver address reaches the guest even when no upstreams are configured")
    func resolverWithNoUpstreams() {
        // An empty forwarder list means the resolver answers its zones and
        // refuses everything else — which is still strictly better than telling
        // the guest it has no resolver at all.
        let options = OVNDHCPOptionsBuilder.v4Options(
            gateway: "10.0.0.1", dnsServers: [], domainName: nil, leaseTime: nil,
            subnet: "10.0.0.0/24", resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"])
        #expect(options["dns_server"] == "{169.254.1.0}")
    }
}
